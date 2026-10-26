# Setup guide: Proton VPN and qBittorrent on Windows

The goal: your ISP sees encrypted VPN traffic and never torrent traffic, including when the VPN drops. Then [port-sync](../README.md) keeps qBittorrent's listening port equal to the one Proton forwards.

You need:

- Windows 10 or 11
- A paid [Proton VPN](https://protonvpn.com/) plan (P2P servers and port forwarding are paid features)
- [qBittorrent](https://www.qbittorrent.org/) 4.x or 5.x
- Windows PowerShell 5.1 (built in) or PowerShell 7

Contents:

- [How the protection works](#how-the-protection-works)
- Setup: [1 install](#1-install-the-apps) · [2 configure Proton VPN](#2-configure-the-proton-vpn-app) · [3 connect](#3-connect-to-a-p2p-server) · [4 port forwarding](#4-turn-on-port-forwarding) · [5 lock down qBittorrent](#5-lock-down-qbittorrent) · [6 prove it](#6-prove-it-works) · [7 port sync](#7-port-sync)
- [Installing port-sync by hand](#installing-port-sync-by-hand)
- [Manual fallback](#manual-fallback)
- [Optional qBittorrent settings](#optional-qbittorrent-settings)
- [Troubleshooting](#troubleshooting)
- [Quick reference](#quick-reference)
- [Sources](#sources)

## How the protection works

Two layers, each enough on its own:

| Layer | What it does | Scope |
| --- | --- | --- |
| Kill switch (Advanced) | Blocks all internet unless connected to Proton VPN; survives reboots ([Proton](https://protonvpn.com/support/advanced-kill-switch)) | Whole system |
| qBittorrent bound to `ProtonVPN` | qBittorrent's only network path is the VPN adapter; no VPN, downloads stall at once ([Proton](https://protonvpn.com/support/bittorrent-vpn)) | qBittorrent only |

Split tunneling stays off. It isn't needed, though on Windows it works alongside the kill switch and has an Include mode ([Proton](https://protonvpn.com/support/protonvpn-split-tunneling)).

### Windows and Linux differences

If you're coming from a Linux setup (the official Proton CLI or app on an Arch-based distro, say):

| Thing | Linux | Windows |
| --- | --- | --- |
| VPN interface to bind | `proton0` (WireGuard), `tun0` (OpenVPN) | `ProtonVPN` (WireGuard or Stealth), `ProtonVPN TUN` (OpenVPN) |
| Forwarded port source | File `/run/user/$UID/Proton/VPN/forwarded_port` | No port file. Shown in the app; port-sync reads it from the app's log |
| Port sync | bash + inotify + systemd user service | PowerShell script + Task Scheduler task |
| Web UI password storage | Plain text in the script | Encrypted to your Windows account (DPAPI) |
| qBittorrent settings menu | Tools → Preferences | Tools → Options |
| New risk | None | The Advanced kill switch can block Microsoft-account sign-in (step 2) |

## Setup

### 1. Install the apps

```powershell
winget install Proton.ProtonVPN
winget install qBittorrent.qBittorrent
```

Or use the installers from [protonvpn.com/download-windows](https://protonvpn.com/download-windows) and [qbittorrent.org](https://www.qbittorrent.org/download).

### 2. Configure the Proton VPN app

Sign in, then open **Settings**:

- **Connection → Protocol: WireGuard.** Not Smart: the protocol decides the adapter name used in step 5.
- **Connection → Kill switch: on → Advanced → Apply.** No internet at all without the VPN, across reboots.
- **Split tunneling: off.**
- Turn on launch at Windows startup and auto-connect.

> **Before turning on Advanced, create a local Windows account as a backup.** If Windows demands an online Microsoft-account sign-in (after a password change, a major update, or a BIOS update), the kill switch blocks it and you can be locked out. Proton says there is no easy fix and recommends a backup local account ([Proton](https://protonvpn.com/support/advanced-kill-switch)).

Use **Standard** instead if you sometimes need internet without the VPN. It only engages on accidental drops.

LAN access (printers, NAS) is **Settings → Connection → Advanced settings → Allow LAN connections**, on by default ([Proton](https://protonvpn.com/support/lan-connections)). Proton's docs don't say how it behaves under the Advanced kill switch, so test your printer after turning it on.

### 3. Connect to a P2P server

**Countries → P2P tab** → pick a country or server → Connect ([Proton](https://protonvpn.com/support/bittorrent-vpn)). The nearest one with the lowest load. Skip Secure Core for torrenting.

Check the tunnel:

```powershell
curl.exe ifconfig.me
```

It should show a Proton IP, not yours. Run it once before connecting to compare. `curl.exe`, not `curl`: in Windows PowerShell plain `curl` is a different command.

### 4. Turn on port forwarding

While connected to the P2P server: **Port forwarding** in the right sidebar → on → **Apply**. Turn on its **Notifications** option too ([Proton](https://protonvpn.com/support/port-forwarding)).

Hover over **Port forwarding** to see the active port number. You need it in step 5.

### 5. Lock down qBittorrent

1. Keep the VPN connected (the adapter has to exist), then open qBittorrent.
2. **Tools → Options → Advanced → Network interface →** `ProtonVPN`
   - `ProtonVPN TUN` if you switch to OpenVPN. Change this setting whenever you change protocols.
3. **Connection tab:**
   - **Port used for incoming connections:** the number from step 4
   - Untick "Use UPnP / NAT-PMP port forwarding from my router"
4. **OK**, then restart qBittorrent.

### 6. Prove it works

1. Start a legal test torrent, an Ubuntu ISO for example.
2. Mid-download, disconnect the VPN. The download must stall to zero peers.
3. Reconnect. It resumes.

If it kept downloading while disconnected, the binding didn't take. Recheck `ProtonVPN` in step 5.

### 7. Port sync

Proton usually changes the forwarded port every time you reconnect ([Proton](https://protonvpn.com/support/port-forwarding)), so the number from step 4 goes stale. In a normal PowerShell window:

```powershell
irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1 | iex
```

The installer prints a Web UI password and copies it to the clipboard. Before pressing Enter, in qBittorrent **Tools → Options → Web UI**:

- Tick **Web User Interface (Remote control)**
- IP address `127.0.0.1`, port `8080`
- Authentication: username `admin`, password = the one it printed
- Leave **"Bypass authentication for clients on localhost"** unticked
- Leave **"Enable Host header validation"** on. Only turn it off if logins are rejected with a correct password.
- **OK**

Then press Enter. Expect `listening port updated: <old> -> <new>` or `listening port already correct: <port>`, matching the port the Proton app shows. Reconnect the VPN to watch it follow: within about 15 seconds of the app showing a new port, `sync.log` shows the update.

## Installing port-sync by hand

For anyone who'd rather not pipe a script into PowerShell. This is what `install.ps1` does.

```powershell
# 1. Folder and an encrypted Web UI password (paste it into qBittorrent, see step 7)
$dir = "$env:LOCALAPPDATA\port-sync"
New-Item -ItemType Directory -Force $dir | Out-Null
$bytes = New-Object byte[] 12
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$pw = -join ($bytes | ForEach-Object { $_.ToString('x2') })
ConvertTo-SecureString $pw -AsPlainText -Force | ConvertFrom-SecureString | Set-Content "$dir\qbit-pass.txt"
$pw | Set-Clipboard; "Web UI password (copied): $pw"

# 2. The script
Invoke-WebRequest 'https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/port-sync.ps1' -OutFile "$dir\port-sync.ps1"

# 3. One test run (VPN connected, port forwarding on, qBittorrent open)
powershell -NoProfile -ExecutionPolicy Bypass -File "$dir\port-sync.ps1" -Once
```

Then, in PowerShell **as administrator** (Task Scheduler wants admin to create a sign-in trigger), but for the account you torrent with, since the password file only decrypts for that account:

```powershell
$user     = "$env:USERDOMAIN\$env:USERNAME"
$script   = "$env:LOCALAPPDATA\port-sync\port-sync.ps1"
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
$princ    = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'port-sync' -Action $action -Trigger $trigger -Principal $princ -Settings $settings
Start-ScheduledTask -TaskName 'port-sync'
```

## Manual fallback

With the task off and speeds down: hover over **Port forwarding** in the Proton VPN app, then type the active port into qBittorrent → Tools → Options → Connection → Port used for incoming connections.

## Optional qBittorrent settings

Already covered above: UPnP/NAT-PMP off, bound to `ProtonVPN`, Web UI on localhost only.

| Setting | Where | Value | Why |
| --- | --- | --- | --- |
| Use different port on each startup | Connection | Off (default) | Would override the port port-sync sets |
| Encryption mode | BitTorrent → Privacy | Allow encryption (default) | Traffic is already inside the tunnel; "Require" only shrinks the peer pool ([VPN University](https://www.vpnuniversity.com/bittorrent/torrent-clients/qbittorrent-guide)) |
| Anonymous mode | BitTorrent → Privacy | Optional on public trackers; off on private trackers | Strips the client fingerprint, which some private trackers use to identify clients ([TRaSH Guides](https://trash-guides.info/Downloaders/qBittorrent/Basic-Setup/)) |
| DHT / PeX / Local Peer Discovery | BitTorrent → Privacy | On (defaults) | Peer discovery for public torrents; the binding forces it through the VPN. Private torrents turn DHT/PeX off per torrent |
| Inhibit system sleep | Behavior | On (laptops) | Keeps downloads running when power saving kicks in |
| Upload rate limit | Speed | About 70-80% of your real upload speed | Keeps the rest of the connection usable while seeding |
| Seeding limits | BitTorrent → Seeding Limits | To stop seeding after download: "When ratio reaches" → 0, then stop the torrent ([qBittorrent wiki](https://github.com/qbittorrent/qBittorrent/wiki/How-to-disable-auto-seed)) | You still upload while downloading. On private trackers this counts as hit-and-run, so seed properly there |

If qBittorrent closes to the tray, the X button only hides it. File → Exit (or tray right-click → Exit) quits, which matters when clearing a Web UI login ban.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| No internet at all | The Advanced kill switch working as designed. Connect in Proton VPN, or set Kill switch to Off or Standard. If the app is broken or uninstalled and you're still blocked, reinstall it and turn the kill switch off from there |
| Can't sign in to Windows after an update or password change | Microsoft-account sign-in needs internet, which the kill switch blocks. Sign in with the backup local account from step 2, then connect the VPN |
| Torrents stalled while the VPN is connected | Check Tools → Options → Advanced → Network interface is still `ProtonVPN`; `ProtonVPN TUN` on OpenVPN. If it stalls right after a reconnect, restart qBittorrent; some Windows users report the binding needs that ([gist thread](https://gist.github.com/thejorro/a63dfa17e6e25a85d7a2f9ddd8c6a652)) |
| Downloads slow but everything connected | The port rotated. Check `sync.log`, or use the manual fallback |
| sync.log: `Web UI login rejected` | Re-run the installer after deleting `%LOCALAPPDATA%\port-sync\qbit-pass.txt`, paste the new password into the Web UI settings, then fully quit and reopen qBittorrent to clear any ban. If the password is right, untick "Enable Host header validation" |
| sync.log: `can't decrypt ...qbit-pass.txt` | The file was made by another Windows account. Re-run the installer as the account you torrent with |
| sync.log: `no forwarded port in the Proton VPN log yet` | Confirm you're on a P2P server with port forwarding on, then run the `Select-String` line from the quick reference. No matches means your app version logs elsewhere or differently: open an issue with a redacted sample line |
| sync.log: `VPN adapter 'ProtonVPN' is not up` | `Get-NetAdapter` while connected shows the real name. On OpenVPN, add `-Adapter 'ProtonVPN TUN'` to the task ([README](../README.md#configuration)) |
| sync.log: `qBittorrent Web UI not reachable` | qBittorrent isn't running, or the Web UI is off or on another port |
| "Running scripts is disabled on this system" | Start it with `powershell -ExecutionPolicy Bypass -File ...` as the task does |
| Sync stopped after sign-in | `Get-ScheduledTaskInfo port-sync` shows the last run result; `Start-ScheduledTask port-sync` starts it |

## Quick reference

```powershell
# Install the apps
winget install Proton.ProtonVPN
winget install qBittorrent.qBittorrent

# Public IP (should be Proton's)
curl.exe ifconfig.me

# VPN adapter name and state
Get-NetAdapter | Where-Object Name -like 'ProtonVPN*'

# Latest forwarded port in the Proton VPN log
Select-String -Path "$env:LOCALAPPDATA\Proton\Proton VPN\Logs\client-logs.txt" -Pattern 'Port pair' | Select-Object -Last 1

# qBittorrent Web UI probe ("Forbidden" = running, login required; no reply = not running)
curl.exe -s http://127.0.0.1:8080/api/v2/app/webapiVersion

# port-sync: one-off run, live log, task status, restart, remove
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\port-sync\port-sync.ps1" -Once
Get-Content "$env:LOCALAPPDATA\port-sync\sync.log" -Wait -Tail 20
Get-ScheduledTaskInfo port-sync
Stop-ScheduledTask port-sync; Start-ScheduledTask port-sync
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1))) -Uninstall
```

## Sources

- [Proton VPN: How to use kill switch](https://protonvpn.com/support/what-is-kill-switch)
- [Proton VPN: How to use advanced kill switch](https://protonvpn.com/support/advanced-kill-switch)
- [Proton VPN: P2P servers and binding qBittorrent](https://protonvpn.com/support/bittorrent-vpn)
- [Proton VPN: Port forwarding](https://protonvpn.com/support/port-forwarding)
- [Proton VPN: Split tunneling](https://protonvpn.com/support/protonvpn-split-tunneling)
- [Proton VPN: LAN connections](https://protonvpn.com/support/lan-connections)
- [EudesRobin/qbit-proton-port](https://github.com/EudesRobin/qbit-proton-port) and [Jaques-and-sons/ProtonVPN-qBittorrent-Auto-Port-Sync](https://github.com/Jaques-and-sons/ProtonVPN-qBittorrent-Auto-Port-Sync): Proton log path and line format
- [qBittorrent Web UI API](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-\(qBittorrent-4.1\))
- [VPN University qBittorrent guide](https://www.vpnuniversity.com/bittorrent/torrent-clients/qbittorrent-guide), [TRaSH Guides basic setup](https://trash-guides.info/Downloaders/qBittorrent/Basic-Setup/), [qBittorrent wiki: disable auto-seed](https://github.com/qbittorrent/qBittorrent/wiki/How-to-disable-auto-seed)
