# setup.ps1 - gets this port-sync dev kit ready on a Windows PC with no internet.
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\offline\setup.ps1 [-Python <python.exe>]
# Needs no network. It checks the toolchains in offline\toolchains.psd1, checks Pester and
# PSScriptAnalyzer load from offline\powershell at the pinned versions in each PowerShell, puts
# the panel's wheels from offline\python into .venv, then prints the commands for the checks.
# Exits 1 and says what's missing if anything is. Windows PowerShell 5.1 or PowerShell 7.
# The source is tools/dev-kit/setup.ps1; tools/build-dev-kit.ps1 copies it into the kit.
[CmdletBinding()]
param(
    [string]$Python   # python.exe to use when the right Python isn't on PATH or the py launcher
)

$ErrorActionPreference = 'Stop'
$offline = $PSScriptRoot
$kit     = Split-Path -Parent $offline
$listing = Join-Path $offline 'toolchains.psd1'
if (-not (Test-Path -LiteralPath $listing)) {
    Write-Host "[setup] Run this from a dev kit's offline folder; tools\build-dev-kit.ps1 builds one."
    exit 1
}
$pins     = Import-PowerShellDataFile (Join-Path $kit 'tools\versions.psd1')
$tools    = (Import-PowerShellDataFile $listing).Toolchains
$pySeries = (($pins.Python -split '\.')[0..1]) -join '.'
$missing  = New-Object System.Collections.Generic.List[string]

function Say([string]$Message) { Write-Host "[setup] $Message" }

function Get-Toolchain([string]$Name) { $tools | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }

function Add-Missing([string]$Name, [string]$Problem) {
    $t = Get-Toolchain $Name
    $line = "$Name ($($t.Usable); CI uses $($t.Version)): $Problem. Needed for $($t.For)."
    if ($t.Url) { $line += " Installer: $($t.Url)" }
    $missing.Add($line)
    Say "MISSING $line"
}

# Runs a PowerShell and returns its path and version, or $null if there's none that works.
function Get-Shell([string]$Exe) {
    $cmd = Get-Command $Exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    $out = @(& $cmd.Source -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()')
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    return @{ Path = $cmd.Source; Version = [version]($out[-1] -replace '[^0-9.].*$', '') }
}

# Runs a Python and returns its executable and version, or $null. The Windows Store's python.exe
# stand-in and a py launcher without that version both fail here, which counts as not found.
function Get-Python([string]$Exe, [string[]]$Pre) {
    $ErrorActionPreference = 'Continue'   # their complaints on stderr aren't errors here
    $out = @(& $Exe @Pre -c "import sys; print(sys.executable); print('.'.join(map(str, sys.version_info[:3])))" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $out.Count -lt 2) { return $null }
    return @{ Path = $out[-2]; Version = $out[-1] }
}

# Files unzipped from a download keep the internet mark, which stops the modules loading.
Get-ChildItem -LiteralPath $kit -Recurse -File | Unblock-File

# 1. PowerShell. CI runs the lint and the tests in Windows PowerShell 5.1 and PowerShell 7.
$shells = @()
foreach ($s in @(@{ Name = 'Windows PowerShell'; Exe = 'powershell.exe' }, @{ Name = 'PowerShell 7'; Exe = 'pwsh.exe' })) {
    $t = Get-Toolchain $s.Name
    $found = Get-Shell $s.Exe
    if (-not $found) { Add-Missing $s.Name "$($s.Exe) is not on PATH" }
    elseif ($found.Version -lt [version]$t.Minimum) { Add-Missing $s.Name "found $($found.Version) at $($found.Path)" }
    else { Say "$($s.Name) $($found.Version) at $($found.Path)"; $shells += , $found }
}

# 2. Pester and PSScriptAnalyzer from offline\powershell, checked in each PowerShell found.
# tools\lint.ps1 and tools\test.ps1 load them from there by path.
$moduleRoot = Join-Path $offline 'powershell'
$absent = @($pins.Modules | Where-Object { -not (Test-Path -LiteralPath ([IO.Path]::Combine($moduleRoot, $_.Name, $_.Version, "$($_.Name).psd1"))) })
if ($absent) {
    $missing.Add("offline\powershell has no $(($absent | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '); download the kit again.")
} else {
    $pairs = ($pins.Modules | ForEach-Object { "'$($_.Name)', '$($_.Version)'" }) -join ', '
    $check = @"
`$ErrorActionPreference = 'Stop'
`$p = @($pairs)
for (`$i = 0; `$i -lt `$p.Count; `$i += 2) {
    `$m = Import-Module ([IO.Path]::Combine('$($moduleRoot -replace "'", "''")', `$p[`$i], `$p[`$i + 1], `$p[`$i] + '.psd1')) -Force -PassThru
    if (`$m.Version -ne [version]`$p[`$i + 1]) { throw "`$(`$p[`$i]) loaded as `$(`$m.Version)" }
    'loads ' + `$m.Name + ' ' + `$m.Version + ' from ' + `$m.ModuleBase
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($check))
    foreach ($s in $shells) {
        $out = @(& $s.Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded)
        if ($LASTEXITCODE -ne 0) { $missing.Add("The kit's modules don't load in $($s.Path) $($s.Version); the error is above.") }
        else { foreach ($l in $out) { Say "  PowerShell $($s.Version) $l" } }
    }
    # So this window, if you ran this with &, finds them by name too
    if (($env:PSModulePath -split ';') -notcontains $moduleRoot) { $env:PSModulePath = "$moduleRoot;$env:PSModulePath" }
}

# 3. Python for the panel: .venv, with the wheels from offline\python and nothing from an index
$candidates = @()
if ($Python) { $candidates += , @($Python) }
else {
    if (Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue) { $candidates += , @('py.exe', "-$pySeries") }
    foreach ($n in 'python.exe', 'python3.exe') {
        if (Get-Command $n -CommandType Application -ErrorAction SilentlyContinue) { $candidates += , @($n) }
    }
}
$py = $null
$seen = @()
foreach ($c in $candidates) {
    $info = Get-Python $c[0] @($c | Select-Object -Skip 1)
    if (-not $info) { continue }
    if ($info.Version -like "$pySeries.*") { $py = $info; break }
    $seen += "$($info.Version) at $($info.Path)"
}
if (-not $py) {
    $why = "no Python $pySeries found"
    if ($seen) { $why += " (found $($seen -join '; '))" }
    if (-not $Python) { $why += '; pass -Python <path to python.exe> if it is installed' }
    Add-Missing 'Python' $why
} else {
    Say "Python $($py.Version) at $($py.Path)"
    $venv   = Join-Path $kit '.venv'
    $venvPy = Join-Path $venv 'Scripts\python.exe'
    $have   = $null
    if (Test-Path -LiteralPath $venvPy) { $have = Get-Python $venvPy @() }
    if (-not $have -or $have.Version -notlike "$pySeries.*") {
        if (Test-Path -LiteralPath $venv) { Remove-Item -LiteralPath $venv -Recurse -Force }
        & $py.Path -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw "python -m venv $venv failed" }
    }
    & $venvPy -m pip install --no-index --find-links (Join-Path $offline 'python') --disable-pip-version-check --quiet `
        -r (Join-Path $kit 'docs\art\requirements.txt')
    if ($LASTEXITCODE -ne 0) { $missing.Add('pip could not install docs\art\requirements.txt from offline\python; the error is above.') }
    else { Say "  .venv has $(@(& $venvPy -m pip freeze --disable-pip-version-check) -join ', ')" }
}

# 4. Not needed for the checks
$git = Get-Toolchain 'Git'
if (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue) { Say "Git: $(& git.exe --version)" }
else { Say "Git isn't installed; you only need it to send a change: $($git.Url)" }
Say 'qbittorrent-nox: the tests against a real Web UI run on Linux only; here they are skipped.'

Write-Host ''
Say 'Next, in this folder:'
Write-Host "  cd `"$kit`""
Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\lint.ps1'
Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test.ps1'
Write-Host '  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\test.ps1'
Write-Host '  .\.venv\Scripts\python.exe docs\art\make-panel.py'
Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-offline.ps1'
Write-Host ''
Say 'make-panel.py redraws docs\assets\panel-*.svg; unchanged files mean the panel matches the script.'
$version = (Select-String -LiteralPath (Join-Path $kit 'port-sync.ps1') -Pattern "PortSyncVersion = '([^']+)'").Matches[0].Groups[1].Value
Say "build-offline.ps1 writes dist\port-sync-$version-offline.zip."
Say 'tests\install.Tests.ps1 runs only elevated and replaces %LOCALAPPDATA%\port-sync: on a PC where'
Say 'port-sync is installed, run the tests from a normal window.'
Say "To load the modules by name in a window: `$env:PSModulePath = '$moduleRoot;' + `$env:PSModulePath"

if ($missing.Count) {
    Write-Host ''
    Say "$($missing.Count) missing:"
    foreach ($m in $missing) { Write-Host "  - $m" }
    exit 1
}
Say 'Ready.'
exit 0
