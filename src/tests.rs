//! The 2.x Pester tests of the sync, ported, and more. The qBittorrent tests run against a
//! stand-in Web UI here, and also against a real one when these are set (they change its
//! listening port, so don't point them at the one you use):
//!   PORT_SYNC_TEST_QBIT_URL=http://127.0.0.1:8080
//!   PORT_SYNC_TEST_QBIT_PASS=<Web UI password for admin>

use crate::config::{self, Settings};
use crate::log::Logger;
use crate::proton;
use crate::sync::{Outcome, Syncer, AUTH_RETRY, LOGIN_REJECTED, NOT_REACHABLE, NO_PORT};
use crate::testkit::{FakeQbit, Style, TempDir};
use std::io::Write;
use std::net::TcpListener;
use std::sync::Mutex;
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn write_proton(t: &TempDir, lines: &[&str], name: &str) {
    let mut text = lines.join("\r\n");
    text.push_str("\r\n");
    std::fs::write(t.logs().join(name), text).unwrap();
}

fn proton_log(t: &TempDir, lines: &[&str]) {
    write_proton(t, lines, "client-logs.txt");
}

fn settings(t: &TempDir, url: &str) -> Settings {
    Settings {
        qbit_url: url.to_string(),
        qbit_user: "admin".into(),
        proton_logs: t.logs(),
        adapter: String::new(),
        state_dir: t.state(),
        interval_sec: 15,
        recheck_sec: 60,
        notifications: true,
    }
}

fn write_password(s: &Settings, plain: &str) {
    std::fs::write(s.pass_file(), crate::platform::encode_password(plain) + "\r\n").unwrap();
}

fn log_lines(s: &Settings) -> Vec<String> {
    std::fs::read_to_string(s.sync_log()).unwrap_or_default().lines().map(|l| l.to_string()).collect()
}

fn last_log(s: &Settings) -> String {
    log_lines(s).pop().unwrap_or_default()
}

fn ago(secs: u64) -> Instant {
    Instant::now().checked_sub(Duration::from_secs(secs)).expect("uptime is longer than the test's look-back")
}

// ---------------------------------------------------------------------------
// The same scenarios against the stand-in and, when configured, a real qBittorrent
// ---------------------------------------------------------------------------

trait Qbit {
    fn url(&self) -> String;
    fn password(&self) -> String;
    fn set_listen_port(&self, port: i64);
    /// (listen_port, random_port, upnp)
    fn prefs(&self) -> (i64, bool, bool);
}

impl Qbit for FakeQbit {
    fn url(&self) -> String {
        self.url.clone()
    }
    fn password(&self) -> String {
        self.state.lock().unwrap().password.clone()
    }
    fn set_listen_port(&self, port: i64) {
        let mut s = self.state.lock().unwrap();
        s.listen_port = port;
        s.random_port = true;
        s.upnp = true;
    }
    fn prefs(&self) -> (i64, bool, bool) {
        let s = self.state.lock().unwrap();
        (s.listen_port, s.random_port, s.upnp)
    }
}

struct RealQbit {
    url: String,
    password: String,
}

impl RealQbit {
    fn from_env() -> Option<RealQbit> {
        let url = std::env::var("PORT_SYNC_TEST_QBIT_URL").ok().filter(|v| !v.is_empty())?;
        let password = std::env::var("PORT_SYNC_TEST_QBIT_PASS").unwrap_or_default();
        Some(RealQbit { url: url.trim_end_matches('/').to_string(), password })
    }
    fn session(&self) -> (ureq::Agent, String) {
        let a = ureq::AgentBuilder::new().timeout(Duration::from_secs(20)).build();
        let r =
            a.post(&format!("{}/api/v2/auth/login", self.url)).send_form(&[("username", "admin"), ("password", &self.password)]).unwrap();
        let cookie = r.all("set-cookie").iter().filter_map(|c| c.split(';').next()).collect::<Vec<_>>().join("; ");
        (a, cookie)
    }
}

impl Qbit for RealQbit {
    fn url(&self) -> String {
        self.url.clone()
    }
    fn password(&self) -> String {
        self.password.clone()
    }
    fn set_listen_port(&self, port: i64) {
        let (a, c) = self.session();
        a.post(&format!("{}/api/v2/app/setPreferences", self.url))
            .set("Cookie", &c)
            .send_form(&[("json", &format!("{{\"listen_port\":{}}}", port))])
            .unwrap();
    }
    fn prefs(&self) -> (i64, bool, bool) {
        let (a, c) = self.session();
        let v: serde_json::Value = serde_json::from_str(
            &a.get(&format!("{}/api/v2/app/preferences", self.url)).set("Cookie", &c).call().unwrap().into_string().unwrap(),
        )
        .unwrap();
        (v["listen_port"].as_i64().unwrap(), v["random_port"].as_bool().unwrap(), v["upnp"].as_bool().unwrap())
    }
}

/// The real qBittorrent is one shared instance: one scenario at a time.
static REAL: Mutex<()> = Mutex::new(());

fn fresh(q: &dyn Qbit, t: &TempDir) -> Syncer {
    let s = settings(t, &q.url());
    write_password(&s, &q.password());
    q.set_listen_port(6881);
    Syncer::new(s, false)
}

fn sets_port_and_turns_off_random_and_upnp(q: &dyn Qbit) {
    let t = TempDir::new("set");
    let mut s = fresh(q, &t);
    proton_log(&t, &["Port pair 48000->48001"]);
    assert_eq!(s.cycle(), Outcome::Updated { from: 6881, to: 48001 });
    assert_eq!(q.prefs(), (48001, false, false));
    assert!(last_log(&s.settings).ends_with("[port-sync] listening port updated: 6881 -> 48001"), "{}", last_log(&s.settings));
}

fn leaves_a_correct_port_alone(q: &dyn Qbit) {
    let t = TempDir::new("correct");
    let mut s = fresh(q, &t);
    q.set_listen_port(48100);
    proton_log(&t, &["Port pair 48100->48100"]);
    assert_eq!(s.cycle(), Outcome::InSync { port: 48100 });
    assert!(last_log(&s.settings).ends_with("listening port already correct: 48100"));
}

fn puts_the_port_back_at_the_next_recheck(q: &dyn Qbit) {
    let t = TempDir::new("recheck");
    let mut s = fresh(q, &t);
    proton_log(&t, &["Port pair 48200->48200"]);
    assert!(s.cycle().ok());
    q.set_listen_port(6999);
    assert!(s.cycle().ok(), "within recheck_sec: no API call");
    assert_eq!(q.prefs().0, 6999);
    s.last_check = Some(ago(61));
    assert_eq!(s.cycle(), Outcome::Updated { from: 6999, to: 48200 });
    assert_eq!(q.prefs().0, 48200);
}

fn follows_a_new_port_at_once(q: &dyn Qbit) {
    let t = TempDir::new("follow");
    let mut s = fresh(q, &t);
    proton_log(&t, &["Port pair 48300->48300"]);
    assert!(s.cycle().ok());
    proton_log(&t, &["Port pair 48300->48300", "Status updated to Disconnected", "Port pair 48301->48301"]);
    assert_eq!(s.cycle(), Outcome::Updated { from: 48300, to: 48301 });
    assert_eq!(q.prefs().0, 48301);
}

fn stops_after_a_rejected_login_until_the_file_changes(q: &dyn Qbit) {
    let t = TempDir::new("auth");
    let mut s = fresh(q, &t);
    proton_log(&t, &["Port pair 48400->48400"]);
    write_password(&s.settings, "definitely-wrong");
    assert_eq!(s.cycle(), Outcome::Problem(LOGIN_REJECTED.into()));
    assert!(last_log(&s.settings).contains("login rejected"));
    let before = log_lines(&s.settings).len();
    s.last_check = None;
    assert!(!s.cycle().ok(), "same file: no second login attempt");
    assert_eq!(log_lines(&s.settings).len(), before);

    std::thread::sleep(Duration::from_millis(50));
    write_password(&s.settings, &q.password()); // a new file: tries again
                                                // Some filesystems keep whole-second times; make sure the stamp moves.
    let f = std::fs::File::options().write(true).open(s.settings.pass_file()).unwrap();
    f.set_modified(std::time::SystemTime::now() + Duration::from_secs(2)).unwrap();
    assert!(s.cycle().ok());
    assert_eq!(q.prefs().0, 48400);
}

fn tries_again_after_30_minutes(q: &dyn Qbit) {
    let t = TempDir::new("auth30");
    let mut s = fresh(q, &t);
    proton_log(&t, &["Port pair 48500->48500"]);
    write_password(&s.settings, "definitely-wrong");
    assert!(!s.cycle().ok());
    s.auth_failed_at = Some(ago(AUTH_RETRY.as_secs() + 1));
    let before = log_lines(&s.settings).len();
    assert!(!s.cycle().ok());
    assert_eq!(log_lines(&s.settings).len(), before + 1, "it tried, and logged the rejection again");
}

macro_rules! both {
    ($fake:ident, $real:ident, $scenario:ident) => {
        #[test]
        fn $fake() {
            for style in [Style::V4, Style::V5] {
                $scenario(&FakeQbit::start("right-pass", 6881, style));
            }
        }
        #[test]
        fn $real() {
            let Some(q) = RealQbit::from_env() else { return };
            let _g = REAL.lock().unwrap_or_else(|e| e.into_inner());
            $scenario(&q);
        }
    };
}

both!(fake_sets_port, real_sets_port, sets_port_and_turns_off_random_and_upnp);
both!(fake_leaves_correct_port, real_leaves_correct_port, leaves_a_correct_port_alone);
both!(fake_recheck, real_recheck, puts_the_port_back_at_the_next_recheck);
both!(fake_follows_new_port, real_follows_new_port, follows_a_new_port_at_once);
both!(fake_auth_backoff, real_auth_backoff, stops_after_a_rejected_login_until_the_file_changes);
both!(fake_auth_retry, real_auth_retry, tries_again_after_30_minutes);

// ---------------------------------------------------------------------------
// The stand-in only: things a real qBittorrent can't easily be made to do
// ---------------------------------------------------------------------------

#[test]
fn logs_out_after_every_check() {
    let q = FakeQbit::start("p", 6881, Style::V4);
    let t = TempDir::new("logout");
    let mut s = fresh(&q, &t);
    proton_log(&t, &["Port pair 40100->40100"]);
    assert!(s.cycle().ok());
    s.force_check();
    assert!(s.cycle().ok());
    let st = q.state.lock().unwrap();
    assert_eq!((st.logins, st.logouts), (2, 2));
    assert!(st.sessions.is_empty(), "no session left open");
}

#[test]
fn a_banned_address_counts_as_a_rejected_login() {
    let q = FakeQbit::start("p", 6881, Style::V4);
    q.state.lock().unwrap().banned = true;
    let t = TempDir::new("ban");
    let mut s = fresh(&q, &t);
    proton_log(&t, &["Port pair 40200->40200"]);
    assert_eq!(s.cycle(), Outcome::Problem(LOGIN_REJECTED.into()));
}

#[test]
fn says_so_when_qbittorrent_ignores_the_new_port() {
    let q = FakeQbit::start("p", 6881, Style::V4);
    q.state.lock().unwrap().stuck = true;
    let t = TempDir::new("stuck");
    let mut s = fresh(&q, &t);
    proton_log(&t, &["Port pair 40300->40300"]);
    assert_eq!(s.cycle(), Outcome::Problem("failed to set port (qBittorrent still reports 6881)".into()));
    assert!(last_log(&s.settings).ends_with("failed to set port (qBittorrent still reports 6881)"));
}

#[test]
fn an_http_error_after_login_is_logged_as_an_error_once() {
    // Logged in, but the session is refused afterwards (as behind a proxy that drops it).
    let q = FakeQbit::start("p", 6881, Style::V4);
    q.state.lock().unwrap().forget = true;
    let t = TempDir::new("err");
    let mut s = fresh(&q, &t);
    proton_log(&t, &["Port pair 40400->40400"]);
    for _ in 0..3 {
        s.force_check();
        match s.cycle() {
            Outcome::Problem(m) => assert_eq!(m, "error: qBittorrent answered 403 to /api/v2/app/preferences"),
            other => panic!("{:?}", other),
        }
    }
    assert_eq!(log_lines(&s.settings).len(), 1, "logged once");
    assert_eq!(q.state.lock().unwrap().logouts, 3, "still logs out");
}

// ---------------------------------------------------------------------------
// Get-ProtonPort
// ---------------------------------------------------------------------------

#[test]
fn proton_none_without_logs() {
    let t = TempDir::new("p0");
    assert_eq!(proton::forwarded_port(&t.logs()), None);
}

#[test]
fn proton_takes_the_newest_pair() {
    let t = TempDir::new("p1");
    proton_log(&t, &["a Port pair 40000->40000", "b noise", "c Port pair 40001->40002"]);
    assert_eq!(proton::forwarded_port(&t.logs()), Some(40002));
}

#[test]
fn proton_reads_the_rotated_file_first() {
    let t = TempDir::new("p2");
    write_proton(&t, &["Port pair 41000->41000"], "client-logs.1.txt");
    proton_log(&t, &["Port pair 42000->42000"]);
    assert_eq!(proton::forwarded_port(&t.logs()), Some(42000));
}

#[test]
fn proton_falls_back_to_the_rotated_file() {
    let t = TempDir::new("p3");
    write_proton(&t, &["Port pair 41000->41000"], "client-logs.1.txt");
    proton_log(&t, &["Status updated to Connecting"]);
    assert_eq!(proton::forwarded_port(&t.logs()), Some(41000));
}

#[test]
fn proton_forgets_after_a_disconnect() {
    let t = TempDir::new("p4");
    proton_log(&t, &["Port pair 43000->43000", "Status updated to Disconnected"]);
    assert_eq!(proton::forwarded_port(&t.logs()), None);
}

#[test]
fn proton_forgets_when_port_forwarding_stops() {
    let t = TempDir::new("p5");
    proton_log(&t, &["Port pair 43000->43000", "Port forwarding status changed from 'Running' to 'Stopped'"]);
    assert_eq!(proton::forwarded_port(&t.logs()), None);
}

#[test]
fn proton_picks_up_the_port_after_a_reconnect() {
    let t = TempDir::new("p6");
    proton_log(&t, &["Port pair 43000->43000", "Status updated to Disconnected", "Port pair 44000->44000"]);
    assert_eq!(proton::forwarded_port(&t.logs()), Some(44000));
}

#[test]
fn proton_rejects_a_port_out_of_range() {
    let t = TempDir::new("p7");
    proton_log(&t, &["Port pair 1->70000"]);
    assert_eq!(proton::forwarded_port(&t.logs()), None);
    proton_log(&t, &["Port pair 1->0"]);
    assert_eq!(proton::forwarded_port(&t.logs()), None);
    proton_log(&t, &["Port pair 1->99999999999999999999999"]);
    assert_eq!(proton::forwarded_port(&t.logs()), None);
}

#[test]
fn proton_finds_the_pair_past_the_256_kb_tail() {
    let t = TempDir::new("p8");
    let filler = "x".repeat(1000);
    let mut lines: Vec<&str> = (0..400).map(|_| filler.as_str()).collect();
    lines.push("Port pair 45000->45000");
    proton_log(&t, &lines);
    assert!(std::fs::metadata(t.logs().join("client-logs.txt")).unwrap().len() > proton::TAIL_BYTES);
    assert_eq!(proton::forwarded_port(&t.logs()), Some(45000));
}

#[test]
fn proton_reads_a_log_another_process_is_writing() {
    let t = TempDir::new("p9");
    let mut f = std::fs::File::create(t.logs().join("client-logs.txt")).unwrap();
    writeln!(f, "Port pair 46000->46000").unwrap();
    f.flush().unwrap();
    assert_eq!(proton::forwarded_port(&t.logs()), Some(46000));
    drop(f);
}

#[test]
fn proton_matches_case_insensitively_like_powershell() {
    assert_eq!(proton::port_pair("2026 PORT PAIR 1->2"), Some(2));
    assert_eq!(proton::port_pair("port pair x Port pair 5->6"), Some(6));
    assert_eq!(proton::port_pair("Port pair 5-> 6"), None);
    assert!(proton::is_stop("status UPDATED to disconnected"));
    assert!(!proton::is_stop("Port forwarding status changed from '' to 'Stopped'"));
    assert!(!proton::is_stop("Port forwarding status changed from 'Running' to 'Starting'"));
}

// ---------------------------------------------------------------------------
// Write-SyncLog, Get-QbitPassword, Sync-Port without qBittorrent
// ---------------------------------------------------------------------------

#[test]
fn sync_log_rotates_past_1_mb() {
    let t = TempDir::new("rot");
    let path = t.state().join("sync.log");
    std::fs::write(&path, "y".repeat(1_100_000)).unwrap();
    let mut l = Logger::new(path.clone(), false);
    l.line("after rotation");
    assert!(t.state().join("sync.log.1").exists());
    let lines: Vec<String> = std::fs::read_to_string(&path).unwrap().lines().map(String::from).collect();
    assert_eq!(lines.len(), 1);
    assert!(lines[0].ends_with("[port-sync] after rotation"));
    // yyyy-MM-dd HH:mm:ss
    let stamp = &lines[0][..19];
    assert!(stamp.as_bytes()[4] == b'-' && stamp.as_bytes()[10] == b' ' && stamp.as_bytes()[13] == b':', "{}", stamp);
}

#[test]
fn notes_are_logged_once_until_they_change() {
    let t = TempDir::new("note");
    let mut l = Logger::new(t.state().join("sync.log"), false);
    l.note("a");
    l.note("a");
    l.note("b");
    l.note("a");
    assert_eq!(std::fs::read_to_string(t.state().join("sync.log")).unwrap().lines().count(), 3);
}

#[test]
fn password_file_missing() {
    let t = TempDir::new("pw0");
    let s = settings(&t, "http://127.0.0.1:1");
    let e = crate::platform::read_password(&s.pass_file()).unwrap_err();
    assert!(e.contains("password file missing"), "{}", e);
}

#[cfg(windows)]
#[test]
fn password_file_that_wont_decrypt_says_so() {
    let t = TempDir::new("pw1");
    let s = settings(&t, "http://127.0.0.1:1");
    for junk in ["not-a-dpapi-blob", "01000000d08c9ddf0115d1118c7a00c04fc297eb", ""] {
        std::fs::write(s.pass_file(), junk).unwrap();
        let e = crate::platform::read_password(&s.pass_file()).unwrap_err();
        assert!(e.contains("can't decrypt"), "{}", e);
    }
}

#[test]
fn password_round_trips() {
    let t = TempDir::new("pw2");
    let s = settings(&t, "http://127.0.0.1:1");
    write_password(&s, "p4ss wörd");
    assert_eq!(crate::platform::read_password(&s.pass_file()).unwrap(), "p4ss wörd");
}

/// The file 2.x's installer writes, made by Windows PowerShell's ConvertFrom-SecureString.
#[cfg(windows)]
#[test]
fn password_from_convertfrom_securestring() {
    let t = TempDir::new("pw3");
    let file = t.state().join("qbit-pass.txt");
    let cmd = format!(
        "ConvertTo-SecureString 'from-powershell' -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath '{}'",
        file.display()
    );
    let ok = std::process::Command::new("powershell.exe").args(["-NoProfile", "-NonInteractive", "-Command", &cmd]).status();
    if !matches!(ok, Ok(s) if s.success()) {
        eprintln!("no Windows PowerShell here; skipped");
        return;
    }
    assert_eq!(crate::platform::read_password(&file).unwrap(), "from-powershell");
}

#[cfg(windows)]
#[test]
fn sync_reports_a_bad_password_file_as_such() {
    let t = TempDir::new("s0");
    let s = settings(&t, "http://127.0.0.1:1");
    std::fs::write(s.pass_file(), "garbage").unwrap();
    proton_log(&t, &["Port pair 47000->47000"]);
    let mut sy = Syncer::new(s, false);
    match sy.cycle() {
        Outcome::Problem(m) => assert!(m.contains("can't decrypt"), "{}", m),
        o => panic!("{:?}", o),
    }
    assert!(sy.log.last_note.contains("can't decrypt"));
}

#[test]
fn sync_waits_while_the_proton_log_has_no_port() {
    let t = TempDir::new("s1");
    proton_log(&t, &["Status updated to Disconnected"]);
    let mut sy = Syncer::new(settings(&t, "http://127.0.0.1:1"), false);
    assert_eq!(sy.cycle(), Outcome::Waiting(NO_PORT.into()));
    assert_eq!(sy.log.last_note, NO_PORT);
}

#[test]
fn sync_waits_when_nothing_listens_at_the_url() {
    let t = TempDir::new("s2");
    proton_log(&t, &["Port pair 47000->47000"]);
    // A port that was free a moment ago.
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let s = settings(&t, &format!("http://127.0.0.1:{}", port));
    write_password(&s, "whatever");
    let mut sy = Syncer::new(s, false);
    assert_eq!(sy.cycle(), Outcome::Waiting(NOT_REACHABLE.into()));
    assert_eq!(sy.log.last_note, NOT_REACHABLE);
}

#[test]
fn sync_waits_for_the_adapter() {
    let t = TempDir::new("s3");
    proton_log(&t, &["Port pair 47000->47000"]);
    let mut s = settings(&t, "http://127.0.0.1:1");
    s.adapter = "no-such-adapter-port-sync-test".into();
    let mut sy = Syncer::new(s, false);
    assert_eq!(sy.cycle(), Outcome::Waiting("VPN adapter 'no-such-adapter-port-sync-test' is not up - waiting".into()));
}

#[test]
fn a_repeating_condition_is_logged_once() {
    let t = TempDir::new("s4");
    proton_log(&t, &["Status updated to Disconnected"]);
    let mut sy = Syncer::new(settings(&t, "http://127.0.0.1:1"), false);
    for _ in 0..5 {
        sy.cycle();
    }
    assert_eq!(log_lines(&sy.settings).len(), 1);
}

// ---------------------------------------------------------------------------
// Settings and arguments
// ---------------------------------------------------------------------------

fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

#[test]
fn flags_take_the_2x_names_and_the_new_ones() {
    let a =
        config::parse_args(&args(&["-Once", "-QbitUrl", "http://x:1/", "--proton-logs", "C:\\L", "-Adapter", "\"\"", "--recheck-sec=5"]))
            .unwrap();
    assert!(a.once);
    assert_eq!(a.qbit_url.as_deref(), Some("http://x:1/"));
    assert_eq!(a.proton_logs.as_deref(), Some("C:\\L"));
    assert_eq!(a.adapter.as_deref(), Some(""));
    assert_eq!(a.recheck_sec, Some(5));
    assert!(config::parse_args(&args(&["--interval-sec", "soon"])).is_err());
    assert!(config::parse_args(&args(&["--nope"])).is_err());
    assert!(config::parse_args(&args(&["stray"])).is_err());
    assert!(config::parse_args(&args(&["--qbit-url"])).is_err());
    assert!(config::parse_args(&args(&["-Version"])).unwrap().version);
}

#[test]
fn config_json_then_flags() {
    let t = TempDir::new("cfg");
    std::fs::write(
        t.state().join("config.json"),
        "\u{feff}{ \"qbitUrl\": \"http://127.0.0.1:9090/\", \"adapter\": \"ProtonVPN TUN\", \"intervalSec\": 0, \"notifications\": false, \"recheckSec\": \"x\", \"bogus\": 1 }",
    )
    .unwrap();
    let st = t.state().display().to_string();
    let (s, problems) = config::resolve(&config::parse_args(&args(&["--state-dir", &st])).unwrap());
    assert_eq!(s.qbit_url, "http://127.0.0.1:9090");
    assert_eq!(s.adapter, "ProtonVPN TUN");
    assert_eq!(s.interval_sec, 1, "at least a second between cycles");
    assert_eq!(s.recheck_sec, 60);
    assert!(!s.notifications);
    assert_eq!(problems.len(), 2, "{:?}", problems);

    let (s, _) = config::resolve(&config::parse_args(&args(&["--state-dir", &st, "--adapter", "", "--qbit-url", "http://a"])).unwrap());
    assert_eq!(s.adapter, "");
    assert_eq!(s.qbit_url, "http://a");

    std::fs::write(t.state().join("config.json"), "{ not json").unwrap();
    let (s, problems) = config::resolve(&config::parse_args(&args(&["--state-dir", &st])).unwrap());
    assert_eq!(s.qbit_url, config::DEFAULT_QBIT_URL);
    assert_eq!(problems.len(), 1);
}

#[test]
fn default_config_reads_back_the_same() {
    let t = TempDir::new("cfg2");
    let mut s = settings(&t, "http://127.0.0.1:8080");
    s.adapter = "ProtonVPN".into();
    config::write_default_config(&s).unwrap();
    let st = t.state().display().to_string();
    let (back, problems) = config::resolve(&config::parse_args(&args(&["--state-dir", &st])).unwrap());
    assert!(problems.is_empty(), "{:?}", problems);
    assert_eq!(back, s);
}

#[test]
fn legacy_password_is_copied_once() {
    let t = TempDir::new("legacy");
    let s = settings(&t, "http://x");
    let mut l = Logger::new(s.sync_log(), false);
    // move_legacy_state reads LOCALAPPDATA; point a copy of its logic at the temp folder.
    let old = t.path().join("proton-qbit-port-sync");
    std::fs::create_dir_all(&old).unwrap();
    std::fs::write(old.join("qbit-pass.txt"), "legacy").unwrap();
    let _g = ENV.lock().unwrap();
    let saved = std::env::var_os("LOCALAPPDATA");
    std::env::set_var("LOCALAPPDATA", t.path());
    crate::sync::move_legacy_state(&s, &mut l);
    crate::sync::move_legacy_state(&s, &mut l);
    match saved {
        Some(v) => std::env::set_var("LOCALAPPDATA", v),
        None => std::env::remove_var("LOCALAPPDATA"),
    }
    assert_eq!(std::fs::read_to_string(s.pass_file()).unwrap(), "legacy");
    assert_eq!(log_lines(&s).len(), 1);
}

static ENV: Mutex<()> = Mutex::new(());

#[cfg(windows)]
#[test]
fn icons_draw_the_mark_in_each_state() {
    use crate::winutil::{render, Look};
    for size in [16u32, 20, 24, 32, 48] {
        let a = render(Look::InSync, size);
        assert_eq!(a.len(), (size * size * 4) as usize);
        // Corners are transparent, the middle of the tile is opaque.
        assert_eq!(a[3], 0);
        let mid = (((size / 2) * size + size / 2) * 4) as usize;
        assert_eq!(a[mid + 3], 255);
        assert_ne!(render(Look::Waiting, size), a);
        assert_ne!(render(Look::Problem, size), a);
    }
}
