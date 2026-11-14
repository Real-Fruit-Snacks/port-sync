//! port-sync: keeps qBittorrent's listening port equal to the port Proton VPN forwards.
//! With no arguments it is the tray app; `--once` runs one sync for scripts and the installer.

// A GUI program, so signing in starts the tray without a console window flashing up.
// `--once` and `--version` attach to the console they were started from.
#![cfg_attr(all(windows, not(test)), windows_subsystem = "windows")]

mod config;
mod log;
mod platform;
mod proton;
mod qbit;
mod sync;
#[cfg(windows)]
mod tray;
#[cfg(windows)]
mod winutil;

#[cfg(test)]
mod testkit;
#[cfg(test)]
mod tests;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

fn attach_console() {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Console::{AttachConsole, GetStdHandle, ATTACH_PARENT_PROCESS, STD_OUTPUT_HANDLE};
        // Output redirected to a file or pipe already works; only attach for a terminal.
        let h = GetStdHandle(STD_OUTPUT_HANDLE);
        if h.is_null() || h == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
            AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }
}

fn run_once(args: &config::Args) -> i32 {
    let (settings, problems) = config::resolve(args);
    let _ = std::fs::create_dir_all(&settings.state_dir);
    let mut s = sync::Syncer::new(settings, true);
    for p in problems {
        s.log.line(&p);
    }
    sync::move_legacy_state(&s.settings, &mut s.log);
    s.log.line(&format!("port-sync {} watching {}", VERSION, s.settings.proton_logs.display()));
    if s.cycle().ok() {
        0
    } else {
        1
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = match config::parse_args(&argv) {
        Ok(a) => a,
        Err(e) => {
            attach_console();
            eprintln!("port-sync: {}\n\n{}", e, config::HELP);
            std::process::exit(2);
        }
    };
    if args.version {
        attach_console();
        println!("port-sync {}", VERSION);
        return;
    }
    if args.help {
        attach_console();
        print!("{}", config::HELP);
        return;
    }
    if args.once {
        attach_console();
        std::process::exit(run_once(&args));
    }
    #[cfg(windows)]
    {
        if args.quit {
            attach_console();
            std::process::exit(tray::quit_running());
        }
        std::process::exit(tray::run(&args));
    }
    #[cfg(not(windows))]
    {
        eprintln!("port-sync: the tray app is Windows only; use --once\n\n{}", config::HELP);
        std::process::exit(2);
    }
}
