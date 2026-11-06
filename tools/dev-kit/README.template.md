<!-- tools/build-dev-kit.ps1 turns this into the kit's offline\README.md; {{...}} are filled in and these comment lines dropped. -->
# port-sync {{VERSION}} dev kit

port-sync at `v{{VERSION}}` (the repo, without `.git`) and every package its checks need, so you can lint it, run its tests, redraw the README panel and build the offline zip on a Windows x64 PC with no internet.

## What's in `offline\`

| Path | Holds |
|---|---|
| `powershell\` | {{MODULES}}, as `Save-Module` writes them |
| `python\` | Wheels for `docs\art\requirements.txt`: {{WHEELS}}, for CPython {{PYSERIES}} on Windows x64 |
| `licences\` | The licence and notices of each of those, and of the libraries they bundle |
| `setup.ps1` | Checks the toolchains below and sets the kit up. Needs no network |
| `toolchains.psd1` | The table below, for `setup.ps1` |

## Toolchains

These aren't in the kit; install them first. **Version** is what CI used when it built this kit.

| Toolchain | Version | Works with | Needed for | Offline installer |
|---|---|---|---|---|
{{TOOLCHAINS}}

## Steps

1. Install the toolchains above.
2. In this folder:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\offline\setup.ps1
   ```

   It unblocks the kit's files, checks each toolchain, checks that Pester and PSScriptAnalyzer load from `offline\powershell` in Windows PowerShell and PowerShell 7, and creates `.venv` with `pip install --no-index --find-links offline\python`. Anything missing, it names, with the installer to get. If Python {{PYSERIES}} isn't on PATH or the `py` launcher, add `-Python <path to python.exe>`.
3. Run the commands it prints:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\lint.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test.ps1
   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\test.ps1
   .\.venv\Scripts\python.exe docs\art\make-panel.py
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-offline.ps1
   ```

   `lint.ps1` and `test.ps1` load the modules from `offline\powershell` by path, at the versions in `tools\versions.psd1`. `make-panel.py` redraws `docs\assets\panel-*.svg`; if they come out unchanged, the panel matches the script. `build-offline.ps1` writes `dist\port-sync-{{VERSION}}-offline.zip`.

`tests\install.Tests.ps1` runs only from an elevated window: it registers a real scheduled task and deletes `%LOCALAPPDATA%\port-sync`. On a PC where port-sync is installed, run the tests from a normal window.

## Not in the kit

- The toolchains above.
- `qbittorrent-nox`, for the tests against a real Web UI. They run on Linux only, are skipped without it, and `CONTRIBUTING.md` says how to run them.
- What a new kit needs: `tools\build-dev-kit.ps1` downloads everything, so it needs the internet.
