# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [SemVer](https://semver.org/).

## [Unreleased]

### Changed
- Install and uninstall lines use the raw GitHub URL of `install.ps1`. The `rfs.sh/port-sync` short link they used before was never live.

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

[Unreleased]: https://github.com/Real-Fruit-Snacks/port-sync/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/Real-Fruit-Snacks/port-sync/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/Real-Fruit-Snacks/port-sync/releases/tag/v1.0.0
