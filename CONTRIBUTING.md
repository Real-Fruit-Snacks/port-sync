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

The README panel (`docs/assets/panel-{dark,light}.svg`) is drawn by `docs/art/make-panel.py`; change the script and re-run it rather than editing the SVGs. CI checks they match:

```sh
python -m pip install -r docs/art/requirements.txt
python docs/art/make-panel.py
```

The social preview is `docs/card.html`, rendered to `docs/assets/social.png` at 1280 x 640.

## Tests

```powershell
(Import-PowerShellDataFile tools/versions.psd1).Modules |
    ForEach-Object { Install-Module $_.Name -RequiredVersion $_.Version -Scope CurrentUser -Force -SkipPublisherCheck }
./tools/lint.ps1   # PSScriptAnalyzer with ./PSScriptAnalyzerSettings.psd1, and the ASCII check
./tools/test.ps1   # Invoke-Pester ./tests
```

`tools/versions.psd1` pins Pester and PSScriptAnalyzer for CI, the scripts and the dev kit.

The tests against a real qBittorrent need a throwaway Web UI. On Linux or WSL with `qbittorrent-nox`:

```sh
sh tests/start-qbittorrent.sh test-pass
PORT_SYNC_TEST_QBIT_URL=http://127.0.0.1:8080 PORT_SYNC_TEST_QBIT_PASS=test-pass pwsh -c 'Invoke-Pester ./tests'
```

`tests/install.Tests.ps1` registers a real scheduled task and deletes `%LOCALAPPDATA%\port-sync`; it only runs elevated on Windows, and is meant for CI. Don't run it where port-sync is installed.

In the PR, say what you ran it against.

## Developing offline

Each release has `port-sync-<version>-dev-windows-x64.zip`: the source at that tag, plus Pester and PSScriptAnalyzer (`offline\powershell`), the panel's Python wheels for CPython 3.13 on Windows x64 (`offline\python`) and their licences. Unzip it, then in the `port-sync-<version>-dev` folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\offline\setup.ps1
```

It needs no network. It checks for Windows PowerShell 5.1, PowerShell 7 and Python 3.13 and says what's missing, checks the bundled modules load in both PowerShells, installs the wheels into `.venv` with `pip install --no-index`, then prints the commands for the lint, the tests, the panel and the offline zip. The kit doesn't include PowerShell, Python or Git; `offline\README.md` lists the versions CI uses, with a link to each offline installer. The tests against a real qBittorrent need `qbittorrent-nox` on Linux, so the kit skips them.

`tools/build-dev-kit.ps1` builds the kit and needs the internet. It takes the versions from `tools/versions.psd1` and `docs/art/requirements.txt`, the files CI reads, and the `offline` workflow checks each release's kit with the network cut off.

## Style

- 4 spaces; CRLF for `.ps1` (`.gitattributes`, `.editorconfig`).
- Approved verbs (`Get-`, `Test-`, `Sync-`); `Rfs` only on the installer's entry point, `Install-RfsPortSync`.
- Comments say why, not what.
- Log lines: lowercase, plain, and they name the next step when there is one.
