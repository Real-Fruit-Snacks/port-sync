# Contributing

Small project, light process.

## Reporting a problem

Use the bug form. The useful parts:

- Windows, Proton VPN app, qBittorrent and PowerShell versions (`port-sync.ps1 -Version`, `$PSVersionTable.PSVersion`)
- The last 20 lines of `%LOCALAPPDATA%\port-sync\sync.log`
- Whether this finds anything:
  `Select-String -Path "$env:LOCALAPPDATA\Proton\Proton VPN\Logs\client-logs.txt" -Pattern 'Port pair' | Select-Object -Last 3`

If the Proton VPN app changed its log format, a redacted sample of the new line is the most useful thing you can send.

## Changing something

1. Branch from `main`.
2. Keep both scripts working under **Windows PowerShell 5.1**: no `??`, `?.`, ternaries or `-Parallel`.
3. ASCII only in `.ps1` files. 5.1 reads a BOM-less file as the system code page, so one curly quote breaks it. CI checks.
4. No modules to install. Pester and PSScriptAnalyzer are for development only.
5. No `exit` in `install.ps1`: under `irm | iex` it closes the user's window.
6. Add a line to `CHANGELOG.md` under *Unreleased*.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester ./tests
```

The tests against a real qBittorrent need a throwaway Web UI. On Linux or WSL with `qbittorrent-nox`:

```sh
sh tests/start-qbittorrent.sh test-pass
PORT_SYNC_TEST_QBIT_URL=http://127.0.0.1:8080 PORT_SYNC_TEST_QBIT_PASS=test-pass pwsh -c 'Invoke-Pester ./tests'
```

`tests/install.Tests.ps1` registers a real scheduled task and deletes `%LOCALAPPDATA%\port-sync`; it only runs elevated on Windows, and is meant for CI. Don't run it where port-sync is installed.

In the PR, say what you ran it against.

## Style

- 4 spaces; CRLF for `.ps1` (`.gitattributes`, `.editorconfig`).
- Approved verbs (`Get-`, `Test-`, `Sync-`); `Rfs` only on the installer's entry point, `Install-RfsPortSync`.
- Comments say why, not what.
- Log lines: lowercase, plain, and they name the next step when there is one.
