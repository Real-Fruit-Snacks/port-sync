# Contributing

Small project, light process.

## Reporting a problem

Use the bug form. The useful parts:

- Windows, Proton VPN app, qBittorrent and port-sync versions (`port-sync.exe --version`)
- The last 20 lines of `%LOCALAPPDATA%\port-sync\sync.log`
- Whether this finds anything:
  `Select-String -Path "$env:LOCALAPPDATA\Proton\Proton VPN\Logs\client-logs.txt" -Pattern 'Port pair' | Select-Object -Last 3`

If the Proton VPN app changed its log format, a redacted sample of the new line is the most useful thing you can send.

## Changing something

1. Branch from `main`.
2. The program is Rust (`src/`): the sync in `sync.rs`, `proton.rs` and `qbit.rs`, the tray app in `tray.rs`. Keep its dependencies few; each one ships to every user, and its licence goes into `THIRD-PARTY-LICENSES.txt` (`about.toml` lists the licences accepted).
3. `sync.log` lines are what people search for and what the README quotes. Change one on purpose, and update the README's table with it.
4. Keep `install.ps1` working under **Windows PowerShell 5.1**: no `??`, `?.`, ternaries or `-Parallel`; ASCII only, since 5.1 reads a BOM-less file as the system code page; and no `exit`, since under `irm | iex` it closes the user's window. CI checks the first two.
5. Bump the version in `Cargo.toml` (and `Cargo.lock`, by building) for a change that ships, and add a line to `CHANGELOG.md` under *Unreleased*.

The README panel (`docs/assets/panel-{dark,light}.svg`) is drawn by `docs/art/make-panel.py`; change the script and re-run it rather than editing the SVGs. CI checks they match:

```sh
python -m pip install -r docs/art/requirements.txt
python docs/art/make-panel.py
```

The social preview is `docs/card.html`, rendered to `docs/assets/social.png` at 1280 x 640.

## Building and testing

You need Rust (the version in `tools/versions.psd1`, with the `x86_64-pc-windows-msvc` toolchain) and the Visual Studio Build Tools for its linker.

```powershell
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test                      # the sync against a stand-in Web UI, and the built program
cargo build --release           # target\release\port-sync.exe
```

The tests also run against a real qBittorrent when you point them at a throwaway Web UI; they change its listening port, so don't use the one you torrent with. On Linux or WSL with `qbittorrent-nox`:

```sh
sh tests/start-qbittorrent.sh test-pass
PORT_SYNC_TEST_QBIT_URL=http://127.0.0.1:8080 PORT_SYNC_TEST_QBIT_PASS=test-pass cargo test
```

The installer has its own checks, PSScriptAnalyzer and Pester:

```powershell
(Import-PowerShellDataFile tools/versions.psd1).Modules |
    ForEach-Object { Install-Module $_.Name -RequiredVersion $_.Version -Scope CurrentUser -Force -SkipPublisherCheck }
./tools/lint.ps1   # PSScriptAnalyzer with ./PSScriptAnalyzerSettings.psd1, and the ASCII check
./tools/test.ps1   # tests/install.Tests.ps1, against target\release\port-sync.exe
```

`tests/install.Tests.ps1` registers real scheduled tasks (2.x and 1.x installs to migrate from), writes your Run key and deletes `%LOCALAPPDATA%\port-sync`; it only runs elevated on Windows, and is meant for CI. Don't run it where port-sync is installed.

`tools/versions.psd1` pins Rust, cargo-about, Pester, PSScriptAnalyzer, Python and qbittorrent-nox for CI, the scripts and the dev kit. `tools/third-party-licences.ps1` writes `THIRD-PARTY-LICENSES.txt`, and `tools/build-offline.ps1` the offline zip, as the release does.

In the PR, say what you ran it against.

## Developing offline

Each release has `port-sync-<version>-dev-windows-x64.zip`: the source at that tag, plus every Rust crate `Cargo.lock` names (`offline\cargo\vendor`), Pester and PSScriptAnalyzer (`offline\powershell`), the panel's Python wheels for CPython 3.13 on Windows x64 (`offline\python`), their licences, and the release's `THIRD-PARTY-LICENSES.txt`. Unzip it, then in the `port-sync-<version>-dev` folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\offline\setup.ps1
```

It needs no network. It checks for Rust, Windows PowerShell 5.1, PowerShell 7 and Python 3.13 and says what's missing, points cargo at the kit's crates, checks the bundled modules load in both PowerShells, installs the wheels into `.venv` with `pip install --no-index`, then prints the commands for the build, the tests, the lint, the panel and the offline zip. The kit doesn't include Rust, the Visual Studio Build Tools, PowerShell, Python or Git; `offline\README.md` lists the versions CI uses, with a link to each installer. The tests against a real qBittorrent need `qbittorrent-nox` on Linux, so in the kit they run against the stand-in only.

`tools/build-dev-kit.ps1` builds the kit and needs the internet. It takes the versions from `tools/versions.psd1`, `Cargo.lock` and `docs/art/requirements.txt`, the files CI reads, and the `offline` workflow checks each release's kit with the network cut off and cargo's cache empty.

## Style

- Rust: `cargo fmt` (`rustfmt.toml`); 4 spaces and CRLF for `.ps1` (`.gitattributes`, `.editorconfig`).
- PowerShell: approved verbs (`Get-`, `Test-`, `Exit-`); `Rfs` only on the installer's entry point, `Install-RfsPortSync`.
- Comments say why, not what.
- Log lines: lowercase, plain, and they name the next step when there is one.
