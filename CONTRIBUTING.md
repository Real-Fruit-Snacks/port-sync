# Contributing

Thanks for helping out. This is a small project, so the process is light.

## Reporting a problem

Open an issue using the bug report template. The most useful things to include:

- Windows version, Proton VPN app version, qBittorrent version
- The last 20 lines of `%LOCALAPPDATA%\proton-qbit-port-sync\sync.log`
- Whether `Select-String -Path "$env:LOCALAPPDATA\Proton\Proton VPN\Logs\client-logs.txt" -Pattern 'Port pair'` finds anything

If the Proton VPN app changed its log format, a redacted sample of the new log line is the single most helpful thing you can provide.

## Suggesting a change

1. Fork and create a branch from `main`.
2. Keep the script compatible with **Windows PowerShell 5.1** (built into Windows). Don't use PowerShell 7-only syntax such as `??`, `?.`, or `-Parallel`.
3. Keep the script dependency-free: no modules to install.
4. Test with `-Once` against a real qBittorrent instance before opening a pull request, and say in the PR what you tested against.
5. Add a line to `CHANGELOG.md` under *Unreleased*.

## Style

- 4-space indentation, CRLF line endings for `.ps1` (enforced by `.gitattributes` and `.editorconfig`).
- Approved PowerShell verbs for function names (`Get-`, `Test-`, `Sync-`, ...).
- Comments explain *why*, not *what*.
