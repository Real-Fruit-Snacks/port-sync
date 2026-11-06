# port-sync

Keeps qBittorrent's port synced to Proton VPN

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/panel-dark.svg">
  <img alt="Two meter readouts. Proton VPN's forwarded port changes from 48213 to 51037, qBittorrent's listening port turns pink and reads out of sync, then port-sync sets it and both read 51037, in sync" src="docs/assets/panel-light.svg" width="100%">
</picture>

```powershell
irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1 | iex
```

Run it in a normal PowerShell window as the Windows account you torrent with. It generates a Web UI password, tells you where to paste it in qBittorrent, does one test sync, then registers a scheduled task that runs at sign-in. One UAC prompt, for the task.

No internet on that PC: unzip `port-sync-<version>-offline.zip` from the [latest release](https://github.com/Real-Fruit-Snacks/port-sync/releases/latest) and run `powershell -ExecutionPolicy Bypass -File .\install.ps1` in that folder. It installs the `port-sync.ps1` next to it instead of downloading one; add `-Uninstall` to remove it.

Proton VPN hands out a new forwarded port on most reconnects. Until qBittorrent listens on that port, peers can't connect in, so downloads slow down and seeding mostly stops. On Linux the Proton app writes the port to a file; the Windows app only writes it to its own log, so port-sync reads the log every 15 seconds and sets the port through qBittorrent's Web UI API. The panel above acts that out, faster. It assumes the VPN and qBittorrent are already set up so torrent traffic can't leave outside the tunnel; [docs/setup-guide.md](docs/setup-guide.md) is that setup, step by step.

Coming from `proton-qbit-port-sync` 1.x: run the same install line. It keeps your password file, replaces the old task, and moves to `%LOCALAPPDATA%\port-sync`.

## What it writes to sync.log

`port-sync.ps1 -Once`, run against a Web UI listening on 49160 while Proton's log said `Port pair 48213->48213`:

```text
2026-11-05 06:30:28 [port-sync] port-sync 2.0.1 watching C:\Users\you\AppData\Local\Proton\Proton VPN\Logs
2026-11-05 06:30:29 [port-sync] listening port updated: 49160 -> 48213
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

## Day to day

```powershell
Get-Content "$env:LOCALAPPDATA\port-sync\sync.log" -Wait -Tail 20                  # watch it
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\port-sync\port-sync.ps1" -Once   # one cycle: exit 0 in sync, 1 not
Stop-ScheduledTask port-sync; Start-ScheduledTask port-sync                         # restart
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1))) -Uninstall   # remove
```

Uninstalling removes the task and `%LOCALAPPDATA%\port-sync`; qBittorrent keeps its last port. `port-sync.ps1 -Version` prints the version.

## Tested on

- Ubuntu 24.04 · PowerShell 7.4.6 · qbittorrent-nox 4.6.3: the Pester suite, including the sync against a real Web UI, with simulated Proton log lines
- Windows Server 2022 (GitHub `windows-latest`) · Windows PowerShell 5.1 and PowerShell 7: unit tests, and the installer against a real Task Scheduler (in [CI](.github/workflows/ci.yml))
- *Not* tested: the Proton VPN app's real log on a real Windows 10/11 desktop, and qBittorrent 5.x. If you run either, an issue saying which versions worked or didn't is the most useful thing you can send.

## Known issues

- Proton doesn't document the `Port pair 54692->54692` log line. The path and wording come from two community tools that rely on it ([qbit-proton-port](https://github.com/EudesRobin/qbit-proton-port), [Auto-Port-Sync](https://github.com/Jaques-and-sons/ProtonVPN-qBittorrent-Auto-Port-Sync)). If an app update changes it, `sync.log` says `no forwarded port in the Proton VPN log yet` and nothing else breaks.
- A console window can flash at sign-in. `-WindowStyle Hidden` hides it after `powershell.exe` has started, not before.
- The password file is DPAPI-encrypted to the account that created it. Run the installer as the account you torrent with, not as a separate admin account.
- qBittorrent has to be running to receive the port. A change made while it's closed lands within 60 s of opening it.
- After a rejected login the script waits for the password file to change, or 30 minutes, before trying again, because qBittorrent bans an address after 5 failures in a row.

## Settings

Defaults fit the setup guide: Web UI on `127.0.0.1:8080`, user `admin`, WireGuard adapter `ProtonVPN`.

| Parameter | Default | Purpose |
|---|---|---|
| `-QbitUrl` | `http://127.0.0.1:8080` | qBittorrent Web UI address |
| `-QbitUser` | `admin` | Web UI username |
| `-ProtonLogs` | `%LOCALAPPDATA%\Proton\Proton VPN\Logs` | Folder with `client-logs.txt` |
| `-Adapter` | `ProtonVPN` | Adapter that must be up before syncing. `ProtonVPN TUN` for OpenVPN, `''` to skip the check |
| `-StateDir` | `%LOCALAPPDATA%\port-sync` | Password file and `sync.log` |
| `-IntervalSec` | `15` | How often to read the Proton log |
| `-RecheckSec` | `60` | How often to re-read qBittorrent's port when Proton's hasn't changed |

To change one for the scheduled task, in an admin PowerShell (OpenVPN as the example):

```powershell
$t = Get-ScheduledTask port-sync
$t.Actions[0].Arguments += " -Adapter 'ProtonVPN TUN'"
Set-ScheduledTask -InputObject $t
Stop-ScheduledTask port-sync; Start-ScheduledTask port-sync
```

Re-running the installer resets the task to the defaults.

## License

[MIT](LICENSE). Not affiliated with Proton AG or the qBittorrent project. [Project page](https://real-fruit-snacks.github.io/port-sync/) · [Changelog](CHANGELOG.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md)
