# third-party-licences.ps1 - writes THIRD-PARTY-LICENSES.txt: the licences of the Rust crates
# built into port-sync.exe, which every download carries. Runs cargo-about at the version and
# checksum in tools/versions.psd1, downloading it into dist\ the first time.
#   ./tools/third-party-licences.ps1 [-Out <file>]
# Needs cargo, and the internet the first time. Fails on a crate whose licence about.toml
# doesn't accept.
param(
    [string]$Out   # default: THIRD-PARTY-LICENSES.txt in the repo
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root 'THIRD-PARTY-LICENSES.txt' }
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
$pin = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'versions.psd1')).CargoAbout

$name = "cargo-about-$($pin.Version)-x86_64-pc-windows-msvc"
$tools = Join-Path $root 'dist\tools'
$exe = Join-Path $tools "$name\cargo-about.exe"
if (-not (Test-Path -LiteralPath $exe)) {
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    $archive = Join-Path $tools "$name.tar.gz"
    Invoke-WebRequest -Uri "https://github.com/EmbarkStudios/cargo-about/releases/download/$($pin.Version)/$name.tar.gz" -OutFile $archive -UseBasicParsing
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $pin.Sha256) { Remove-Item -LiteralPath $archive -Force; throw "$name.tar.gz has SHA-256 $hash, not $($pin.Sha256)" }
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -x -f $archive -C $tools
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }
    Remove-Item -LiteralPath $archive -Force
}

Push-Location $root
try {
    & $exe generate --locked --fail about.hbs -o $Out
    if ($LASTEXITCODE -ne 0) { throw "cargo-about failed with exit code $LASTEXITCODE" }
} finally { Pop-Location }
Write-Host "wrote $Out ($((Get-Item -LiteralPath $Out).Length) bytes)"
