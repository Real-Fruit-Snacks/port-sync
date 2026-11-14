//! The forwarded port, from the Proton VPN app's client log. The app writes a line like
//! `... Port pair 54692->54692 ...` every few seconds while port forwarding runs; a
//! disconnect, or port forwarding stopping, makes the last port stale.

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

pub const TAIL_BYTES: u64 = 256 * 1024;

/// The last `max` bytes of a log, split into lines. Proton keeps writing to (and rotating)
/// the file while it is read; std opens files with every share mode, so that works.
pub fn read_tail(path: &Path, max: u64) -> Vec<String> {
    let Ok(mut f) = std::fs::File::open(path) else { return Vec::new() };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    if len > max && f.seek(SeekFrom::End(-(max as i64))).is_err() {
        return Vec::new();
    }
    let mut bytes = Vec::new();
    if f.read_to_end(&mut bytes).is_err() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&bytes);
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
    text.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l).to_string()).collect()
}

fn digits_at(s: &[u8], at: usize) -> Option<(u64, usize)> {
    let mut end = at;
    while end < s.len() && s[end].is_ascii_digit() {
        end += 1;
    }
    if end == at {
        return None;
    }
    // Too many digits to be a port: treat it as no port.
    let n = std::str::from_utf8(&s[at..end]).ok()?.parse::<u64>().unwrap_or(u64::MAX);
    Some((n, end))
}

/// `Port pair <digits>-><digits>`, case-insensitive like PowerShell's -match: the second
/// number of the first match in the line.
pub fn port_pair(line: &str) -> Option<u64> {
    let lower = line.to_ascii_lowercase();
    let s = lower.as_bytes();
    let needle = b"port pair ";
    let mut from = 0;
    while let Some(off) = lower[from..].find("port pair ") {
        let at = from + off + needle.len();
        if let Some((_, end)) = digits_at(s, at) {
            if s.get(end) == Some(&b'-') && s.get(end + 1) == Some(&b'>') {
                if let Some((n, _)) = digits_at(s, end + 2) {
                    return Some(n);
                }
            }
        }
        from = from + off + 1;
    }
    None
}

/// `Status updated to Disconnected`, or `Port forwarding status changed from '<x>' to 'Stopped'`.
pub fn is_stop(line: &str) -> bool {
    let lower = line.to_ascii_lowercase();
    if lower.contains("status updated to disconnected") {
        return true;
    }
    let lead = "port forwarding status changed from '";
    let mut from = 0;
    while let Some(off) = lower[from..].find(lead) {
        let rest = &lower[from + off + lead.len()..];
        if let Some(q) = rest.find('\'') {
            if q > 0 && rest[q..].starts_with("' to 'stopped'") {
                return true;
            }
        }
        from = from + off + 1;
    }
    false
}

/// The latest forwarded port in these lines, or None if the VPN has disconnected since.
pub fn port_from_lines<'a>(lines: impl IntoIterator<Item = &'a String>) -> Option<u32> {
    let mut port: Option<u64> = None;
    for l in lines {
        if let Some(p) = port_pair(l) {
            port = Some(p);
        } else if is_stop(l) {
            port = None;
        }
    }
    match port {
        Some(p) if (1..=65535).contains(&p) => Some(p as u32),
        _ => None,
    }
}

/// The rotated log first, then the current one, so the current file wins.
pub fn forwarded_port(logs: &Path) -> Option<u32> {
    let mut lines = read_tail(&logs.join("client-logs.1.txt"), TAIL_BYTES);
    lines.extend(read_tail(&logs.join("client-logs.txt"), TAIL_BYTES));
    port_from_lines(&lines)
}
