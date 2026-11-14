//! Test helpers shared by the unit tests (src/tests.rs) and the command-line tests
//! (tests/cli.rs, which includes this file by path): temporary folders and a stand-in for
//! qBittorrent's Web UI.
#![allow(dead_code)]

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> Self {
        static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let p = std::env::temp_dir().join(format!("port-sync-test-{}-{}-{}", tag, std::process::id(), n));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(p.join("logs")).unwrap();
        std::fs::create_dir_all(p.join("state")).unwrap();
        TempDir(p)
    }
    pub fn path(&self) -> &Path {
        &self.0
    }
    pub fn logs(&self) -> PathBuf {
        self.0.join("logs")
    }
    pub fn state(&self) -> PathBuf {
        self.0.join("state")
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

// ---------------------------------------------------------------------------
// A stand-in for qBittorrent's Web UI
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
pub enum Style {
    /// qBittorrent 4.x: 200 "Ok." / 200 "Fails.", cookie SID.
    V4,
    /// qBittorrent 5.x: 204 on success, 401 "Fails.", a QBT_SID_<port> cookie.
    V5,
}

pub struct Fake {
    pub password: String,
    pub listen_port: i64,
    pub random_port: bool,
    pub upnp: bool,
    pub style: Style,
    pub banned: bool,
    /// setPreferences is accepted but changes nothing.
    pub stuck: bool,
    /// Logins succeed but the session is forgotten at once, so every later call gets a 403.
    pub forget: bool,
    pub sessions: Vec<String>,
    pub logins: u32,
    pub logouts: u32,
    pub next_sid: u32,
}

#[derive(Clone)]
pub struct FakeQbit {
    pub url: String,
    pub state: Arc<Mutex<Fake>>,
}

fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => match u8::from_str_radix(&s[i + 1..i + 3], 16) {
                Ok(v) => {
                    out.push(v);
                    i += 2;
                }
                Err(_) => out.push(b'%'),
            },
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn form(body: &str) -> HashMap<String, String> {
    body.split('&').filter_map(|kv| kv.split_once('=')).map(|(k, v)| (url_decode(k), url_decode(v))).collect()
}

impl FakeQbit {
    pub fn start(password: &str, listen_port: i64, style: Style) -> FakeQbit {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://127.0.0.1:{}", l.local_addr().unwrap().port());
        let state = Arc::new(Mutex::new(Fake {
            password: password.into(),
            listen_port,
            random_port: true,
            upnp: true,
            style,
            banned: false,
            stuck: false,
            forget: false,
            sessions: Vec::new(),
            logins: 0,
            logouts: 0,
            next_sid: 1,
        }));
        let st = Arc::clone(&state);
        std::thread::spawn(move || {
            for conn in l.incoming().flatten() {
                let st = Arc::clone(&st);
                std::thread::spawn(move || {
                    let _ = handle(conn, &st);
                });
            }
        });
        FakeQbit { url, state }
    }
}

fn handle(conn: std::net::TcpStream, st: &Mutex<Fake>) -> std::io::Result<()> {
    conn.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut r = BufReader::new(conn.try_clone()?);
    let mut out = conn;
    loop {
        let mut first = String::new();
        if r.read_line(&mut first)? == 0 {
            return Ok(());
        }
        let mut parts = first.split_whitespace();
        let method = parts.next().unwrap_or("").to_string();
        let path = parts.next().unwrap_or("").to_string();
        let mut headers = HashMap::new();
        loop {
            let mut h = String::new();
            r.read_line(&mut h)?;
            let h = h.trim_end();
            if h.is_empty() {
                break;
            }
            if let Some((k, v)) = h.split_once(':') {
                headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
            }
        }
        let len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut body = vec![0u8; len];
        r.read_exact(&mut body)?;
        let body = String::from_utf8_lossy(&body).into_owned();
        let cookie = headers.get("cookie").cloned().unwrap_or_default();

        let mut s = st.lock().unwrap();
        let authed = s.sessions.iter().any(|sid| cookie.split(';').any(|c| c.trim().split_once('=').map(|(_, v)| v) == Some(sid.as_str())));
        let (status, extra, text): (u16, String, String) = match (method.as_str(), path.as_str()) {
            ("POST", "/api/v2/auth/login") => {
                s.logins += 1;
                let f = form(&body);
                if s.banned {
                    (403, String::new(), "Your IP address has been banned after too many failed authentication attempts.".into())
                } else if f.get("username").map(|u| u.as_str()) == Some("admin") && f.get("password") == Some(&s.password) {
                    let sid = format!("sid{}", s.next_sid);
                    s.next_sid += 1;
                    if !s.forget {
                        s.sessions.push(sid.clone());
                    }
                    match s.style {
                        Style::V4 => (200, format!("Set-Cookie: SID={}; HttpOnly; SameSite=Strict; path=/\r\n", sid), "Ok.".into()),
                        Style::V5 => (204, format!("Set-Cookie: QBT_SID_8080={}; HttpOnly; path=/\r\n", sid), String::new()),
                    }
                } else {
                    match s.style {
                        Style::V4 => (200, String::new(), "Fails.".into()),
                        Style::V5 => (401, String::new(), "Fails.".into()),
                    }
                }
            }
            ("POST", "/api/v2/auth/logout") => {
                s.logouts += 1;
                s.sessions.retain(|sid| !cookie.contains(sid.as_str()));
                (200, String::new(), String::new())
            }
            (_, "/api/v2/app/preferences") if authed => (
                200,
                "Content-Type: application/json\r\n".into(),
                format!("{{\"listen_port\":{},\"random_port\":{},\"upnp\":{},\"web_ui_port\":8080}}", s.listen_port, s.random_port, s.upnp),
            ),
            ("POST", "/api/v2/app/setPreferences") if authed => {
                let f = form(&body);
                if !s.stuck {
                    if let Some(v) = f.get("json").and_then(|j| serde_json::from_str::<serde_json::Value>(j).ok()) {
                        if let Some(p) = v.get("listen_port").and_then(|p| p.as_i64()) {
                            s.listen_port = p;
                        }
                        if let Some(b) = v.get("random_port").and_then(|p| p.as_bool()) {
                            s.random_port = b;
                        }
                        if let Some(b) = v.get("upnp").and_then(|p| p.as_bool()) {
                            s.upnp = b;
                        }
                    }
                }
                (200, String::new(), String::new())
            }
            (_, p) if p.starts_with("/api/v2/") => (403, String::new(), "Forbidden".into()),
            _ => (404, String::new(), "Not Found".into()),
        };
        drop(s);
        let reason = match status {
            200 => "OK",
            204 => "No Content",
            401 => "Unauthorized",
            403 => "Forbidden",
            _ => "Not Found",
        };
        let resp = if status == 204 {
            format!("HTTP/1.1 204 {}\r\n{}\r\n", reason, extra)
        } else {
            format!("HTTP/1.1 {} {}\r\n{}Content-Length: {}\r\n\r\n{}", status, reason, extra, text.len(), text)
        };
        out.write_all(resp.as_bytes())?;
        out.flush()?;
    }
}
