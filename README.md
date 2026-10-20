# proton-qbit-port-sync

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)

Leak-proof torrenting with **Proton VPN + qBittorrent on Windows**, plus a dependency-free PowerShell script that keeps qBittorrent's listening port in sync with the port Proton VPN forwards.

**Goal:** your ISP sees only encrypted VPN traffic, never torrent traffic, even if the VPN drops.

## Requirements

- Windows 10 or 11
- A paid [Proton VPN](https://protonvpn.com/) plan (P2P servers and port forwarding are paid features)
- [qBittorrent](https://www.qbittorrent.org/) 4.x or 5.x with the Web UI enabled (covered below)
- Windows PowerShell 5.1 (built in) or PowerShell 7

## Quick start

Already have Proton VPN and qBittorrent set up the way the guide describes? Then:

```powershell
# 1. Create the state folder and an encrypted Web UI password (paste it into qBittorrent → Options → Web UI)
$dir = "$env:LOCALAPPDATA\proton-qbit-port-sync"
New-Item -ItemType Directory -Force $dir | Out-Null
$bytes = New-Object byte[] 12
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$pw = -join ($bytes | ForEach-Object { $_.ToString('x2') })
ConvertTo-SecureString $pw -AsPlainText -Force | ConvertFrom-SecureString | Set-Content "$dir\qbit-pass.txt"
$pw | Set-Clipboard; "Web UI password (copied): $pw"

# 2. Download the script
Invoke-WebRequest 'https://raw.githubusercontent.com/Real-Fruit-Snacks/proton-qbit-port-sync/main/proton-qbit-port-sync.ps1' -OutFile "$dir\proton-qbit-port-sync.ps1"

# 3. Test it once (VPN connected, port forwarding on, qBittorrent open)
powershell -NoProfile -ExecutionPolicy Bypass -File "$dir\proton-qbit-port-sync.ps1" -Once
```

Then register it to run at sign-in ([Automation step 5](#5-run-it-at-sign-in)). The rest of this README is the full guide.

## Contents

- [How the protection works](#how-the-protection-works-two-independent-layers)
- [Setup](#setup)
  1. [Install the apps](#step-1-install-the-apps)
  2. [Configure the Proton VPN app](#step-2-configure-the-proton-vpn-app)
  3. [Connect to a P2P server](#step-3-connect-to-a-p2p-server)
  4. [Enable port forwarding](#step-4-enable-port-forwarding)
  5. [Lock down qBittorrent](#step-5-lock-down-qbittorrent)
  6. [Prove it works](#step-6-prove-it-works)
- [Automation: port sync script](#automation-keep-qbittorrents-port-in-sync)
- [Manual fallback](#manual-fallback)
- [Recommended qBittorrent settings](#recommended-qbittorrent-settings-optional-tuning)
- [Troubleshooting](#troubleshooting)
- [Quick reference](#quick-reference)
- [Sources](#sources)
- [Contributing](#contributing)

## How the protection works (two independent layers)

| Layer | What it does | Scope |
| --- | --- | --- |
| **Kill switch (Advanced)** | Blocks all internet unless connected to Proton VPN; survives reboots ([Proton](https://protonvpn.com/support/advanced-kill-switch)) | Whole system |
| **qBittorrent →** `ProtonVPN` **binding** | qBittorrent's only network path is the VPN adapter; no VPN = downloads stall instantly ([Proton](https://protonvpn.com/support/bittorrent-vpn)) | qBittorrent only |

Either layer alone stops torrent leaks; together they cover each other. Split tunneling stays **off**. It isn't needed, though on Windows it is compatible with the kill switch and has an Include mode ([Proton](https://protonvpn.com/support/protonvpn-split-tunneling)).

### Windows vs Linux

If you're coming from a Linux setup (e.g. the official Proton CLI/app on Arch-based distros), these are the differences:

| Thing | Linux | Windows |
| --- | --- | --- |
| VPN interface to bind | `proton0` (WireGuard), `tun0` (OpenVPN) | `ProtonVPN` (WireGuard or Stealth), `ProtonVPN TUN` (OpenVPN) |
| Forwarded port source | File `/run/user/$UID/Proton/VPN/forwarded_port` | No port file. Shown in the app; the sync script reads it from the app's log |
| Port sync | bash + inotify + systemd user service | PowerShell script + Task Scheduler task |
| Web UI password storage | Plain text in the script | Encrypted to your Windows account (DPAPI) |
| qBittorrent settings menu | Tools → Preferences | Tools → Options |
| New risk | None | Advanced kill switch can block Microsoft-account sign-in (Step 2) |

## Setup

### Step 1: Install the apps

In PowerShell or Terminal:

```powershell
winget install Proton.ProtonVPN
winget install qBittorrent.qBittorrent
```

Or use the installers from [protonvpn.com/download-windows](https://protonvpn.com/download-windows) and [qbittorrent.org](https://www.qbittorrent.org/download).

### Step 2: Configure the Proton VPN app

Sign in, then open **Settings**:

- **Connection → Protocol: WireGuard.** Don't leave it on Smart: the protocol decides the adapter name used in Step 5.
- **Connection → Kill switch: on → Advanced → Apply.** No internet at all without the VPN, and it persists across reboots.
- **Split tunneling: off.**
- Turn on launch at Windows startup and auto-connect.

> **Before enabling Advanced, create a local Windows account as a backup.** If Windows ever demands an online Microsoft-account sign-in (after a password change, major update, or BIOS update), the kill switch blocks it and you can be locked out. Proton says there is no easy fix and recommends a backup local account ([Proton](https://protonvpn.com/support/advanced-kill-switch)).

Prefer **Standard** if you sometimes need internet without the VPN. It only engages on accidental drops.

LAN access (printers, NAS) is controlled by **Settings → Connection → Advanced settings → Allow LAN connections**, on by default ([Proton](https://protonvpn.com/support/lan-connections)). Proton's docs don't say how it behaves under the Advanced kill switch, so test your printer after enabling it.

### Step 3: Connect to a P2P server

**Countries → P2P tab** → pick a country or server → Connect ([Proton](https://protonvpn.com/support/bittorrent-vpn)). Pick the nearest one with the lowest load. Skip Secure Core for torrenting.

Verify the tunnel in PowerShell:

```powershell
curl.exe ifconfig.me
```

It should show a Proton IP, not your real one. Run it once before connecting to compare. Use `curl.exe`, not `curl`: in Windows PowerShell plain `curl` is a different command.

### Step 4: Enable port forwarding

While connected to the P2P server: click **Port forwarding** in the right sidebar → toggle **on** → **Apply**. Also turn on its **Notifications** option ([Proton](https://protonvpn.com/support/port-forwarding)).

Hover over **Port forwarding** in the sidebar to see the **active port number**. Note it for Step 5.

### Step 5: Lock down qBittorrent

1. Keep the VPN connected (the adapter must exist), then open qBittorrent.
2. **Tools → Options → Advanced → Network interface →** `ProtonVPN`
   - Use `ProtonVPN TUN` if you ever switch to OpenVPN. Update this setting whenever you change protocols.
3. **Connection tab:**
   - **Port used for incoming connections:** the number from Step 4
   - **Uncheck** "Use UPnP / NAT-PMP port forwarding from my router"
4. Click **OK** and restart qBittorrent.

### Step 6: Prove it works

1. Start a legal test torrent, for example an Ubuntu ISO.
2. Mid-download, disconnect the VPN. The download must **stall to zero peers**.
3. Reconnect. It resumes.

If it kept downloading while disconnected, the binding didn't take. Recheck `ProtonVPN` in Step 5.

---

## Automation: keep qBittorrent's port in sync

Proton usually changes the forwarded port every time you reconnect ([Proton](https://protonvpn.com/support/port-forwarding)). [`proton-qbit-port-sync.ps1`](proton-qbit-port-sync.ps1) reads the current port from the Proton VPN app's log and pushes it into qBittorrent through its Web UI API ([API docs](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-\(qBittorrent-4.1\))).

The Windows app has no port file. It logs lines containing `Port pair 54692->54692` to `%LOCALAPPDATA%\Proton\Proton VPN\Logs\client-logs.txt`. Proton doesn't document this; the path and wording come from two community tools that rely on it ([qbit-proton-port](https://github.com/EudesRobin/qbit-proton-port), [Auto-Port-Sync](https://github.com/Jaques-and-sons/ProtonVPN-qBittorrent-Auto-Port-Sync)). If an app update changes the log, the script stops finding a port and says so in its own log.

**Test status:** the script passed against qBittorrent 4.6.3 with simulated Proton log lines, under PowerShell 7 on Linux. It has not yet run on Windows or against a real Proton log. Step 4 below is that check. If it works (or doesn't) for you, please [open an issue](https://github.com/Real-Fruit-Snacks/proton-qbit-port-sync/issues) and say which versions you ran.

### Script parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-QbitUrl` | `http://127.0.0.1:8080` | qBittorrent Web UI address |
| `-QbitUser` | `admin` | Web UI username |
| `-ProtonLogs` | `%LOCALAPPDATA%\Proton\Proton VPN\Logs` | Folder containing `client-logs.txt` |
| `-Adapter` | `ProtonVPN` | VPN adapter that must be up before syncing. `ProtonVPN TUN` for OpenVPN, `''` to skip the check |
| `-StateDir` | `%LOCALAPPDATA%\proton-qbit-port-sync` | Where the password file and `sync.log` live |
| `-IntervalSec` | `15` | How often to read the Proton log |
| `-RecheckSec` | `60` | How often to re-verify qBittorrent's port |
| `-Once` | off | Run one cycle and exit (for testing) |

### 1. Generate the Web UI password

In PowerShell (normal, not admin):

```powershell
$dir = "$env:LOCALAPPDATA\proton-qbit-port-sync"
New-Item -ItemType Directory -Force $dir | Out-Null
$bytes = New-Object byte[] 12
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$pw = -join ($bytes | ForEach-Object { $_.ToString('x2') })
ConvertTo-SecureString $pw -AsPlainText -Force | ConvertFrom-SecureString | Set-Content "$dir\qbit-pass.txt"
$pw | Set-Clipboard
"Web UI password (copied to clipboard): $pw"
```

The saved file is encrypted to your Windows account, so only you on this PC can read it.

### 2. Enable qBittorrent's Web UI

**Tools → Options → Web UI:**

- Enable **Web User Interface (Remote control)**
- IP address: `127.0.0.1`, port: `8080`
- Authentication: username `admin`, password = paste the one from step 1
- Keep **"Bypass authentication for clients on localhost" unchecked**
- Leave **"Enable Host header validation"** on. The script worked with it on in testing. Only turn it off if logins are rejected with a correct password.
- Click **OK**

### 3. Get the script

Download [`proton-qbit-port-sync.ps1`](proton-qbit-port-sync.ps1) from this repo into the state directory:

```powershell
$dir = "$env:LOCALAPPDATA\proton-qbit-port-sync"
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Real-Fruit-Snacks/proton-qbit-port-sync/main/proton-qbit-port-sync.ps1' -OutFile "$dir\proton-qbit-port-sync.ps1"
```

(Or clone the repo and copy the file there by hand.)

### 4. Test it once

With the VPN connected, port forwarding on, and qBittorrent open:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\proton-qbit-port-sync\proton-qbit-port-sync.ps1" -Once
```

Expect `listening port updated: <old> -> <new>` or `listening port already correct: <port>`. The port should match the one shown in the Proton VPN app.

If it says `no forwarded port in the Proton VPN log yet`, check that the log really contains the port lines:

```powershell
Select-String -Path "$env:LOCALAPPDATA\Proton\Proton VPN\Logs\client-logs.txt" -Pattern 'Port pair' | Select-Object -Last 3
```

No matches means the log location or wording differs in your app version. Use the manual fallback below and adjust `-ProtonLogs` or the pattern in the script.

### 5. Run it at sign-in

In PowerShell **as administrator** (Task Scheduler needs admin to create a sign-in trigger). Use the same Windows account you torrent with, since the password file only decrypts for that account.

```powershell
$script   = "$env:LOCALAPPDATA\proton-qbit-port-sync\proton-qbit-port-sync.ps1"
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'Proton qBittorrent port sync' -Action $action -Trigger $trigger -Settings $settings
Start-ScheduledTask -TaskName 'Proton qBittorrent port sync'
```

A console window may flash briefly at sign-in.

### 6. Verify

```powershell
Get-Content "$env:LOCALAPPDATA\proton-qbit-port-sync\sync.log" -Wait -Tail 20
```

Reconnect the VPN. Within about 15 seconds of the app showing a new port, the log should show `listening port updated: <old> -> <new>` and qBittorrent's Connection tab shows the new port.

**Note:** qBittorrent must be running for the API call. The script re-checks every 60 seconds, so a port change that happens while qBittorrent is closed is applied shortly after it opens.

## Manual fallback

If the sync task is off and speeds drop: hover over **Port forwarding** in the Proton VPN app, then paste the active port number into qBittorrent → Tools → Options → Connection → Port used for incoming connections.

## Recommended qBittorrent settings (optional tuning)

Already covered by the main steps: UPnP/NAT-PMP off, bound to `ProtonVPN`, Web UI locked down.

| Setting | Where | Value | Why |
| --- | --- | --- | --- |
| Use different port on each startup | Connection | **OFF** (default) | Would silently override the port the sync script sets |
| Encryption mode | BitTorrent → Privacy | **Allow encryption** (default) | Traffic is already inside the VPN tunnel; "Require" only shrinks the peer pool ([VPN University](https://www.vpnuniversity.com/bittorrent/torrent-clients/qbittorrent-guide)) |
| Anonymous mode | BitTorrent → Privacy | Optional for public trackers; **OFF for private trackers** | Strips the client fingerprint, but can interfere with private-tracker identification ([TRaSH Guides](https://trash-guides.info/Downloaders/qBittorrent/Basic-Setup/)) |
| DHT / PeX / Local Peer Discovery | BitTorrent → Privacy | **ON** (defaults) | Peer discovery for public torrents; the binding forces it all through the VPN. Private torrents disable DHT/PeX per torrent |
| Inhibit system sleep | Behavior | **ON** (laptop) | Keeps downloads running when power saving kicks in |
| Upload rate limit | Speed | Optional: about 70–80% of real upload speed | Keeps the rest of the connection responsive while seeding |
| Seeding limits | BitTorrent → Seeding Limits | To never seed after download: "When ratio reaches" → **0**, then stop the torrent ([qBittorrent wiki](https://github.com/qbittorrent/qBittorrent/wiki/How-to-disable-auto-seed)) | You still upload during downloads. On private trackers this counts as hit-and-run, so seed properly there |

**Reminder:** if qBittorrent is set to close to the tray, the X button only hides it. File → Exit (or tray right-click → Exit) actually quits, which matters when clearing a Web UI login ban.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| No internet at all | The Advanced kill switch is working as designed. Connect in Proton VPN, or set Kill switch to Off or Standard. If the app is broken or uninstalled and you're still blocked, reinstall it and turn the kill switch off from there |
| Can't sign in to Windows after an update or password change | Microsoft-account sign-in needs internet, which the kill switch blocks. Sign in with the backup local account from Step 2, then connect the VPN |
| Torrents stalled while the VPN is connected | Check Tools → Options → Advanced → Network interface is still `ProtonVPN`. If the protocol changed to OpenVPN, re-bind to `ProtonVPN TUN`. If it stalls right after a reconnect, restart qBittorrent; some Windows users report the binding needs that ([gist thread](https://gist.github.com/thejorro/a63dfa17e6e25a85d7a2f9ddd8c6a652)) |
| Downloads slow but everything connected | The port rotated. Check `sync.log` (Quick reference), or use the manual fallback |
| Sync log: "Web UI login rejected" | Re-run Automation step 1, paste the new password into the Web UI settings, then fully quit and reopen qBittorrent to clear any ban. If the password is right, uncheck "Enable Host header validation" |
| Sync log: "no forwarded port in the Proton VPN log yet" | Confirm you're on a P2P server with port forwarding on. Then run the `Select-String` check from Automation step 4 |
| Sync log: "VPN adapter 'ProtonVPN' is not up" | Run `Get-NetAdapter` while connected to see the real adapter name. On OpenVPN, add `-Adapter 'ProtonVPN TUN'` to the task's arguments |
| "Running scripts is disabled on this system" | Start the script with `powershell -ExecutionPolicy Bypass -File ...` as in Automation step 4 |
| Sync stopped after sign-in | `Get-ScheduledTaskInfo 'Proton qBittorrent port sync'` shows the last run result; `Start-ScheduledTask` restarts it |

## Quick reference

```powershell
# Install
winget install Proton.ProtonVPN
winget install qBittorrent.qBittorrent

# Check public IP (should be Proton's)
curl.exe ifconfig.me

# VPN adapter name and state
Get-NetAdapter | Where-Object Name -like 'ProtonVPN*'

# Latest forwarded port in the Proton VPN log
Select-String -Path "$env:LOCALAPPDATA\Proton\Proton VPN\Logs\client-logs.txt" -Pattern 'Port pair' | Select-Object -Last 1

# Probe the qBittorrent Web UI ("Forbidden" = running, login required; no reply = not running)
curl.exe -s http://127.0.0.1:8080/api/v2/app/webapiVersion

# Port sync: one-off run, live log, task status, restart
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\proton-qbit-port-sync\proton-qbit-port-sync.ps1" -Once
Get-Content "$env:LOCALAPPDATA\proton-qbit-port-sync\sync.log" -Wait -Tail 20
Get-ScheduledTaskInfo 'Proton qBittorrent port sync'
Stop-ScheduledTask 'Proton qBittorrent port sync'; Start-ScheduledTask 'Proton qBittorrent port sync'

# Remove the task
Unregister-ScheduledTask 'Proton qBittorrent port sync' -Confirm:$false
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

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md); changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE). This project is not affiliated with Proton AG or the qBittorrent project.
