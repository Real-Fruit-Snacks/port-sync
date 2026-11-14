//! One sync cycle, as 2.x's `Sync-Port` did it: VPN up, forwarded port known, then make
//! qBittorrent listen on it. The tray runs a cycle every `interval_sec`; `--once` runs one.

use crate::config::Settings;
use crate::log::Logger;
use crate::{platform, proton, qbit};
use std::time::{Duration, Instant, SystemTime};

/// After a rejected login, try again after 30 minutes even if the password file is
/// unchanged (qBittorrent bans an address after 5 failed logins in a row).
pub const AUTH_RETRY: Duration = Duration::from_secs(1800);

pub const LOGIN_REJECTED: &str = "Web UI login rejected (wrong password, or address banned). Fix the password, fully quit and reopen qBittorrent; next try when the password file changes or in 30 min.";
pub const NOT_REACHABLE: &str = "qBittorrent Web UI not reachable (not running?) - will retry";
pub const NO_PORT: &str = "no forwarded port in the Proton VPN log yet - waiting";

#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    /// qBittorrent listens on Proton's port.
    InSync { port: u32 },
    /// It didn't; port-sync set it.
    Updated { from: i64, to: u32 },
    /// Nothing to do until the VPN, Proton or qBittorrent comes up.
    Waiting(String),
    /// Something the user has to fix (or an error); the message says what.
    Problem(String),
}

impl Outcome {
    pub fn ok(&self) -> bool {
        matches!(self, Outcome::InSync { .. } | Outcome::Updated { .. })
    }
}

pub struct Syncer {
    pub settings: Settings,
    pub log: Logger,
    pub last_port: Option<u32>,
    pub last_check: Option<Instant>,
    pub auth_failed_for: Option<SystemTime>,
    pub auth_failed_at: Option<Instant>,
    /// What the last cycle saw, for the tray.
    pub proton_port: Option<u32>,
    pub qbit_port: Option<i64>,
}

impl Syncer {
    pub fn new(settings: Settings, echo: bool) -> Self {
        let log = Logger::new(settings.sync_log(), echo);
        Syncer {
            settings,
            log,
            last_port: None,
            last_check: None,
            auth_failed_for: None,
            auth_failed_at: None,
            proton_port: None,
            qbit_port: None,
        }
    }

    /// New settings from config.json: keep the state, re-read qBittorrent at the next cycle.
    pub fn reconfigure(&mut self, settings: Settings) {
        self.log.path = settings.sync_log();
        self.settings = settings;
        self.last_check = None;
    }

    /// Make the next cycle ask qBittorrent even if Proton's port hasn't changed.
    pub fn force_check(&mut self) {
        self.last_check = None;
    }

    /// One cycle. Errors become a logged `error: ...` line, as 2.x's loop did.
    pub fn cycle(&mut self) -> Outcome {
        match self.sync_port() {
            Ok(o) => o,
            Err(e) => {
                let m = format!("error: {}", e);
                self.log.note(&m);
                Outcome::Problem(m)
            }
        }
    }

    fn sync_port(&mut self) -> Result<Outcome, String> {
        if !platform::adapter_up(&self.settings.adapter) {
            let m = format!("VPN adapter '{}' is not up - waiting", self.settings.adapter);
            self.log.note(&m);
            self.proton_port = None;
            return Ok(Outcome::Waiting(m));
        }
        let Some(port) = proton::forwarded_port(&self.settings.proton_logs) else {
            self.log.note(NO_PORT);
            self.proton_port = None;
            return Ok(Outcome::Waiting(NO_PORT.into()));
        };
        self.proton_port = Some(port);

        let due = self.last_check.map(|t| t.elapsed() >= Duration::from_secs(self.settings.recheck_sec)).unwrap_or(true);
        if self.last_port == Some(port) && !due {
            return Ok(Outcome::InSync { port });
        }

        // After a rejected login, wait for the password file to change or 30 minutes to pass.
        let pass_file = self.settings.pass_file();
        let stamp = crate::config::modified(&pass_file);
        if let (Some(failed_for), Some(at)) = (self.auth_failed_for, self.auth_failed_at) {
            if Some(failed_for) == stamp && at.elapsed() < AUTH_RETRY {
                return Ok(Outcome::Problem(LOGIN_REJECTED.into()));
            }
        }

        let password = match platform::read_password(&pass_file) {
            Ok(p) => p,
            Err(m) => {
                self.log.note(&m);
                return Ok(Outcome::Problem(m));
            }
        };
        let session = match qbit::login(&self.settings.qbit_url, &self.settings.qbit_user, &password) {
            Ok(s) => s,
            Err(qbit::LoginError::Rejected) => {
                self.auth_failed_for = stamp;
                self.auth_failed_at = Some(Instant::now());
                self.log.line(LOGIN_REJECTED);
                return Ok(Outcome::Problem(LOGIN_REJECTED.into()));
            }
            Err(qbit::LoginError::Unreachable) => {
                self.auth_failed_for = None;
                self.log.note(NOT_REACHABLE);
                self.qbit_port = None;
                return Ok(Outcome::Waiting(NOT_REACHABLE.into()));
            }
        };
        self.auth_failed_for = None;
        let result = self.set_if_needed(&session, port);
        session.logout();
        result
    }

    fn set_if_needed(&mut self, session: &qbit::Session, port: u32) -> Result<Outcome, String> {
        let current = session.listen_port()?;
        self.last_check = Some(Instant::now());
        self.qbit_port = Some(current);
        if current == port as i64 {
            if self.last_port != Some(port) {
                self.log.line(&format!("listening port already correct: {}", port));
            }
            self.last_port = Some(port);
            self.log.last_note.clear();
            return Ok(Outcome::InSync { port });
        }
        session.set_port(port)?;
        let after = session.listen_port()?;
        self.qbit_port = Some(after);
        if after == port as i64 {
            self.log.line(&format!("listening port updated: {} -> {}", current, port));
            self.last_port = Some(port);
            self.log.last_note.clear();
            return Ok(Outcome::Updated { from: current, to: port });
        }
        let m = format!("failed to set port (qBittorrent still reports {})", after);
        self.log.line(&m);
        Ok(Outcome::Problem(m))
    }
}

/// Settle into the 2.x state folder name. 1.x kept its files in
/// %LOCALAPPDATA%\proton-qbit-port-sync.
pub fn move_legacy_state(s: &Settings, log: &mut Logger) {
    let Some(base) = std::env::var_os("LOCALAPPDATA").filter(|v| !v.is_empty()) else { return };
    let old = std::path::PathBuf::from(base).join("proton-qbit-port-sync");
    let old_pass = old.join("qbit-pass.txt");
    let pass = s.pass_file();
    if old_pass.exists() && !pass.exists() && std::fs::copy(&old_pass, &pass).is_ok() {
        log.line(&format!("copied the 1.x password file from {}", old.display()));
    }
}
