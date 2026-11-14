//! qBittorrent's Web UI API: log in, read and set the listening port, log out.

use std::time::Duration;

pub enum LoginError {
    /// qBittorrent answered, and refused: a wrong password, or the address is banned.
    Rejected,
    /// Nothing answered: qBittorrent isn't running, or the Web UI is off.
    Unreachable,
}

pub struct Session {
    agent: ureq::Agent,
    base: String,
    cookies: String,
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(Duration::from_secs(20)).user_agent(concat!("port-sync/", env!("CARGO_PKG_VERSION"))).build()
}

fn cookie_pairs(resp: &ureq::Response) -> String {
    resp.all("set-cookie")
        .iter()
        .filter_map(|c| c.split(';').next())
        .map(|c| c.trim())
        .filter(|c| c.contains('=') && !c.ends_with('='))
        .collect::<Vec<_>>()
        .join("; ")
}

fn describe(path: &str, e: ureq::Error) -> String {
    match e {
        ureq::Error::Status(code, _) => format!("qBittorrent answered {} to {}", code, path),
        ureq::Error::Transport(t) => format!("{} failed: {}", path, t),
    }
}

pub fn login(base: &str, user: &str, password: &str) -> Result<Session, LoginError> {
    let a = agent();
    match a.post(&format!("{}/api/v2/auth/login", base)).send_form(&[("username", user), ("password", password)]) {
        Ok(r) => {
            let cookies = cookie_pairs(&r);
            // qBittorrent 4.x answers 200 "Ok." / 200 "Fails."; 5.x answers an empty 204.
            let body = r.into_string().unwrap_or_default();
            if body.contains("Fails") {
                return Err(LoginError::Rejected);
            }
            Ok(Session { agent: a, base: base.to_string(), cookies })
        }
        // Any HTTP error (401, 403) means it answered: a bad login or a ban.
        Err(ureq::Error::Status(..)) => Err(LoginError::Rejected),
        Err(ureq::Error::Transport(_)) => Err(LoginError::Unreachable),
    }
}

impl Session {
    fn get(&self, path: &str) -> ureq::Request {
        let r = self.agent.get(&format!("{}{}", self.base, path));
        if self.cookies.is_empty() {
            r
        } else {
            r.set("Cookie", &self.cookies)
        }
    }

    fn post(&self, path: &str) -> ureq::Request {
        let r = self.agent.post(&format!("{}{}", self.base, path));
        if self.cookies.is_empty() {
            r
        } else {
            r.set("Cookie", &self.cookies)
        }
    }

    pub fn listen_port(&self) -> Result<i64, String> {
        let path = "/api/v2/app/preferences";
        let body = self.get(path).call().map_err(|e| describe(path, e))?.into_string().map_err(|e| format!("{}: {}", path, e))?;
        let v: serde_json::Value = serde_json::from_str(&body).map_err(|_| format!("{} did not answer JSON", path))?;
        v.get("listen_port").and_then(|p| p.as_i64()).ok_or_else(|| format!("{} has no listen_port", path))
    }

    /// Sets the port, and turns off the random port and UPnP, which would change it again.
    pub fn set_port(&self, port: u32) -> Result<(), String> {
        let path = "/api/v2/app/setPreferences";
        let json = format!("{{\"listen_port\":{},\"random_port\":false,\"upnp\":false}}", port);
        self.post(path).send_form(&[("json", &json)]).map_err(|e| describe(path, e))?;
        Ok(())
    }

    /// Each check logs in; log out again so qBittorrent doesn't hold an hour-long session
    /// per check.
    pub fn logout(&self) {
        let _ = self.post("/api/v2/auth/logout").send_string("");
    }
}
