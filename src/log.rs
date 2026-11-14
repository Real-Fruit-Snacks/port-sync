//! sync.log: one line per event, `yyyy-MM-dd HH:mm:ss [port-sync] message`, rotated to
//! sync.log.1 past 1 MB. `--once` also prints each line.

use std::io::Write;
use std::path::PathBuf;

pub const ROTATE_BYTES: u64 = 1024 * 1024;

pub struct Logger {
    pub path: PathBuf,
    pub echo: bool,
    /// The last condition logged with `note`, so a repeating one is logged once.
    pub last_note: String,
}

impl Logger {
    pub fn new(path: PathBuf, echo: bool) -> Self {
        Logger { path, echo, last_note: String::new() }
    }

    pub fn line(&mut self, message: &str) {
        let line = format!("{} [port-sync] {}", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"), message);
        if self.echo {
            let mut out = std::io::stdout().lock();
            let _ = writeln!(out, "{}", line);
            let _ = out.flush();
        }
        if std::fs::metadata(&self.path).map(|m| m.len() > ROTATE_BYTES).unwrap_or(false) {
            let mut old = self.path.clone().into_os_string();
            old.push(".1");
            let _ = std::fs::rename(&self.path, PathBuf::from(old));
        }
        if let Some(d) = self.path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = write!(f, "{}\r\n", line);
        }
    }

    /// Log a recurring condition only when it changes, so the log doesn't fill with repeats.
    pub fn note(&mut self, message: &str) {
        if message != self.last_note {
            self.line(message);
            self.last_note = message.to_string();
        }
    }
}
