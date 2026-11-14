# Pester 5. Runs install.ps1 for real: it registers scheduled tasks (as 2.x and 1.x did) to
# migrate from, so it only runs on Windows from an elevated session (GitHub's windows runners
# are). It uses your real %LOCALAPPDATA%\port-sync folder and Run key and deletes them at the
# end: don't run it on a machine where port-sync is installed.
# The program it installs: $env:PORT_SYNC_EXE, or target\release\port-sync.exe (cargo build --release).

$isWindowsAdmin = $false
if ($env:OS -eq 'Windows_NT') {
    $isWindowsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

Describe 'install.ps1' -Tag 'Windows' -Skip:(-not $isWindowsAdmin) {
    BeforeAll {
        # script: scope so the It blocks see them (and the analyzer knows they're used)
        $root             = Split-Path -Parent $PSScriptRoot
        $script:installer = Join-Path $root 'install.ps1'
        $script:exe       = if ($env:PORT_SYNC_EXE) { $env:PORT_SYNC_EXE } else { Join-Path $root 'target\release\port-sync.exe' }
        if (-not (Test-Path -LiteralPath $exe)) { throw "build the program first (cargo build --release), or set PORT_SYNC_EXE: no $exe" }
        $script:dir       = Join-Path $env:LOCALAPPDATA 'port-sync'
        $script:legacyDir = Join-Path $env:LOCALAPPDATA 'proton-qbit-port-sync'
        $script:target    = Join-Path $dir 'port-sync.exe'
        $script:config    = Join-Path $dir 'config.json'
        $script:runKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $script:shortcut  = Join-Path ([Environment]::GetFolderPath('Programs')) 'port-sync.lnk'
        $script:version   = (@(& $exe --version | ForEach-Object { "$_" }) -join '') -replace '^port-sync ', ''

        # An unzipped offline download: install.ps1 with a port-sync.exe next to it
        $script:zipName      = 'port-sync-zip-' + [guid]::NewGuid().ToString('N')
        $script:zipDir       = Join-Path ([IO.Path]::GetTempPath()) $zipName
        $script:zipInstaller = Join-Path $zipDir 'install.ps1'
        New-Item -ItemType Directory -Path $zipDir | Out-Null
        Copy-Item -LiteralPath $installer -Destination $zipInstaller
        Copy-Item -LiteralPath $exe -Destination (Join-Path $zipDir 'port-sync.exe')

        function script:Get-RunValue { (Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue).'port-sync' }
        function script:Read-Password([string]$Path) {
            $s = (Get-Content -LiteralPath $Path -Raw).Trim() | ConvertTo-SecureString
            (New-Object Net.NetworkCredential('', $s)).Password
        }
        function script:Register-OldTask([string]$Name, [string]$Arguments) {
            $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $Arguments
            Register-ScheduledTask -TaskName $Name -Action $a | Out-Null
        }
        function script:Get-TrayProcess { @(Get-Process -Name 'port-sync' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $target }) }
    }

    AfterAll {
        Get-TrayProcess | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $runKey -Name 'port-sync' -ErrorAction SilentlyContinue
        if ($shortcut -and (Test-Path -LiteralPath $shortcut)) { Remove-Item -LiteralPath $shortcut -Force }
        foreach ($n in 'port-sync', 'Proton qBittorrent port sync') { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
        foreach ($d in $zipDir, $dir, $legacyDir) { if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force } }
    }

    It 'migrates a 1.x install: task removed, password and the edited adapter kept' {
        New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
        ConvertTo-SecureString 'legacy-pass' -AsPlainText -Force | ConvertFrom-SecureString |
            Set-Content -LiteralPath (Join-Path $legacyDir 'qbit-pass.txt')
        Set-Content -LiteralPath (Join-Path $legacyDir 'proton-qbit-port-sync.ps1') -Value @(
            'param('
            "    [string]`$QbitUrl     = 'http://127.0.0.1:8080',"
            "    [string]`$Adapter     = 'ProTUN',   # edited by hand"
            '    [int]$IntervalSec    = 15'
            ')'
        )
        Register-OldTask 'Proton qBittorrent port sync' '-NoProfile -Command exit'

        & $installer -Source $exe -NoPrompt -NoStart

        Get-ScheduledTask -TaskName 'Proton qBittorrent port sync' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Read-Password (Join-Path $dir 'qbit-pass.txt') | Should -Be 'legacy-pass'
        $c = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        $c.adapter | Should -Be 'ProTUN'
        @($c.PSObject.Properties).Count | Should -Be 1 -Because 'only the changed setting is written'
    }

    It 'migrates a 2.x install: task and script removed, the task''s parameters kept' {
        Remove-Item -LiteralPath $config -Force
        Set-Content -LiteralPath (Join-Path $dir 'port-sync.ps1') -Value "`$script:PortSyncVersion = '2.1.0'"
        Register-OldTask 'port-sync' "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\port-sync.ps1`" -Adapter 'ProtonVPN TUN' -RecheckSec 120"

        & $installer -Source $exe -NoPrompt -NoStart

        Get-ScheduledTask -TaskName 'port-sync' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $dir 'port-sync.ps1') | Should -BeFalse
        $c = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        $c.adapter    | Should -Be 'ProtonVPN TUN' -Because 'the task''s argument beats the 1.x script''s default'
        $c.recheckSec | Should -Be 120
    }

    It 'installs the program, starts it at sign-in from the Run key (no task), and adds a Start menu entry' {
        (Get-FileHash $target).Hash | Should -Be (Get-FileHash $exe).Hash
        Test-Path -LiteralPath (Join-Path $dir 'port-sync.new.exe') | Should -BeFalse
        Get-RunValue | Should -Be "`"$target`" --autostart"
        (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath | Should -Be $target
        Get-ScheduledTask -TaskName 'port-sync' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'keeps the password and config.json on a re-run' {
        $pass = Get-Content -LiteralPath (Join-Path $dir 'qbit-pass.txt') -Raw
        $cfg  = Get-Content -LiteralPath $config -Raw
        & $installer -Source $exe -NoPrompt -NoStart
        Get-Content -LiteralPath (Join-Path $dir 'qbit-pass.txt') -Raw | Should -Be $pass
        Get-Content -LiteralPath $config -Raw | Should -Be $cfg
    }

    It 'refuses a file that is not port-sync.exe and changes nothing' {
        $bogus = Join-Path ([IO.Path]::GetTempPath()) 'not-port-sync.ps1'
        Set-Content -LiteralPath $bogus -Value 'Write-Host hi'
        $before = (Get-FileHash $target).Hash
        $out = (& $installer -Source $bogus -NoPrompt -NoStart 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $out | Should -Match "isn't port-sync\.exe"
        (Get-FileHash $target).Hash | Should -Be $before
        Test-Path -LiteralPath (Join-Path $dir 'port-sync.new.exe') | Should -BeFalse
    }

    It 'starts the tray app, and replaces a running one on a re-run' {
        & $installer -Source $exe -NoPrompt
        $first = @()
        for ($i = 0; $i -lt 50 -and -not $first; $i++) { Start-Sleep -Milliseconds 100; $first = Get-TrayProcess }
        $first | Should -HaveCount 1
        Start-Sleep -Seconds 1
        Select-String -LiteralPath (Join-Path $dir 'sync.log') -SimpleMatch "port-sync $version watching" -Quiet | Should -BeTrue

        & $installer -Source $exe -NoPrompt
        Start-Sleep -Seconds 1
        $first[0].HasExited | Should -BeTrue -Because 'the installer stops the old one before replacing the exe'
        Get-TrayProcess | Should -HaveCount 1
    }

    It 'run as a file with no -Source, installs the port-sync.exe next to it' {
        $out = (& $zipInstaller -NoPrompt -NoStart 6>&1 | ForEach-Object { "$_" }) -join "`n"   # Out-String would wrap long lines in 5.1
        # by folder name: the temp path can come back in its short (8.3) form
        $out | Should -Match "installing .*$zipName\\port-sync\.exe"
        $out | Should -Match "uninstall: powershell -NoProfile -ExecutionPolicy Bypass -File `".*$zipName\\install\.ps1`" -Uninstall"
        Get-TrayProcess | Should -HaveCount 0 -Because 'it stopped the running one and -NoStart started none'
    }

    It 'under irm | iex, downloads from the release and checks it against SHA256SUMS.txt' {
        # iex runs install.ps1 in the wrapper's scope, so this stand-in replaces the download
        $wrapper = Join-Path $zipDir 'iex-wrapper.ps1'
        $hash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
        $make = {
            param([string]$Sum)
            Set-Content -LiteralPath $wrapper -Value @(
                'function Invoke-WebRequest { param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)'
                "    if (`$Uri -like '*/releases/latest/download/port-sync.exe') { Copy-Item -LiteralPath '$exe' -Destination `$OutFile }"
                "    elseif (`$Uri -like '*/releases/latest/download/SHA256SUMS.txt') { Set-Content -LiteralPath `$OutFile -Value @('0000  port-sync-$version-offline.zip', '$Sum  port-sync.exe') }"
                "    else { throw `"unexpected download `$Uri`" } }"
                'function Read-Host { param([string]$Prompt) }'
                "Get-Content -LiteralPath '$installer' -Raw | Invoke-Expression"
            )
        }
        Remove-Item -LiteralPath $target -Force
        & $make ('f' * 64)
        $out = (& $wrapper 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $out | Should -Match "doesn't match the release's SHA256SUMS\.txt"
        Test-Path -LiteralPath $target | Should -BeFalse

        & $make $hash
        $out = (& $wrapper 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $out | Should -Match "installed port-sync $([regex]::Escape($version))"
        (Get-FileHash $target).Hash | Should -Be (Get-FileHash $exe).Hash
        Get-TrayProcess | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    It 'uninstalls, run from that folder too: tray stopped, Run entry, Start menu entry and both folders gone' {
        & $installer -Source $exe -NoPrompt
        Start-Sleep -Seconds 1
        & $zipInstaller -Uninstall
        Get-TrayProcess | Should -HaveCount 0
        Get-RunValue | Should -BeNullOrEmpty
        Test-Path -LiteralPath $shortcut | Should -BeFalse
        Test-Path -LiteralPath $dir       | Should -BeFalse
        Test-Path -LiteralPath $legacyDir | Should -BeFalse
    }
}
