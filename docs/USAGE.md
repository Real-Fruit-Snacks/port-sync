# port-sync Usage, Settings & Troubleshooting

Complete installation details, `sync.log` reference, day-to-day commands, settings, tested environments, and known issues for `port-sync`. For step-by-step Proton VPN + qBittorrent tunnel binding, see [setup-guide.md](setup-guide.md).

## Install & Upgrade

Run the PowerShell installer in a normal window as the Windows account you torrent with. It generates a Web UI password, tells you where to paste it in qBittorrent, runs one test sync, and registers `port-sync` in the notification area and at sign-in — no admin rights needed.

- **Offline PC:** Unzip `port-sync-<version>-offline.zip` from the [latest release](https://github.com/Real-Fruit-Snacks/port-sync/releases/latest) and run `powershell -ExecutionPolicy Bypass -File .\install.ps1` in that folder (it installs the bundled `port-sync.exe` without downloading anything; add `-Uninstall` to remove it).
- **Upgrading from 2.x or `proton-qbit-port-sync` 1.x:** Run the same install line. It keeps your password file and settings, removes the old scheduled task (one UAC prompt for that only), and moves to `%LOCALAPPDATA%\port-sync`.

## What It Writes to `sync.log`

`port-sync.exe --once`, run against a Web UI listening on 49160 while Proton's log said `Port pair 48213->48213`:

```text
2026-11-05 20:47:33 [port-sync] port-sync 3.0.0 watching C:\Users\you\AppData\Local\Proton\Proton VPN\Logs
2026-11-05 20:47:33 [port-sync] listening port updated: 49160 -> 48213
```

The same call sends qBittorrent `{"listen_port":48213,"random_port":false,"upnp":false}`, so it also turns off the random port and UPnP. A condition that repeats is logged once:

| Line | Means |
|---|---|
| `listening port already correct: 48213` | Checked; nothing to change |
| `VPN adapter 'ProtonVPN' is not up - waiting` | The VPN isn't connected yet |
| `no forwarded port in the Proton VPN log yet - waiting` | Port forwarding is off, or a Proton update changed the log line |
| `qBittorrent Web UI not reachable (not running?) - will retry` | Start qBittorrent; the port lands within 60 s |
| `Web UI login rejected (wrong password, or address banned) ...` | It stops for 30 minutes, or until the password file changes |
| `can't decrypt ...\qbit-pass.txt ...` | The file opens only for the Windows account that made it; re-run the installer as that account |

## Day to Day

```powershell
Get-Content "$env:LOCALAPPDATA\port-sync\sync.log" -Wait -Tail 20                  # watch it
& "$env:LOCALAPPDATA\port-sync\port-sync.exe" --once | Write-Output           # one cycle: exit 0 in sync, 1 not
& "$env:LOCALAPPDATA\port-sync\port-sync.exe" --quit | Write-Output           # stop; start it again from the Start menu
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1))) -Uninstall   # remove
```

Uninstalling removes the sign-in entry, the Start menu entry and `%LOCALAPPDATA%\port-sync`; qBittorrent keeps its last port. `port-sync.exe --version` prints the version. (`| Write-Output` makes PowerShell wait for `port-sync.exe` and show what it prints.)

## Settings

Defaults fit the setup guide: Web UI on `127.0.0.1:8080`, user `admin`, WireGuard adapter `ProtonVPN`.

| Setting | Default | Purpose |
|---|---|---|
| `qbitUrl` | `http://127.0.0.1:8080` | qBittorrent Web UI address |
| `qbitUser` | `admin` | Web UI username |
| `protonLogs` | `%LOCALAPPDATA%\Proton\Proton VPN\Logs` | Folder with `client-logs.txt` |
| `adapter` | `ProtonVPN` | Adapter that must be up before syncing. `ProtonVPN TUN` for OpenVPN, `""` to skip the check |
| `intervalSec` | `15` | How often to read the Proton log |
| `recheckSec` | `60` | How often to re-read qBittorrent's port when Proton's hasn't changed |
| `notifications` | `true` | Notifications for a new port and for problems |

To change one, use **Edit settings** in port-sync's menu (click its icon). It opens `%LOCALAPPDATA%\port-sync\config.json`, which can hold only the settings you change; port-sync picks them up within 15 seconds. OpenVPN as the example:

```json
{ "adapter": "ProtonVPN TUN" }
```

For `--once` they are options too; `port-sync.exe --help` lists them.

## Tested On

- Ubuntu 24.04 · qbittorrent-nox 4.6.3: the sync's tests, including against a real Web UI, with simulated Proton log lines
- Windows Server 2022 (GitHub `windows-latest`): the sync's tests, and the installer under Windows PowerShell 5.1 and PowerShell 7 (in [CI](../.github/workflows/ci.yml))
- *Not* tested: the Proton VPN app's real log on a real Windows 10/11 desktop, and qBittorrent 5.x. If you run either, an issue saying which versions worked or didn't is the most useful thing you can send.

## Known Issues

- Proton doesn't document the `Port pair 54692->54692` log line. The path and wording come from two community tools that rely on it ([qbit-proton-port](https://github.com/EudesRobin/qbit-proton-port), [Auto-Port-Sync](https://github.com/Jaques-and-sons/ProtonVPN-qBittorrent-Auto-Port-Sync)). If an app update changes it, `sync.log` says `no forwarded port in the Proton VPN log yet` and nothing else breaks.
- The password file is DPAPI-encrypted to the account that created it. Run the installer as the account you torrent with, not as a separate admin account.
- qBittorrent has to be running to receive the port. A change made while it's closed lands within 60 s of opening it.
- After a rejected login port-sync waits for the password file to change, or 30 minutes, before trying again, because qBittorrent bans an address after 5 failures in a row.
