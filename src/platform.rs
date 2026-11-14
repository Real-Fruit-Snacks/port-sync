//! What the sync needs from the OS: the Web UI password and whether the VPN adapter is up.
//!
//! On Windows the password file is what 2.x's installer wrote, `ConvertFrom-SecureString`
//! output: the password as UTF-16, encrypted with DPAPI to the Windows account, in hex. Only
//! that account can read it. Elsewhere (the tests against qbittorrent-nox on Linux) the file
//! holds the password as plain text.

use std::path::Path;

pub fn password_missing(path: &Path) -> String {
    format!("password file missing: {}", path.display())
}

pub fn password_unreadable(path: &Path) -> String {
    format!(
        "can't decrypt {} (it only opens for the Windows account that created it; re-run the installer as this account)",
        path.display()
    )
}

/// The Web UI password, or the message for the log when there is none to use.
pub fn read_password(path: &Path) -> Result<String, String> {
    let text = match std::fs::read(path) {
        Ok(b) => String::from_utf8_lossy(&b).trim().trim_start_matches('\u{feff}').trim().to_string(),
        Err(_) => return Err(password_missing(path)),
    };
    decode_password(&text).ok_or_else(|| password_unreadable(path))
}

#[cfg(windows)]
fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.is_empty() || !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

#[cfg(windows)]
fn decode_password(text: &str) -> Option<String> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB};
    let blob = hex_decode(text)?;
    let input = CRYPT_INTEGER_BLOB { cbData: blob.len() as u32, pbData: blob.as_ptr() as *mut u8 };
    let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    let ok = unsafe {
        CryptUnprotectData(
            &input,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out,
        )
    };
    if ok == 0 || out.pbData.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize) }.to_vec();
    unsafe {
        // Wipe the plain text before giving the buffer back.
        std::ptr::write_bytes(out.pbData, 0, out.cbData as usize);
        LocalFree(out.pbData.cast());
    }
    let (pairs, rest) = bytes.as_chunks::<2>();
    if !rest.is_empty() {
        return None;
    }
    let units: Vec<u16> = pairs.iter().map(|c| u16::from_le_bytes(*c)).collect();
    String::from_utf16(&units).ok()
}

#[cfg(not(windows))]
fn decode_password(text: &str) -> Option<String> {
    Some(text.to_string())
}

/// What `ConvertTo-SecureString $p -AsPlainText -Force | ConvertFrom-SecureString` writes.
#[cfg(all(windows, test))]
pub fn encode_password(plain: &str) -> String {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB};
    let bytes: Vec<u8> = plain.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    let input = CRYPT_INTEGER_BLOB { cbData: bytes.len() as u32, pbData: bytes.as_ptr() as *mut u8 };
    let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    let ok = unsafe {
        CryptProtectData(
            &input,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out,
        )
    };
    assert!(ok != 0, "CryptProtectData failed");
    let blob = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize) };
    let hex: String = blob.iter().map(|b| format!("{:02x}", b)).collect();
    unsafe {
        LocalFree(out.pbData.cast());
    }
    hex
}

#[cfg(all(not(windows), test))]
pub fn encode_password(plain: &str) -> String {
    plain.to_string()
}

/// Is the adapter with this name (as `Get-NetAdapter -Name` matches it) up? An empty name
/// skips the check.
pub fn adapter_up(name: &str) -> bool {
    if name.is_empty() {
        return true;
    }
    adapter_up_impl(name)
}

#[cfg(windows)]
fn adapter_up_impl(name: &str) -> bool {
    use windows_sys::Win32::Foundation::{ERROR_BUFFER_OVERFLOW, NO_ERROR};
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_MULTICAST, IP_ADAPTER_ADDRESSES_LH,
    };
    use windows_sys::Win32::NetworkManagement::Ndis::IfOperStatusUp;
    use windows_sys::Win32::Networking::WinSock::AF_UNSPEC;
    let want = name.to_lowercase();
    let flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    let mut size: u32 = 32 * 1024;
    for _ in 0..4 {
        // u64 elements keep the buffer aligned for the structs inside it.
        let mut buf = vec![0u64; (size as usize).div_ceil(8)];
        let first = buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH;
        let r = unsafe { GetAdaptersAddresses(AF_UNSPEC as u32, flags, std::ptr::null(), first, &mut size) };
        if r == ERROR_BUFFER_OVERFLOW {
            continue;
        }
        if r != NO_ERROR {
            return false;
        }
        let mut p = first;
        while !p.is_null() {
            let a = unsafe { &*p };
            if !a.FriendlyName.is_null() {
                let mut n = 0;
                while unsafe { *a.FriendlyName.add(n) } != 0 {
                    n += 1;
                }
                let friendly = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(a.FriendlyName, n) });
                if friendly.to_lowercase() == want {
                    return a.OperStatus == IfOperStatusUp;
                }
            }
            p = a.Next;
        }
        return false;
    }
    false
}

/// Linux (tests only): /sys/class/net/<name>/operstate.
#[cfg(not(windows))]
fn adapter_up_impl(name: &str) -> bool {
    std::fs::read_to_string(Path::new("/sys/class/net").join(name).join("operstate")).map(|s| s.trim() == "up").unwrap_or(false)
}
