//! The Windows tray app. A worker thread runs the sync every `interval_sec`, as 2.x's loop
//! did; the icon shows the result, the tooltip and the menu show both ports, and a
//! notification says when the port changes or something needs fixing.

use crate::config::{self, Args, Settings};
use crate::sync::{self, Outcome, Syncer};
use crate::winutil::{self, copy_w, w, Look};
use std::sync::atomic::{AtomicIsize, AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HWND, LPARAM, LRESULT, POINT, WAIT_OBJECT_0, WPARAM,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Threading::{CreateMutexW, OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE};
use windows_sys::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_SHOWTIP, NIF_TIP, NIIF_INFO, NIIF_WARNING, NIM_ADD, NIM_DELETE, NIM_MODIFY,
    NIM_SETVERSION, NOTIFYICONDATAW, NOTIFYICON_VERSION_4,
};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

const CLASS: &str = "RFS.PortSync.Tray";
const WM_TRAY: u32 = WM_APP + 1;
const WM_STATUS: u32 = WM_APP + 2;
/// A second launch asks the running one to say how it's doing.
const WM_SHOW: u32 = WM_APP + 3;
const NIN_SELECT: u32 = WM_USER;
const NIN_KEYSELECT: u32 = WM_USER + 1;
const NIN_BALLOONUSERCLICK: u32 = WM_USER + 5;

const ID_SYNC: usize = 10;
const ID_COPY: usize = 11;
const ID_WEBUI: usize = 12;
const ID_LOG: usize = 20;
const ID_SETTINGS: usize = 21;
const ID_STARTUP: usize = 30;
const ID_QUIT: usize = 31;

// ---------------------------------------------------------------------------
// The worker: the sync loop, on its own thread
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Control {
    wake: bool,
    force: bool,
    quit: bool,
}

#[derive(Clone)]
struct Status {
    outcome: Option<Outcome>,
    proton: Option<u32>,
    qbit: Option<i64>,
    settings: Settings,
}

struct Shared {
    control: Mutex<Control>,
    cv: Condvar,
    status: Mutex<Status>,
}

static HWND_MAIN: AtomicIsize = AtomicIsize::new(0);
static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);

fn post(msg: u32) {
    let h = HWND_MAIN.load(Ordering::SeqCst) as HWND;
    if !h.is_null() {
        unsafe {
            PostMessageW(h, msg, 0, 0);
        }
    }
}

fn worker(shared: Arc<Shared>, args: Args) {
    let (settings, problems) = config::resolve(&args);
    let _ = std::fs::create_dir_all(&settings.state_dir);
    let mut s = Syncer::new(settings, false);
    for p in &problems {
        s.log.line(p);
    }
    sync::move_legacy_state(&s.settings, &mut s.log);
    s.log.line(&format!("port-sync {} watching {}", crate::VERSION, s.settings.proton_logs.display()));
    let mut stamp = config::modified(&s.settings.config_path());
    loop {
        // config.json edited from the menu (or by hand): pick it up at the next cycle.
        let now = config::modified(&s.settings.config_path());
        if now != stamp {
            stamp = now;
            let (fresh, problems) = config::resolve(&args);
            for p in &problems {
                s.log.line(p);
            }
            if fresh != s.settings {
                s.log.line(&format!(
                    "settings changed: Web UI {} as {}, adapter '{}', Proton logs {}, every {} s",
                    fresh.qbit_url,
                    fresh.qbit_user,
                    fresh.adapter,
                    fresh.proton_logs.display(),
                    fresh.interval_sec
                ));
                s.reconfigure(fresh);
            }
        }
        let force = std::mem::take(&mut shared.control.lock().unwrap().force);
        if force {
            s.force_check();
        }
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| s.cycle()))
            .unwrap_or_else(|_| Outcome::Problem("error: port-sync hit a bug; it will try again".into()));
        *shared.status.lock().unwrap() =
            Status { outcome: Some(outcome), proton: s.proton_port, qbit: s.qbit_port, settings: s.settings.clone() };
        post(WM_STATUS);

        let mut c = shared.control.lock().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(s.settings.interval_sec);
        while !c.wake && !c.quit {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                break;
            }
            c = shared.cv.wait_timeout(c, left).unwrap().0;
        }
        if c.quit {
            return;
        }
        c.wake = false;
    }
}

// ---------------------------------------------------------------------------
// What the icon, tooltip and menu say
// ---------------------------------------------------------------------------

fn trim_tail(m: &str) -> &str {
    m.trim_end_matches(" - waiting").trim_end_matches(" - will retry")
}

fn look(o: &Option<Outcome>) -> Look {
    match o {
        Some(Outcome::InSync { .. }) | Some(Outcome::Updated { .. }) => Look::InSync,
        Some(Outcome::Problem(_)) => Look::Problem,
        _ => Look::Waiting,
    }
}

fn headline(o: &Option<Outcome>) -> String {
    match o {
        None => "Starting".into(),
        Some(Outcome::InSync { port }) => format!("In sync on {}", port),
        Some(Outcome::Updated { to, .. }) => format!("In sync on {}", to),
        Some(Outcome::Waiting(m)) => format!("Waiting: {}", trim_tail(m)),
        Some(Outcome::Problem(m)) => {
            // The first sentence; the log has the rest.
            let first = m.split(". ").next().unwrap_or(m);
            first.trim_end_matches('.').to_string()
        }
    }
}

fn ports_line(st: &Status) -> String {
    let p = st.proton.map(|p| p.to_string()).unwrap_or_else(|| "-".into());
    let q = st.qbit.map(|p| p.to_string()).unwrap_or_else(|| "-".into());
    format!("Proton VPN {}  ·  qBittorrent {}", p, q)
}

// ---------------------------------------------------------------------------
// The tray window
// ---------------------------------------------------------------------------

struct Tray {
    hwnd: HWND,
    shared: Arc<Shared>,
    icons: [HICON; 3],
    look: Look,
    /// The last problem a notification was shown for, so each is shown once.
    told: Option<String>,
    /// "Sync now" was clicked: say what the next cycle found.
    manual: bool,
    /// Started by hand or by the installer (not at sign-in): say it is running.
    greet: bool,
}

// The window and icon handles are only used on the UI thread.
unsafe impl Send for Tray {}

static TRAY: Mutex<Option<Tray>> = Mutex::new(None);

fn with_tray<R>(f: impl FnOnce(&mut Tray) -> R) -> Option<R> {
    TRAY.lock().unwrap().as_mut().map(f)
}

fn icon_for(t: &Tray, l: Look) -> HICON {
    t.icons[match l {
        Look::InSync => 0,
        Look::Waiting => 1,
        Look::Problem => 2,
    }]
}

fn nid(t: &Tray) -> NOTIFYICONDATAW {
    let mut n: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
    n.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    n.hWnd = t.hwnd;
    n.uID = 1;
    n
}

fn tooltip(st: &Status) -> String {
    format!("port-sync: {}\n{}", headline(&st.outcome), ports_line(st))
}

fn add_icon(t: &Tray, tip: &str) {
    let mut n = nid(t);
    n.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    n.uCallbackMessage = WM_TRAY;
    n.hIcon = icon_for(t, t.look);
    copy_w(&mut n.szTip, tip);
    unsafe {
        Shell_NotifyIconW(NIM_ADD, &n);
        n.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &n);
    }
}

fn update_icon(t: &mut Tray, l: Look, tip: &str) {
    t.look = l;
    let mut n = nid(t);
    n.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    n.hIcon = icon_for(t, l);
    copy_w(&mut n.szTip, tip);
    unsafe {
        Shell_NotifyIconW(NIM_MODIFY, &n);
    }
}

fn notify(t: &Tray, title: &str, body: &str, warning: bool) {
    let mut n = nid(t);
    n.uFlags = NIF_INFO;
    copy_w(&mut n.szInfoTitle, title);
    copy_w(&mut n.szInfo, if body.trim().is_empty() { " " } else { body });
    n.dwInfoFlags = if warning { NIIF_WARNING } else { NIIF_INFO };
    unsafe {
        Shell_NotifyIconW(NIM_MODIFY, &n);
    }
}

fn status(t: &Tray) -> Status {
    t.shared.status.lock().unwrap().clone()
}

fn on_status(t: &mut Tray) {
    let st = status(t);
    update_icon(t, look(&st.outcome), &tooltip(&st));
    let allowed = st.settings.notifications;
    let mut said = false;
    match &st.outcome {
        Some(Outcome::Updated { from, to }) => {
            t.told = None;
            if allowed {
                notify(t, &format!("qBittorrent now listens on {}", to), &format!("The port Proton VPN forwards. It was {}.", from), false);
                said = true;
            }
        }
        Some(Outcome::InSync { .. }) => t.told = None,
        Some(Outcome::Problem(m)) if t.told.as_deref() != Some(m.as_str()) => {
            t.told = Some(m.clone());
            if allowed {
                notify(t, "port-sync needs attention", m, true);
                said = true;
            }
        }
        _ => {}
    }
    if (t.manual || t.greet) && !said {
        let title = if t.greet { "port-sync is running" } else { "port-sync" };
        notify(t, title, &format!("{}.\n{}", headline(&st.outcome), ports_line(&st)), false);
    }
    t.manual = false;
    t.greet = false;
}

fn wake(shared: &Shared, force: bool) {
    let mut c = shared.control.lock().unwrap();
    c.wake = true;
    c.force |= force;
    shared.cv.notify_all();
}

fn open_in_notepad(p: &std::path::Path) -> bool {
    if !p.exists() {
        if let Some(d) = p.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let _ = std::fs::write(p, "");
    }
    winutil::shell_open("notepad.exe", Some(&format!("\"{}\"", p.display())))
}

fn show_menu(hwnd: HWND) {
    let Some(st) = with_tray(|t| status(t)) else { return };
    let port = st.proton;
    unsafe {
        let m = CreatePopupMenu();
        let add = |id: usize, text: &str, flags: u32| {
            let t = w(text);
            AppendMenuW(m, MF_STRING | flags, id, t.as_ptr());
        };
        let sep = || {
            AppendMenuW(m, MF_SEPARATOR, 0, std::ptr::null());
        };
        add(1, &format!("port-sync {}", crate::VERSION), MF_GRAYED);
        add(2, &headline(&st.outcome), MF_GRAYED);
        add(3, &ports_line(&st), MF_GRAYED);
        sep();
        add(ID_SYNC, "Sync now", 0);
        match port {
            Some(p) => add(ID_COPY, &format!("Copy port {}", p), 0),
            None => add(ID_COPY, "Copy port", MF_GRAYED),
        }
        add(ID_WEBUI, "Open qBittorrent Web UI", 0);
        sep();
        add(ID_LOG, "Open log", 0);
        add(ID_SETTINGS, "Edit settings", 0);
        sep();
        add(ID_STARTUP, "Start at sign-in", if winutil::startup_enabled() { MF_CHECKED } else { 0 });
        add(ID_QUIT, "Quit", 0);
        let mut pt = POINT { x: 0, y: 0 };
        GetCursorPos(&mut pt);
        SetForegroundWindow(hwnd);
        let cmd = TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd, std::ptr::null());
        PostMessageW(hwnd, WM_NULL, 0, 0);
        DestroyMenu(m);
        if cmd != 0 {
            command(hwnd, cmd as usize, &st);
        }
    }
}

fn failed(hwnd: HWND, what: &str) {
    let t = w(&format!("Could not {}.", what));
    let c = w("port-sync");
    unsafe {
        MessageBoxW(hwnd, t.as_ptr(), c.as_ptr(), MB_OK | MB_ICONWARNING);
    }
}

fn command(hwnd: HWND, id: usize, st: &Status) {
    match id {
        ID_SYNC => {
            with_tray(|t| {
                t.manual = true;
                wake(&t.shared, true);
            });
        }
        ID_COPY => {
            if let Some(p) = st.proton {
                if !winutil::copy_text(hwnd, &p.to_string()) {
                    failed(hwnd, "copy the port");
                }
            }
        }
        ID_WEBUI => {
            if !winutil::shell_open(&format!("{}/", st.settings.qbit_url), None) {
                failed(hwnd, "open the browser");
            }
        }
        ID_LOG => {
            if !open_in_notepad(&st.settings.sync_log()) {
                failed(hwnd, "open the log");
            }
        }
        ID_SETTINGS => {
            let p = st.settings.config_path();
            if !p.exists() && config::write_default_config(&st.settings).is_err() {
                failed(hwnd, &format!("write {}", p.display()));
                return;
            }
            if !open_in_notepad(&p) {
                failed(hwnd, "open the settings");
            }
        }
        ID_STARTUP => {
            let on = !winutil::startup_enabled();
            if let Err(e) = winutil::set_startup(on) {
                failed(hwnd, &format!("change the sign-in entry (registry error {})", e));
            }
        }
        ID_QUIT => unsafe {
            PostMessageW(hwnd, WM_CLOSE, 0, 0);
        },
        _ => {}
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let tc = TASKBAR_CREATED.load(Ordering::SeqCst);
    if tc != 0 && msg == tc {
        // Explorer restarted: put the icon back.
        with_tray(|t| add_icon(t, &tooltip(&status(t))));
        return 0;
    }
    match msg {
        WM_TRAY => {
            match (lparam as u32) & 0xffff {
                WM_CONTEXTMENU | NIN_SELECT | NIN_KEYSELECT => show_menu(hwnd),
                NIN_BALLOONUSERCLICK => {
                    if let Some(st) = with_tray(|t| status(t)) {
                        open_in_notepad(&st.settings.sync_log());
                    }
                }
                _ => {}
            }
            0
        }
        WM_STATUS => {
            with_tray(on_status);
            0
        }
        WM_SHOW => {
            with_tray(|t| {
                let st = status(t);
                notify(t, "port-sync is running", &format!("{}.\n{}", headline(&st.outcome), ports_line(&st)), false);
            });
            0
        }
        WM_CLOSE => {
            with_tray(|t| {
                let n = nid(t);
                Shell_NotifyIconW(NIM_DELETE, &n);
                let mut c = t.shared.control.lock().unwrap();
                c.quit = true;
                t.shared.cv.notify_all();
            });
            DestroyWindow(hwnd);
            0
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn find_running() -> HWND {
    let class = w(CLASS);
    unsafe { FindWindowW(class.as_ptr(), std::ptr::null()) }
}

/// `--quit`: close the running tray app and wait for it to exit (the installer replaces the
/// exe next). 0 when none is left running.
pub fn quit_running() -> i32 {
    let hwnd = find_running();
    if hwnd.is_null() {
        println!("port-sync is not running");
        return 0;
    }
    unsafe {
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, &mut pid);
        let process = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
        PostMessageW(hwnd, WM_CLOSE, 0, 0);
        let gone = if process.is_null() {
            let mut left = 100;
            while left > 0 && !find_running().is_null() {
                std::thread::sleep(Duration::from_millis(100));
                left -= 1;
            }
            left > 0
        } else {
            let r = WaitForSingleObject(process, 10_000) == WAIT_OBJECT_0;
            CloseHandle(process);
            r
        };
        if gone {
            println!("stopped port-sync");
            0
        } else {
            println!("port-sync did not stop within 10 s");
            1
        }
    }
}

pub fn run(args: &Args) -> i32 {
    // One tray per user session: a second launch asks the first to show how it's doing.
    let mname = w(r"Local\RFS.PortSync.Tray");
    let mutex = unsafe { CreateMutexW(std::ptr::null(), 1, mname.as_ptr()) };
    if !mutex.is_null() && unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        let h = find_running();
        if !h.is_null() {
            unsafe {
                PostMessageW(h, WM_SHOW, 0, 0);
            }
        }
        return 0;
    }

    let (settings, _) = config::resolve(args);
    let shared = Arc::new(Shared {
        control: Mutex::new(Control::default()),
        cv: Condvar::new(),
        status: Mutex::new(Status { outcome: None, proton: None, qbit: None, settings }),
    });

    unsafe {
        let hinst = GetModuleHandleW(std::ptr::null());
        let class = w(CLASS);
        let wc = WNDCLASSW {
            style: 0,
            lpfnWndProc: Some(wndproc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hinst,
            hIcon: std::ptr::null_mut(),
            hCursor: std::ptr::null_mut(),
            hbrBackground: std::ptr::null_mut(),
            lpszMenuName: std::ptr::null(),
            lpszClassName: class.as_ptr(),
        };
        RegisterClassW(&wc);
        let title = w("port-sync");
        let hwnd = CreateWindowExW(
            0,
            class.as_ptr(),
            title.as_ptr(),
            0,
            0,
            0,
            0,
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            hinst,
            std::ptr::null(),
        );
        if hwnd.is_null() {
            return 1;
        }
        HWND_MAIN.store(hwnd as isize, Ordering::SeqCst);
        let tc = w("TaskbarCreated");
        TASKBAR_CREATED.store(RegisterWindowMessageW(tc.as_ptr()), Ordering::SeqCst);

        let size = GetSystemMetrics(SM_CXSMICON).max(16) as u32;
        let tray = Tray {
            hwnd,
            shared: Arc::clone(&shared),
            icons: [
                winutil::make_icon(Look::InSync, size),
                winutil::make_icon(Look::Waiting, size),
                winutil::make_icon(Look::Problem, size),
            ],
            look: Look::Waiting,
            told: None,
            manual: false,
            greet: !args.autostart,
        };
        add_icon(&tray, "port-sync: starting");
        *TRAY.lock().unwrap() = Some(tray);

        let a = args.clone();
        let s2 = Arc::clone(&shared);
        std::thread::spawn(move || worker(s2, a));

        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    0
}
