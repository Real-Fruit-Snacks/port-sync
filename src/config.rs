//! Settings: the defaults, then `config.json` in the state folder, then the command line.
//! The flags keep the 2.x parameter names; `-QbitUrl`, `--qbit-url` and `--qbiturl` are the
//! same flag.

use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    pub qbit_url: String,
    pub qbit_user: String,
    pub proton_logs: PathBuf,
    /// The network adapter that must be up before syncing; empty skips the check.
    pub adapter: String,
    pub state_dir: PathBuf,
    pub interval_sec: u64,
    pub recheck_sec: u64,
    /// Tray notifications when the port changes or something needs fixing.
    pub notifications: bool,
}

pub const DEFAULT_QBIT_URL: &str = "http://127.0.0.1:8080";
pub const DEFAULT_ADAPTER: &str = "ProtonVPN";

fn local_app_data() -> PathBuf {
    match std::env::var_os("LOCALAPPDATA") {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => std::env::temp_dir(),
    }
}

pub fn default_state_dir() -> PathBuf {
    local_app_data().join("port-sync")
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            qbit_url: DEFAULT_QBIT_URL.into(),
            qbit_user: "admin".into(),
            proton_logs: local_app_data().join("Proton").join("Proton VPN").join("Logs"),
            adapter: DEFAULT_ADAPTER.into(),
            state_dir: default_state_dir(),
            interval_sec: 15,
            recheck_sec: 60,
            notifications: true,
        }
    }
}

impl Settings {
    pub fn config_path(&self) -> PathBuf {
        self.state_dir.join("config.json")
    }
    pub fn pass_file(&self) -> PathBuf {
        self.state_dir.join("qbit-pass.txt")
    }
    pub fn sync_log(&self) -> PathBuf {
        self.state_dir.join("sync.log")
    }
}

/// What the command line asked for.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Args {
    pub once: bool,
    pub version: bool,
    pub help: bool,
    /// Stop the running tray app (the installer uses this before replacing the exe).
    pub quit: bool,
    /// Set by the Run key entry; the tray starts the same either way.
    pub autostart: bool,
    pub qbit_url: Option<String>,
    pub qbit_user: Option<String>,
    pub proton_logs: Option<String>,
    pub adapter: Option<String>,
    pub state_dir: Option<String>,
    pub interval_sec: Option<u64>,
    pub recheck_sec: Option<u64>,
}

fn flag_key(a: &str) -> Option<String> {
    let s = a.strip_prefix("--").or_else(|| a.strip_prefix('-')).or_else(|| a.strip_prefix('/'))?;
    if s.is_empty() {
        return None;
    }
    Some(s.chars().filter(|c| *c != '-' && *c != '_').collect::<String>().to_ascii_lowercase())
}

pub fn parse_args(args: &[String]) -> Result<Args, String> {
    let mut a = Args::default();
    let mut i = 0;
    while i < args.len() {
        let raw = &args[i];
        // --name=value
        let (name, inline) = match raw.split_once('=') {
            Some((n, v)) if raw.starts_with('-') => (n.to_string(), Some(v.to_string())),
            _ => (raw.clone(), None),
        };
        let key = flag_key(&name).ok_or_else(|| format!("unexpected argument: {}", raw))?;
        let mut value = |what: &str| -> Result<String, String> {
            if let Some(v) = inline.clone() {
                return Ok(v);
            }
            i += 1;
            args.get(i).cloned().ok_or_else(|| format!("{} needs a value", what))
        };
        let number = |s: String, what: &str| -> Result<u64, String> {
            s.trim().parse::<u64>().map_err(|_| format!("{} needs a whole number of seconds, not '{}'", what, s))
        };
        match key.as_str() {
            "once" => a.once = true,
            "version" | "v" => a.version = true,
            "help" | "h" | "?" => a.help = true,
            "quit" => a.quit = true,
            "autostart" => a.autostart = true,
            "qbiturl" => a.qbit_url = Some(value("--qbit-url")?),
            "qbituser" => a.qbit_user = Some(value("--qbit-user")?),
            "protonlogs" => a.proton_logs = Some(value("--proton-logs")?),
            // An empty value skips the check. Windows PowerShell 5.1 can only pass one as '""'.
            "adapter" => a.adapter = Some(value("--adapter")?.trim_matches('"').to_string()),
            "statedir" => a.state_dir = Some(value("--state-dir")?),
            "intervalsec" => a.interval_sec = Some(number(value("--interval-sec")?, "--interval-sec")?),
            "rechecksec" => a.recheck_sec = Some(number(value("--recheck-sec")?, "--recheck-sec")?),
            _ => return Err(format!("unknown option: {}", raw)),
        }
        i += 1;
    }
    Ok(a)
}

pub const HELP: &str = "port-sync keeps qBittorrent's listening port equal to the port Proton VPN forwards.

Usage:
  port-sync                 the tray app (what the sign-in entry starts)
  port-sync --once          one sync, then exit 0 (in sync) or 1 (not; the output says why)
  port-sync --version       print the version
  port-sync --quit          stop the running tray app

Options (they override config.json in the state folder):
  --qbit-url <url>          qBittorrent Web UI address (http://127.0.0.1:8080)
  --qbit-user <name>        Web UI username (admin)
  --proton-logs <folder>    folder with Proton VPN's client-logs.txt
  --adapter <name>          adapter that must be up first (ProtonVPN); \"\" skips the check
  --state-dir <folder>      password file, config.json and sync.log (%LOCALAPPDATA%\\port-sync)
  --interval-sec <n>        how often to read the Proton log (15)
  --recheck-sec <n>         how often to re-read qBittorrent's port when Proton's hasn't changed (60)
";

/// The keys config.json may have, with the setting each one sets.
fn apply_key(s: &mut Settings, key: &str, v: &Value) -> Result<(), String> {
    let text = || v.as_str().map(|x| x.to_string()).ok_or_else(|| format!("\"{}\" should be text", key));
    let secs = || v.as_u64().ok_or_else(|| format!("\"{}\" should be a whole number of seconds", key));
    match key {
        "qbitUrl" => s.qbit_url = text()?,
        "qbitUser" => s.qbit_user = text()?,
        "protonLogs" => s.proton_logs = PathBuf::from(text()?),
        "adapter" => s.adapter = text()?,
        "intervalSec" => s.interval_sec = secs()?,
        "recheckSec" => s.recheck_sec = secs()?,
        "notifications" => s.notifications = v.as_bool().ok_or_else(|| "\"notifications\" should be true or false".to_string())?,
        _ => return Err(format!("unknown setting \"{}\"", key)),
    }
    Ok(())
}

/// Settings from config.json (if there is one) and the command line. Problems with
/// config.json come back as messages for the log; the setting keeps its default.
pub fn resolve(args: &Args) -> (Settings, Vec<String>) {
    let mut s = Settings::default();
    if let Some(d) = &args.state_dir {
        s.state_dir = PathBuf::from(d);
    }
    let mut problems = Vec::new();
    let path = s.config_path();
    match std::fs::read(&path) {
        Ok(bytes) => {
            let text = String::from_utf8_lossy(&bytes);
            let text = text.trim_start_matches('\u{feff}');
            if !text.trim().is_empty() {
                match serde_json::from_str::<Value>(text) {
                    Ok(Value::Object(m)) => {
                        for (k, v) in &m {
                            if let Err(e) = apply_key(&mut s, k, v) {
                                problems.push(format!("config.json: {}; using the default", e));
                            }
                        }
                    }
                    Ok(_) => problems.push("config.json should hold one { ... } object; using the defaults".into()),
                    Err(e) => problems.push(format!("config.json is not valid JSON ({}); using the defaults", e)),
                }
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => problems.push(format!("can't read {}: {}; using the defaults", path.display(), e)),
    }
    if let Some(v) = &args.qbit_url {
        s.qbit_url = v.clone();
    }
    if let Some(v) = &args.qbit_user {
        s.qbit_user = v.clone();
    }
    if let Some(v) = &args.proton_logs {
        s.proton_logs = PathBuf::from(v);
    }
    if let Some(v) = &args.adapter {
        s.adapter = v.clone();
    }
    if let Some(v) = args.interval_sec {
        s.interval_sec = v;
    }
    if let Some(v) = args.recheck_sec {
        s.recheck_sec = v;
    }
    s.qbit_url = s.qbit_url.trim().trim_end_matches('/').to_string();
    s.interval_sec = s.interval_sec.max(1);
    (s, problems)
}

/// config.json with every setting at its current value, for the tray's "Edit settings".
#[cfg_attr(not(windows), allow(dead_code))] // the tray's Edit settings
pub fn write_default_config(s: &Settings) -> std::io::Result<()> {
    let mut m = Map::new();
    m.insert("qbitUrl".into(), json!(s.qbit_url));
    m.insert("qbitUser".into(), json!(s.qbit_user));
    m.insert("protonLogs".into(), json!(s.proton_logs.to_string_lossy()));
    m.insert("adapter".into(), json!(s.adapter));
    m.insert("intervalSec".into(), json!(s.interval_sec));
    m.insert("recheckSec".into(), json!(s.recheck_sec));
    m.insert("notifications".into(), json!(s.notifications));
    std::fs::create_dir_all(&s.state_dir)?;
    let text = serde_json::to_string_pretty(&Value::Object(m)).unwrap_or_default().replace('\n', "\r\n") + "\r\n";
    std::fs::write(s.config_path(), text)
}

pub fn modified(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}
