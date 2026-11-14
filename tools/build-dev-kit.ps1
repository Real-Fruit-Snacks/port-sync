# build-dev-kit.ps1 - builds dist\port-sync-<version>-dev-windows-x64.zip: the repo at a git ref
# plus every package its checks need, so port-sync can be built, linted, tested, its panel
# redrawn and its offline zip built on a Windows x64 PC with no internet. It unzips to one
# folder, port-sync-<version>-dev\, with offline\ next to the source:
#   cargo\vendor\     every Rust crate Cargo.lock names (cargo vendor), each with its licence
#   cargo\config.toml the cargo settings that build from cargo\vendor only
#   powershell\       Pester and PSScriptAnalyzer, as Save-Module writes them
#   python\           wheels for docs/art/requirements.txt, for CPython on win_amd64
#   licences\         the licence and notices of every package above
#   setup.ps1         from tools/dev-kit/setup.ps1
#   toolchains.psd1   the toolchains the kit doesn't bundle, for setup.ps1
#   README.md         from tools/dev-kit/README.template.md
# The kit's root also gets THIRD-PARTY-LICENSES.txt (-ThirdPartyLicences), which the offline zip carries.
# Versions come from tools/versions.psd1, Cargo.lock and docs/art/requirements.txt, the files
# CI reads.
#
#   ./tools/build-dev-kit.ps1 [-Ref HEAD] [-OutDir <folder>] [-Python python] [-PwshVersion 7.x.y]
#                             [-ThirdPartyLicences THIRD-PARTY-LICENSES.txt]
#
# Needs the internet, Git for Windows, cargo, a Python with pip (any version: it downloads wheels for
# the pinned one), PowerShellGet with the PowerShell Gallery, and Windows 10 or later (tar.exe).
# The kit's toolchain table lists the PowerShell 7 and Git that built it; CI builds it on the
# runner its tests use.
[CmdletBinding()]
param(
    [string]$Ref = 'HEAD',
    [string]$OutDir,                 # default: dist\ in the repo
    [string]$Python = 'python',      # runs pip download
    [string]$PwshVersion,            # default: the pwsh on PATH
    [string]$ThirdPartyLicences      # default: THIRD-PARTY-LICENSES.txt in the repo
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'

function Say([string]$Message) { Write-Host "[dev-kit] $Message" }

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

# The gallery, PyPI and GitHub all fail now and then from hosted runners: 5 tries, 15/30/45/60 s apart.
function Invoke-WithRetry([string]$What, [scriptblock]$Action) {
    for ($try = 1; $true; $try++) {
        try { return (& $Action) }
        catch {
            if ($try -ge 5) { throw }
            Write-Warning "$What failed (try $try): $_"
            Start-Sleep -Seconds (15 * $try)
        }
    }
}

function Save-Download([string]$Url, [string]$Path) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Invoke-WithRetry "download $Url" { Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing }
}

function Test-Url([string]$Url) {
    Invoke-WithRetry "check $Url" {
        $r = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing
        if ($r.StatusCode -ne 200) { throw "$Url answered $($r.StatusCode)" }
    }
}

function Get-GitHubJson([string]$Path) {
    $headers = @{ 'User-Agent' = 'port-sync-build-dev-kit'; Accept = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }
    Invoke-WithRetry "GitHub API $Path" { Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers }
}

$src = & git -C $root show "$($Ref):Cargo.toml"
if ($LASTEXITCODE -ne 0) { throw "git can't read Cargo.toml at $Ref" }
if (($src -join "`n") -notmatch '(?m)^version = "([^"]+)"') { throw "no version in Cargo.toml at $Ref" }
$version = $Matches[1]
if (-not $ThirdPartyLicences) { $ThirdPartyLicences = Join-Path $root 'THIRD-PARTY-LICENSES.txt' }
if (-not (Test-Path -LiteralPath $ThirdPartyLicences)) { throw "no $ThirdPartyLicences; run tools/third-party-licences.ps1" }
$name    = "port-sync-$version-dev"
$stage   = Join-Path ([IO.Path]::GetTempPath()) ('port-sync-dev-kit-' + [guid]::NewGuid().ToString('N'))
$kit     = Join-Path $stage $name
$offline = Join-Path $kit 'offline'

try {
    # 1. The repo at $Ref, without .git
    New-Item -ItemType Directory -Path $stage | Out-Null
    $source = Join-Path $stage 'source.zip'
    Invoke-Native 'git' @('-C', $root, 'archive', '--format=zip', "--prefix=$name/", '-o', $source, $Ref)
    Invoke-Native $tar @('-x', '-f', $source, '-C', $stage)
    Remove-Item -LiteralPath $source
    if (Test-Path -LiteralPath $offline) { throw "the repo at $Ref already has an offline\ folder" }
    Say "source of port-sync $version at $Ref"

    # Pins as of $Ref, so an older tag builds with its own versions
    $pins     = Import-PowerShellDataFile (Join-Path $kit 'tools\versions.psd1')
    $pySeries = (($pins.Python -split '\.')[0..1]) -join '.'
    $licences = Join-Path $offline 'licences'

    Copy-Item -LiteralPath $ThirdPartyLicences -Destination (Join-Path $kit 'THIRD-PARTY-LICENSES.txt')

    # 2. Rust crates: everything Cargo.lock names, for every platform, each with its licence
    $have = (& rustc --version) -join ''
    if ($have -notmatch "^rustc $([regex]::Escape($pins.Rust))\b") { Write-Warning "tools\versions.psd1 pins Rust $($pins.Rust); this machine runs '$have'." }
    New-Item -ItemType Directory -Path (Join-Path $offline 'cargo') -Force | Out-Null
    Push-Location $kit
    try {
        Invoke-WithRetry 'cargo vendor' { Invoke-Native 'cargo' @('vendor', '--locked', '--versioned-dirs', 'offline/cargo/vendor') | Out-Null }
    } finally { Pop-Location }
    [IO.File]::WriteAllText((Join-Path $offline 'cargo\config.toml'), @'
# Build from the crates in offline\cargo\vendor only. offline\setup.ps1 adds this to
# .cargo\config.toml; the path is relative to the kit's root.
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "offline/cargo/vendor"
'@)
    $crates = @(Get-ChildItem -LiteralPath (Join-Path $offline 'cargo\vendor') -Directory)
    Say "vendored $($crates.Count) crates"

    # 3. PowerShell modules: offline\powershell\<Name>\<Version>\
    $modules = Join-Path $offline 'powershell'
    New-Item -ItemType Directory -Path $modules -Force | Out-Null
    foreach ($m in $pins.Modules) {
        Invoke-WithRetry "Save-Module $($m.Name) $($m.Version)" {
            if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) { Register-PSRepository -Default }
            Save-Module -Name $m.Name -RequiredVersion $m.Version -Repository PSGallery -Path $modules -Force
        }
        if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($modules, $m.Name, $m.Version, "$($m.Name).psd1")))) {
            throw "Save-Module didn't write $($m.Name) $($m.Version)"
        }
        Say "saved $($m.Name) $($m.Version)"
    }
    $pinned = @($pins.Modules | ForEach-Object { $_.Name })
    $extra  = @(Get-ChildItem -LiteralPath $modules -Directory | Where-Object { $pinned -notcontains $_.Name })
    if ($extra) { throw "Save-Module brought modules that aren't pinned: $($extra.Name -join ', ')" }

    # Each module's licence, and the DLLs it ships. A new pin that brings a DLL not listed here
    # stops the build until its licence is added.
    foreach ($m in $pins.Modules) {
        $base = [IO.Path]::Combine($modules, $m.Name, $m.Version)
        $dir  = Join-Path $licences "$($m.Name)-$($m.Version)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        switch ($m.Name) {
            'Pester' {
                # Apache-2.0; the package has no copy of it
                Save-Download "https://raw.githubusercontent.com/pester/Pester/$($m.Version)/LICENSE" (Join-Path $dir 'LICENSE')
                $known = @('Pester.dll')
            }
            'PSScriptAnalyzer' {
                # MIT; ThirdPartyNotices.txt covers Newtonsoft.Json (MIT)
                Copy-Item -LiteralPath (Join-Path $base 'LICENSE'), (Join-Path $base 'ThirdPartyNotices.txt') -Destination $dir
                if (-not (Select-String -LiteralPath (Join-Path $dir 'ThirdPartyNotices.txt') -SimpleMatch 'Newtonsoft.Json' -Quiet)) {
                    throw "PSScriptAnalyzer's ThirdPartyNotices.txt no longer covers Newtonsoft.Json"
                }
                # Pluralize.NET (MIT) ships in PSv7\ but isn't in the notices
                $dll = Get-ChildItem -LiteralPath $base -Recurse -Filter 'Pluralize.NET.dll' | Select-Object -First 1
                $pv  = ([version]$dll.VersionInfo.FileVersion).ToString(3)
                Save-Download "https://raw.githubusercontent.com/sarathkcm/Pluralize.NET/v$pv/LICENCE" ([IO.Path]::Combine($licences, "Pluralize.NET-$pv", 'LICENCE'))
                $known = @('Microsoft.Windows.PowerShell.ScriptAnalyzer.dll', 'Microsoft.Windows.PowerShell.ScriptAnalyzer.BuiltinRules.dll',
                           'Microsoft.PowerShell.CrossCompatibility.dll', 'Newtonsoft.Json.dll', 'Pluralize.NET.dll')
            }
            default { throw "no licence source for module $($m.Name); add one to tools/build-dev-kit.ps1" }
        }
        $unknown = @(Get-ChildItem -LiteralPath $base -Recurse -Filter '*.dll' | Where-Object { $known -notcontains $_.Name })
        if ($unknown) { throw "$($m.Name) $($m.Version) ships DLLs with no licence here: $($unknown.Name -join ', ')" }
    }

    # 4. Wheels for the panel, binary only, for CPython <series> on Windows x64
    $wheels = Join-Path $offline 'python'
    $req    = Join-Path $kit 'docs\art\requirements.txt'
    Invoke-WithRetry 'pip download' {
        Invoke-Native $Python @('-m', 'pip', 'download', '--disable-pip-version-check', '--no-cache-dir', '--only-binary=:all:',
            '--platform', 'win_amd64', '--implementation', 'cp', '--python-version', $pySeries, '-d', $wheels, '-r', $req)
    }
    $files = @(Get-ChildItem -LiteralPath $wheels -Filter '*.whl')
    foreach ($line in Get-Content -LiteralPath $req) {
        if ($line -notmatch '^\s*([A-Za-z0-9_.-]+)==([^\s;#]+)') { continue }
        $dist = $Matches[1] -replace '[-_.]+', '_'
        $ver  = $Matches[2]
        if (-not ($files | Where-Object { $_.Name -match ('^' + [regex]::Escape($dist) + '-' + [regex]::Escape($ver) + '-') })) {
            throw "no wheel for $line"
        }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($whl in $files) {
        $parts = $whl.Name -split '-'
        $dir   = Join-Path $licences "$($parts[0])-$($parts[1])"
        $zip   = [IO.Compression.ZipFile]::OpenRead($whl.FullName)
        try {
            $entries = @($zip.Entries | Where-Object { $_.FullName -match '^[^/]+\.dist-info/(licenses/.+|(LICEN[CS]E|COPYING|NOTICE|AUTHORS)[^/]*)$' -and $_.Name })
            if (-not $entries) { throw "$($whl.Name) has no licence file" }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            foreach ($e in $entries) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dir $e.Name), $true) }
        } finally { $zip.Dispose() }
        Say "wheel $($whl.Name)"
    }

    # 5. The toolchains the kit doesn't bundle, at the versions CI uses
    if (-not $PwshVersion) {
        $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pwsh) { throw 'PowerShell 7 (pwsh) is not on PATH; pass -PwshVersion' }
        $PwshVersion = @(& $pwsh.Source -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()')[-1]
    }
    $psm1 = Get-Content -LiteralPath ([IO.Path]::Combine($modules, 'PSScriptAnalyzer', ($pins.Modules | Where-Object { $_.Name -eq 'PSScriptAnalyzer' }).Version, 'PSScriptAnalyzer.psm1')) -Raw
    if ($psm1 -notmatch "minimumPowerShellCoreVersion = '([\d.]+)'") { throw "can't find PSScriptAnalyzer's minimum PowerShell 7 version" }
    $pwshMinimum = $Matches[1]

    $gitVersion = ((& git --version) -replace '^git version ', '').Trim()
    if ($gitVersion -notmatch '\.windows\.\d+$') { throw "git $gitVersion isn't Git for Windows" }
    $gitRelease = Get-GitHubJson "repos/git-for-windows/git/releases/tags/v$gitVersion"
    $gitUrl = ($gitRelease.assets | Where-Object { $_.name -match '^Git-.+-64-bit\.exe$' } | Select-Object -First 1).browser_download_url
    if (-not $gitUrl) { throw "no 64-bit installer in Git for Windows v$gitVersion" }

    $toolchains = @(
        [ordered]@{ Name = 'Rust'; Version = $pins.Rust; Minimum = $pins.Rust; Usable = "$($pins.Rust), x86_64-pc-windows-msvc"
                    For = 'building and testing port-sync.exe'; Url = "https://static.rust-lang.org/dist/rust-$($pins.Rust)-x86_64-pc-windows-msvc.msi"; Note = '' }
        [ordered]@{ Name = 'Visual Studio Build Tools'; Version = '2022'; Minimum = ''; Usable = '2019 or later, with the C++ workload'
                    For = "Rust's linker"; Url = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'; Note = 'For a PC with no internet, make an offline layout first (vs_BuildTools.exe --layout)' }
        [ordered]@{ Name = 'Windows PowerShell'; Version = '5.1'; Minimum = '5.1'; Usable = '5.1'
                    For = 'the lint and the tests, which CI runs in both PowerShells'; Url = ''; Note = 'Built into Windows 10 and 11' }
        [ordered]@{ Name = 'PowerShell 7'; Version = $PwshVersion; Minimum = $pwshMinimum; Usable = "$pwshMinimum or later"
                    For = 'the tests in PowerShell 7'; Url = "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/PowerShell-$PwshVersion-win-x64.msi"; Note = '' }
        [ordered]@{ Name = 'Python'; Version = $pins.Python; Minimum = $pySeries; Usable = "any $pySeries.x"
                    For = 'redrawing the panel (docs\art\make-panel.py)'; Url = "https://www.python.org/ftp/python/$($pins.Python)/python-$($pins.Python)-amd64.exe"; Note = '' }
        [ordered]@{ Name = 'Git'; Version = $gitVersion; Minimum = ''; Usable = 'any'
                    For = 'sending a change; nothing in the kit runs it'; Url = $gitUrl; Note = 'Optional' }
        [ordered]@{ Name = 'qbittorrent-nox'; Version = $pins.QbittorrentNox; Minimum = ''; Usable = $pins.QbittorrentNox
                    For = 'the tests against a real Web UI, which run on Linux only'; Url = 'https://packages.ubuntu.com/noble/qbittorrent-nox'
                    Note = "Ubuntu 24.04's package, as CI uses; not bundled (GPL)" }
    )
    foreach ($t in $toolchains) { if ($t.Url) { Test-Url $t.Url } }

    $psd1 = @("# Written by tools/build-dev-kit.ps1 for port-sync ${version}: the toolchains this kit doesn't bundle.", '@{', '    Toolchains = @(')
    foreach ($t in $toolchains) {
        $psd1 += '        @{ ' + (($t.Keys | ForEach-Object { "$_ = '" + ($t[$_] -replace "'", "''") + "'" }) -join '; ') + ' }'
    }
    $psd1 += '    )', '}'
    Set-Content -LiteralPath (Join-Path $offline 'toolchains.psd1') -Value $psd1 -Encoding Ascii

    # 6. setup.ps1 and README.md
    Copy-Item -LiteralPath (Join-Path $kit 'tools\dev-kit\setup.ps1') -Destination (Join-Path $offline 'setup.ps1')
    $rows = foreach ($t in $toolchains) {
        $link = if ($t.Url) { "[$(($t.Url -split '/')[-1])]($($t.Url))" } else { '-' }
        $what = if ($t.Note) { "$($t.For). $($t.Note)" } else { $t.For }
        $what = $what.Substring(0, 1).ToUpper() + $what.Substring(1)
        "| $($t.Name) | $($t.Version) | $($t.Usable) | $what | $link |"
    }
    $listModules = ($pins.Modules | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ' and '
    $listWheels  = ($files | ForEach-Object { $p = $_.Name -split '-'; "$($p[0]) $($p[1])" }) -join ' and '
    $readme = (Get-Content -LiteralPath (Join-Path $kit 'tools\dev-kit\README.template.md') -Raw) `
        -replace '\{\{VERSION\}\}', $version -replace '\{\{PYSERIES\}\}', $pySeries `
        -replace '\{\{MODULES\}\}', $listModules -replace '\{\{WHEELS\}\}', $listWheels `
        -replace '\{\{CRATES\}\}', $crates.Count -replace '\{\{RUST\}\}', $pins.Rust `
        -replace '\{\{TOOLCHAINS\}\}', ($rows -join "`n")
    $readme = ($readme -split "`r?`n" | Where-Object { $_ -notmatch '^<!--' }) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $offline 'README.md'), $readme)

    # 7. The zip: one folder, port-sync-<version>-dev\
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $out = Join-Path $OutDir "$name-windows-x64.zip"
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    Invoke-Native $tar @('-a', '-c', '-f', $out, '-C', $stage, $name)
    Say "built $out ($((Get-Item -LiteralPath $out).Length) bytes)"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
