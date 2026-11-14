# build-offline.ps1 - builds dist\port-sync-<version>-offline.zip, everything a PC with no
# internet needs to install and run port-sync, and dist\port-sync.exe, the program on its own
# (what the install line downloads). Unzipped, the zip is one folder; install.ps1 run there
# installs the port-sync.exe next to it instead of downloading one.
#   ./tools/build-offline.ps1 [-OutDir <folder>] [-Exe <port-sync.exe>]
# Needs the program built first (cargo build --release --locked) and THIRD-PARTY-LICENSES.txt
# (tools/third-party-licences.ps1, or the copy in the dev kit). Windows 10 or later (it zips
# with the built-in tar.exe). Needs no network.
param(
    [string]$OutDir,   # default: dist\ in the repo
    [string]$Exe       # default: target\release\port-sync.exe
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
if (-not $Exe) { $Exe = Join-Path $root 'target\release\port-sync.exe' }
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

$cargo = Get-Content -LiteralPath (Join-Path $root 'Cargo.toml') -Raw
if ($cargo -notmatch '(?m)^version = "([^"]+)"') { throw 'no version in Cargo.toml' }
$version = $Matches[1]
if (-not (Test-Path -LiteralPath $Exe)) { throw "no $Exe; build it first: cargo build --release --locked" }
$said = (@(& $Exe --version | ForEach-Object { "$_" }) -join '').Trim()
if ($said -ne "port-sync $version") { throw "$Exe says '$said', but Cargo.toml is $version; rebuild it" }
$licences = Join-Path $root 'THIRD-PARTY-LICENSES.txt'
if (-not (Test-Path -LiteralPath $licences)) { throw 'no THIRD-PARTY-LICENSES.txt; run tools/third-party-licences.ps1' }

$name  = "port-sync-$version"
$files = 'install.ps1', 'README.md', 'LICENSE', 'THIRD-PARTY-LICENSES.txt', 'CHANGELOG.md', 'docs\setup-guide.md'

$stage = Join-Path ([IO.Path]::GetTempPath()) ('port-sync-offline-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($f in $files) {
        $dest = [IO.Path]::Combine($stage, $name, $f)
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination $dest
    }
    Copy-Item -LiteralPath $Exe -Destination ([IO.Path]::Combine($stage, $name, 'port-sync.exe'))
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $zip = Join-Path $OutDir "$name-offline.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -a -c -f $zip -C $stage $name
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }
    Copy-Item -LiteralPath $Exe -Destination (Join-Path $OutDir 'port-sync.exe') -Force
    Write-Host "built $zip ($((Get-Item -LiteralPath $zip).Length) bytes) and $(Join-Path $OutDir 'port-sync.exe')"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
