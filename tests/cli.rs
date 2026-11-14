//! The built program, run the way the installer and scripts run it: `--once`, `--version`,
//! and bad arguments.

#[path = "../src/testkit.rs"]
mod testkit;

use std::process::Command;
use testkit::{FakeQbit, Style, TempDir};

const EXE: &str = env!("CARGO_BIN_EXE_port-sync");

fn run(args: &[&str]) -> (i32, String, String) {
    let out = Command::new(EXE).args(args).output().expect("run port-sync");
    (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
}

/// The password file the installer writes: DPAPI on Windows (via Windows PowerShell, as
/// install.ps1 does it), plain text elsewhere.
fn write_password(t: &TempDir, plain: &str) {
    let file = t.state().join("qbit-pass.txt");
    if cfg!(windows) {
        let cmd = format!(
            "ConvertTo-SecureString '{}' -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath '{}'",
            plain,
            file.display()
        );
        let ok = Command::new("powershell.exe").args(["-NoProfile", "-NonInteractive", "-Command", &cmd]).status().unwrap();
        assert!(ok.success());
    } else {
        std::fs::write(file, plain).unwrap();
    }
}

fn once(t: &TempDir, url: &str) -> (i32, String, String) {
    let logs = t.logs().display().to_string();
    let state = t.state().display().to_string();
    run(&["--once", "--qbit-url", url, "--proton-logs", &logs, "--state-dir", &state, "--adapter", ""])
}

#[test]
fn version() {
    let want = format!("port-sync {}\n", env!("CARGO_PKG_VERSION"));
    assert_eq!(run(&["--version"]).1.replace('\r', ""), want);
    assert_eq!(run(&["-Version"]).1.replace('\r', ""), want, "the 2.x spelling");
}

#[test]
fn help_and_bad_arguments() {
    let (code, out, _) = run(&["--help"]);
    assert_eq!(code, 0);
    assert!(out.contains("--once"));
    let (code, _, err) = run(&["--bogus"]);
    assert_eq!(code, 2);
    assert!(err.contains("unknown option: --bogus"), "{}", err);
}

#[test]
fn once_exits_1_with_nothing_to_sync() {
    let t = TempDir::new("cli1");
    std::fs::write(t.logs().join("client-logs.txt"), "Status updated to Disconnected\r\n").unwrap();
    let (code, out, _) = once(&t, "http://127.0.0.1:1");
    assert_eq!(code, 1);
    assert!(out.contains(&format!("[port-sync] port-sync {} watching {}", env!("CARGO_PKG_VERSION"), t.logs().display())), "{}", out);
    assert!(out.contains("[port-sync] no forwarded port in the Proton VPN log yet - waiting"), "{}", out);
}

#[test]
fn once_syncs_and_exits_0() {
    let q = FakeQbit::start("cli-pass", 49160, Style::V4);
    let t = TempDir::new("cli2");
    write_password(&t, "cli-pass");
    std::fs::write(t.logs().join("client-logs.txt"), "Port pair 48213->48213\r\n").unwrap();
    let (code, out, err) = once(&t, &q.url);
    assert_eq!(code, 0, "{}{}", out, err);
    assert!(out.contains("[port-sync] listening port updated: 49160 -> 48213"), "{}", out);
    let log = std::fs::read_to_string(t.state().join("sync.log")).unwrap();
    assert_eq!(log.lines().count(), 2, "{}", log);
    assert!(log.ends_with("listening port updated: 49160 -> 48213\r\n"));
    assert_eq!(q.state.lock().unwrap().listen_port, 48213);

    // Again: already correct, still 0.
    let (code, out, _) = once(&t, &q.url);
    assert_eq!(code, 0);
    assert!(out.contains("listening port already correct: 48213"), "{}", out);
}

#[test]
fn once_exits_1_when_the_login_is_rejected() {
    let q = FakeQbit::start("right", 49160, Style::V5);
    let t = TempDir::new("cli3");
    write_password(&t, "wrong");
    std::fs::write(t.logs().join("client-logs.txt"), "Port pair 48213->48213\r\n").unwrap();
    let (code, out, _) = once(&t, &q.url);
    assert_eq!(code, 1);
    assert!(out.contains("Web UI login rejected"), "{}", out);
}
