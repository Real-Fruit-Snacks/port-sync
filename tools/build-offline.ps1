# build-offline.ps1 - builds dist\port-sync-<version>-offline.zip, everything a PC with no
# internet needs to install and run port-sync. Unzipped, it is one folder; install.ps1 run there
# installs the port-sync.ps1 next to it instead of downloading one.
#   ./tools/build-offline.ps1 [-OutDir <folder>]
# Windows 10 or later (it zips with the built-in tar.exe). Needs no network.
param(
    [string]$OutDir   # default: dist\ in the repo
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

$version = (Select-String -LiteralPath (Join-Path $root 'port-sync.ps1') -Pattern "PortSyncVersion = '([^']+)'").Matches[0].Groups[1].Value
$name    = "port-sync-$version"
$files   = 'install.ps1', 'port-sync.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md', 'docs\setup-guide.md'

$stage = Join-Path ([IO.Path]::GetTempPath()) ('port-sync-offline-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($f in $files) {
        $dest = [IO.Path]::Combine($stage, $name, $f)
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination $dest
    }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $zip = Join-Path $OutDir "$name-offline.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -a -c -f $zip -C $stage $name
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }
    Write-Host "built $zip ($((Get-Item -LiteralPath $zip).Length) bytes)"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
