//! Small Win32 helpers for the tray: wide strings, the Run key, the clipboard, opening
//! things, and the status icons.

use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Graphics::Gdi::{
    CreateBitmap, CreateDIBSection, DeleteObject, GetDC, ReleaseDC, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
};
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegGetValueW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE,
    REG_OPTION_NON_VOLATILE, REG_SZ, RRF_RT_REG_SZ,
};
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::{CreateIconIndirect, HICON, ICONINFO, SW_SHOWNORMAL};

pub fn w(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Copy into a fixed-size UTF-16 field (NOTIFYICONDATAW's), cut to fit, NUL-terminated.
pub fn copy_w(dst: &mut [u16], s: &str) {
    let v: Vec<u16> = s.encode_utf16().take(dst.len() - 1).collect();
    dst[..v.len()].copy_from_slice(&v);
    dst[v.len()] = 0;
}

pub fn shell_open(target: &str, args: Option<&str>) -> bool {
    let op = w("open");
    let t = w(target);
    let a = args.map(w);
    let r = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            op.as_ptr(),
            t.as_ptr(),
            a.as_ref().map(|v| v.as_ptr()).unwrap_or(std::ptr::null()),
            std::ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    r as isize > 32
}

// ---------------------------------------------------------------------------
// Start at sign-in: HKCU\Software\Microsoft\Windows\CurrentVersion\Run, no admin rights needed
// ---------------------------------------------------------------------------

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
pub const RUN_VALUE: &str = "port-sync";

pub fn exe_path() -> String {
    std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default()
}

pub fn startup_enabled() -> bool {
    let key = w(RUN_KEY);
    let val = w(RUN_VALUE);
    let mut buf = vec![0u16; 2048];
    let mut len = (buf.len() * 2) as u32;
    let r = unsafe {
        RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), val.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr().cast(), &mut len)
    };
    if r != 0 {
        return false;
    }
    let s = String::from_utf16_lossy(&buf[..(len as usize / 2).saturating_sub(1)]);
    !s.is_empty() && s.to_lowercase().contains(&exe_path().to_lowercase())
}

/// Ok, or the registry error code.
pub fn set_startup(enable: bool) -> Result<(), u32> {
    let key = w(RUN_KEY);
    let mut h: HKEY = std::ptr::null_mut();
    let r = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            key.as_ptr(),
            0,
            std::ptr::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            std::ptr::null(),
            &mut h,
            std::ptr::null_mut(),
        )
    };
    if r != 0 {
        return Err(r);
    }
    let val = w(RUN_VALUE);
    let res = unsafe {
        if enable {
            let data = w(&format!("\"{}\" --autostart", exe_path()));
            RegSetValueExW(h, val.as_ptr(), 0, REG_SZ, data.as_ptr().cast(), (data.len() * 2) as u32)
        } else {
            match RegDeleteValueW(h, val.as_ptr()) {
                2 => 0, // not there: already off
                e => e,
            }
        }
    };
    unsafe {
        RegCloseKey(h);
    }
    if res == 0 {
        Ok(())
    } else {
        Err(res)
    }
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

pub fn copy_text(hwnd: HWND, text: &str) -> bool {
    use windows_sys::Win32::Foundation::GlobalFree;
    use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
    use windows_sys::Win32::System::Ole::CF_UNICODETEXT;
    let data = w(text);
    unsafe {
        if OpenClipboard(hwnd) == 0 {
            return false;
        }
        EmptyClipboard();
        let bytes = data.len() * 2;
        let mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
        let mut ok = false;
        if !mem.is_null() {
            let p = GlobalLock(mem) as *mut u16;
            if !p.is_null() {
                std::ptr::copy_nonoverlapping(data.as_ptr(), p, data.len());
                GlobalUnlock(mem);
                ok = !SetClipboardData(CF_UNICODETEXT as u32, mem).is_null();
            }
            if !ok {
                GlobalFree(mem);
            }
        }
        CloseClipboard();
        ok
    }
}

// ---------------------------------------------------------------------------
// Icons: the app's mark (two bars on a dark tile, docs/icon.svg), drawn at the size the tray
// wants, with the bars' colours saying the state.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Look {
    /// Proton's bar amber, qBittorrent's mint: in sync.
    InSync,
    /// Both bars grey: waiting for the VPN, Proton or qBittorrent.
    Waiting,
    /// qBittorrent's bar pink: something needs fixing.
    Problem,
}

type Rgb = (u8, u8, u8);
const TILE: Rgb = (0x0C, 0x0D, 0x10);
const AMBER: Rgb = (0xFF, 0xC2, 0x47);
const MINT: Rgb = (0x3D, 0xDC, 0x97);
const RASP: Rgb = (0xF0, 0x62, 0x92);
const GREY: Rgb = (0x6B, 0x70, 0x7A);

/// Coverage of a rounded rectangle at (x, y), in the icon's 64-unit space.
fn in_rrect(x: f32, y: f32, rx: f32, ry: f32, rw: f32, rh: f32, r: f32) -> bool {
    let cx = x.clamp(rx + r, rx + rw - r);
    let cy = y.clamp(ry + r, ry + rh - r);
    let (dx, dy) = (x - cx, y - cy);
    x >= rx && x <= rx + rw && y >= ry && y <= ry + rh && dx * dx + dy * dy <= r * r
}

/// Straight-alpha BGRA pixels, top row first, 4x4 supersampled.
pub fn render(look: Look, size: u32) -> Vec<u8> {
    let (top, bottom) = match look {
        Look::InSync => (AMBER, MINT),
        Look::Waiting => (GREY, GREY),
        Look::Problem => (AMBER, RASP),
    };
    let n = 4;
    let scale = 64.0 / size as f32;
    let mut px = vec![0u8; (size * size * 4) as usize];
    for py in 0..size {
        for pxi in 0..size {
            let (mut a, mut r, mut g, mut b) = (0f32, 0f32, 0f32, 0f32);
            for sy in 0..n {
                for sx in 0..n {
                    let x = (pxi as f32 + (sx as f32 + 0.5) / n as f32) * scale;
                    let y = (py as f32 + (sy as f32 + 0.5) / n as f32) * scale;
                    if !in_rrect(x, y, 0.0, 0.0, 64.0, 64.0, 14.0) {
                        continue;
                    }
                    let c = if in_rrect(x, y, 12.0, 16.0, 40.0, 12.0, 2.5) {
                        top
                    } else if in_rrect(x, y, 12.0, 36.0, 40.0, 12.0, 2.5) {
                        bottom
                    } else {
                        TILE
                    };
                    a += 1.0;
                    r += c.0 as f32;
                    g += c.1 as f32;
                    b += c.2 as f32;
                }
            }
            let i = ((py * size + pxi) * 4) as usize;
            if a > 0.0 {
                px[i] = (b / a).round() as u8;
                px[i + 1] = (g / a).round() as u8;
                px[i + 2] = (r / a).round() as u8;
                px[i + 3] = (a / (n * n) as f32 * 255.0).round() as u8;
            }
        }
    }
    px
}

pub fn make_icon(look: Look, size: u32) -> HICON {
    let pixels = render(look, size);
    unsafe {
        let mut bi: BITMAPINFO = std::mem::zeroed();
        bi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
        bi.bmiHeader.biWidth = size as i32;
        bi.bmiHeader.biHeight = -(size as i32); // top-down
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        let dc = GetDC(std::ptr::null_mut());
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let color = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &mut bits, std::ptr::null_mut(), 0);
        ReleaseDC(std::ptr::null_mut(), dc);
        if color.is_null() || bits.is_null() {
            return std::ptr::null_mut();
        }
        std::ptr::copy_nonoverlapping(pixels.as_ptr(), bits as *mut u8, pixels.len());
        let mask_bytes = vec![0u8; (size.div_ceil(16) * 2 * size) as usize];
        let mask = CreateBitmap(size as i32, size as i32, 1, 1, mask_bytes.as_ptr().cast());
        let info = ICONINFO { fIcon: 1, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color };
        let icon = CreateIconIndirect(&info);
        DeleteObject(color);
        DeleteObject(mask);
        icon
    }
}
