# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [SemVer](https://semver.org/).

## [Unreleased]

## [3.0.2] - 2026-11-24

Upgraded the Windows application icon and runtime notification area status icons to full Cyclorama Dawn `v2.1.0` fidelity.

### Changed
- Packaged `assets/app.ico` as a 9-size multi-resolution Windows icon (`16`, `20`, `24`, `32`, `40`, `48`, `64`, `128`, `256px`) from the canonical Cyclorama Dawn marks so Explorer, taskbar, and Start Menu views render crisply at every scale.
- Added the Cyclorama Dawn hairline frame (`#3B3E4A`) and subtle rising Glacial Steel → Maritime Beacon Orange wash behind the notification area status bars in `src/winutil.rs`.

## [3.0.1] - 2026-11-24

Visual refresh to the Cyclorama Dawn `v2.1.0` palette. Sync behaviour, settings, and `sync.log` are unchanged.

### Changed
- Application icon (`app.ico`) and notification area status icons updated to Cyclorama Dawn `v2.1.0` (Matte Dark base, Mint in-sync, Slate waiting, Signal Crimson fault).
- Project page, README art, and cover assets updated to Cyclorama Dawn `v2.1.0` with a below-header scroll shell and wide-dash controller layout.

## [3.0.0] - 2026-11-13

port-sync is now one small program, `port-sync.exe`, that sits in the notification area: the icon shows whether qBittorrent has Proton's port, and a notification says when the port changes or something needs fixing. The sync itself is the same, line for line, and so is `sync.log`. Re-running the install line updates from 2.x or 1.x: it removes the old scheduled task (one UAC prompt, for that only) and keeps your password file and any setting you changed.

### Added
- The notification area icon: amber over green when in sync, grey while waiting for the VPN, a forwarded port or qBittorrent, pink below when something needs you. Its tooltip shows both ports.
- Its menu: Sync now, Copy port, Open qBittorrent Web UI, Open log, Edit settings, Start at sign-in, Quit.
- Notifications when qBittorrent gets a new port, and when something needs fixing (a rejected login, a password file that can't be read, a port qBittorrent won't take), once each. `"notifications": false` turns them off.
- `%LOCALAPPDATA%\port-sync\config.json` for the settings, which **Edit settings** opens. Changes apply within 15 seconds, with nothing to restart.
- A Start menu entry, to start port-sync again after Quit.
- `port-sync.exe --quit` stops the running one; `--help` lists the options.
- `port-sync.exe` on each release on its own, which the install line downloads and checks against `SHA256SUMS.txt`, and `THIRD-PARTY-LICENSES.txt` in each download.

### Changed
- `port-sync.ps1` is now `port-sync.exe`, written in Rust: about 800 KB, using about 15 MB of memory, where 2.x kept a PowerShell process running. `--once` and `--version` replace `-Once` and `-Version`; the 2.x spellings still work, and so do the 2.x option names (`-QbitUrl`, `-Adapter`, ...).
- It starts at sign-in from your own Run key instead of a scheduled task, so installing needs no admin rights. **Start at sign-in** in the menu turns that off and on.
- Settings you changed for 2.x, as task arguments, or for 1.x, in the script, move into `config.json` when you upgrade.
- The offline zip carries `port-sync.exe` instead of `port-sync.ps1`. The dev kit adds every Rust crate (`cargo vendor`) and lists Rust and the Visual Studio Build Tools among the toolchains to install.
- The sync's Pester tests are Rust tests now, run against a stand-in Web UI that answers as qBittorrent 4.x and 5.x do, and in CI also against a real qbittorrent-nox. The installer's tests stay in Pester.

### Fixed
- No console window flashes at sign-in. 2.x hid `powershell.exe`'s window only after it had opened.

## [2.1.0] - 2026-11-05

The sync is unchanged; if 2.0.x is running, there's nothing you need to do. Re-running the install line updates it to 2.1.0 and keeps your password file. New: each release has a download for installing on a PC with no internet, and a kit for working on port-sync offline.

### Added
- `port-sync-2.1.0-offline.zip`: `install.ps1`, `port-sync.ps1`, the README, changelog, licence and setup guide. Unzip it and run `powershell -ExecutionPolicy Bypass -File .\install.ps1` in that folder; nothing is downloaded. `-Uninstall` on the same line removes it.
- `port-sync-2.1.0-dev-windows-x64.zip`: the source with Pester, PSScriptAnalyzer and the panel's Python wheels, and `offline\setup.ps1`, which sets it up with no network. You can lint, test, redraw the panel and build the offline zip without internet. *Developing offline* in `CONTRIBUTING.md` has the steps.
- `SHA256SUMS.txt` on the release, with the checksum of each zip.

### Changed
- `install.ps1`, run as a file from a folder that has a `port-sync.ps1` in it, installs that copy instead of downloading one. It also ends by printing an uninstall line for that file. `irm | iex` downloads as before, and `-Source` still picks the file.
- Releases are built and published by a workflow. Before it publishes, it runs the tests and the panel check, and checks both zips work with the network cut off.

## [2.0.1] - 2026-11-05

The sync itself is unchanged; if 2.0.0 is running, there's nothing you need to do. Re-running the install line updates it to 2.0.1 and keeps your password file.

### Fixed
- The install and uninstall lines in the README and `docs/setup-guide.md`, and the uninstall line the installer prints when it finishes, used the `rfs.sh/port-sync` short link, which was never live. They use the raw GitHub URL of `install.ps1` now: `irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1 | iex`.

### Changed
- The README opens with an animated panel of the two ports and shows real `sync.log` output, with what each line means. The [project page](https://real-fruit-snacks.github.io/port-sync/) is redesigned around the same panel, with a reconnect you can replay.
- The panel is drawn by `docs/art/make-panel.py` and CI checks it's up to date. A monthly link check covers the README, the docs and the page.

## [2.0.0] - 2026-10-26

Renamed from `proton-qbit-port-sync` to `port-sync`. Re-run the installer to move over; it keeps the 1.x password file and replaces the 1.x task.

### Added
- `install.ps1`, for `irm rfs.sh/port-sync | iex`: generates and encrypts the Web UI password, installs the script, runs one test sync, registers the sign-in task with a single UAC prompt. `-Uninstall` removes the task and both state folders. `-Source` installs a local copy. Checks the download is `port-sync.ps1` before replacing anything.
- `port-sync.ps1 -Once` exits 0 when qBittorrent has the forwarded port and 1 when it doesn't.
- `port-sync.ps1 -Version`.
- Pester tests (`tests/`), 25 for the sync including 7 against a real qBittorrent Web UI, 6 for the installer against Task Scheduler. CI on Windows PowerShell 5.1, PowerShell 7 and qbittorrent-nox 4.6.
- `PSScriptAnalyzerSettings.psd1`.

### Changed
- Script is `port-sync.ps1`; state folder `%LOCALAPPDATA%\port-sync`; task `port-sync`, running as you, not elevated, one instance at a time, restarted up to 3 times if it dies.
- After a rejected login it tries again when the password file changes or after 30 minutes. 1.x waited for the file to change, so fixing the password in qBittorrent instead left it stuck until the next sign-in.
- Each check logs out of the Web UI after it's done. 1.x left a session open per check, up to about 60 at a time.
- A trailing slash on `-QbitUrl` is ignored.
- README follows the RFS layout; the full setup guide moved to `docs/setup-guide.md`.

### Fixed
- A password file that couldn't be decrypted (made by another Windows account) was reported as "qBittorrent Web UI not reachable". It now says the file can't be decrypted and by whom.
- Renamed the internal `Write-Log` function, which shadows a cmdlet name in PowerShell 7 on Windows.

## [1.0.0] - 2026-10-19

### Added
- `proton-qbit-port-sync.ps1`: keeps qBittorrent's listening port equal to the port Proton VPN forwards, by reading the Proton VPN app log and calling the qBittorrent Web UI API.
- Setup guide for torrenting on Windows behind Proton VPN: kill switch, interface binding, port forwarding, verification, troubleshooting.
- MIT license.

[Unreleased]: https://github.com/Real-Fruit-Snacks/port-sync/compare/v3.0.1...HEAD
[3.0.1]: https://github.com/Real-Fruit-Snacks/port-sync/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/Real-Fruit-Snacks/port-sync/compare/v2.1.0...v3.0.0
[2.1.0]: https://github.com/Real-Fruit-Snacks/port-sync/compare/v2.0.1...v2.1.0
[2.0.1]: https://github.com/Real-Fruit-Snacks/port-sync/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/Real-Fruit-Snacks/port-sync/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/Real-Fruit-Snacks/port-sync/releases/tag/v1.0.0
