# Pester 5. Registers and removes a real scheduled task, so it only runs on Windows
# from an elevated session (GitHub's windows runners are). It uses your real
# %LOCALAPPDATA%\port-sync folder and deletes it at the end: don't run it on a machine
# where port-sync is installed.

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
        $script:source    = Join-Path $root 'port-sync.ps1'
        $script:dir       = Join-Path $env:LOCALAPPDATA 'port-sync'
        $script:legacyDir = Join-Path $env:LOCALAPPDATA 'proton-qbit-port-sync'

        # An unzipped offline download: install.ps1 with a port-sync.ps1 next to it, marked so
        # the tests can tell it from the repo's copy and from a download
        $script:zipName      = 'port-sync-zip-' + [guid]::NewGuid().ToString('N')
        $script:zipDir       = Join-Path ([IO.Path]::GetTempPath()) $zipName
        $script:zipInstaller = Join-Path $zipDir 'install.ps1'
        New-Item -ItemType Directory -Path $zipDir | Out-Null
        Copy-Item -LiteralPath $installer -Destination $zipInstaller
        (Get-Content -LiteralPath $source -Raw) -replace "PortSyncVersion = '[^']+'", "PortSyncVersion = '0.0.0-zip'" |
            Set-Content -LiteralPath (Join-Path $zipDir 'port-sync.ps1') -NoNewline
    }

    AfterAll {
        if ($zipDir -and (Test-Path -LiteralPath $zipDir)) { Remove-Item -LiteralPath $zipDir -Recurse -Force }
    }

    It 'migrates a 1.x install: password file kept, old task replaced' {
        New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
        ConvertTo-SecureString 'legacy-pass' -AsPlainText -Force | ConvertFrom-SecureString |
            Set-Content -LiteralPath (Join-Path $legacyDir 'qbit-pass.txt')
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -Command exit'
        Register-ScheduledTask -TaskName 'Proton qBittorrent port sync' -Action $a | Out-Null

        & $installer -Source $source -NoPrompt

        Get-ScheduledTask -TaskName 'Proton qBittorrent port sync' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $pass = (Get-Content -LiteralPath (Join-Path $dir 'qbit-pass.txt') -Raw).Trim() | ConvertTo-SecureString
        (New-Object Net.NetworkCredential('', $pass)).Password | Should -Be 'legacy-pass'
    }

    It 'registers a sign-in task for this account, not elevated' {
        $t = Get-ScheduledTask -TaskName 'port-sync'
        $t.Principal.RunLevel   | Should -Be 'Limited'
        $t.Principal.UserId     | Should -Match ([regex]::Escape($env:USERNAME))
        $t.Triggers[0].CimClass.CimClassName | Should -Be 'MSFT_TaskLogonTrigger'
        $t.Actions[0].Execute   | Should -Be 'powershell.exe'
        $t.Actions[0].Arguments | Should -Match ([regex]::Escape("$dir\port-sync.ps1"))
        $t.Settings.MultipleInstances | Should -Be 'IgnoreNew'
    }

    It 'installs the script next to the password file' {
        Test-Path -LiteralPath (Join-Path $dir 'port-sync.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'port-sync.ps1.download') | Should -BeFalse
    }

    It 'keeps the password on a re-run' {
        $before = Get-Content -LiteralPath (Join-Path $dir 'qbit-pass.txt') -Raw
        & $installer -Source $source -NoPrompt
        Get-Content -LiteralPath (Join-Path $dir 'qbit-pass.txt') -Raw | Should -Be $before
    }

    It 'refuses a file that is not port-sync.ps1 and changes nothing' {
        $bogus = Join-Path ([IO.Path]::GetTempPath()) 'not-port-sync.ps1'
        Set-Content -LiteralPath $bogus -Value 'Write-Host hi'
        $before = Get-FileHash (Join-Path $dir 'port-sync.ps1')
        & $installer -Source $bogus -NoPrompt
        (Get-FileHash (Join-Path $dir 'port-sync.ps1')).Hash | Should -Be $before.Hash
    }

    It 'run as a file with no -Source, installs the port-sync.ps1 next to it' {
        $out = (& $zipInstaller -NoPrompt 6>&1 | ForEach-Object { "$_" }) -join "`n"   # Out-String would wrap long lines in 5.1
        # by folder name: the temp path can come back in its short (8.3) form
        $out | Should -Match "installing .*$zipName\\port-sync\.ps1"
        (Get-FileHash (Join-Path $dir 'port-sync.ps1')).Hash | Should -Be (Get-FileHash (Join-Path $zipDir 'port-sync.ps1')).Hash
        $out | Should -Match "uninstall: powershell -NoProfile -ExecutionPolicy Bypass -File `".*$zipName\\install\.ps1`" -Uninstall"
    }

    It 'under irm | iex, still downloads, even from a script in a folder with a port-sync.ps1' {
        # iex runs install.ps1 in the wrapper's scope, so these stand-ins replace the download and the Enter prompt
        $wrapper = Join-Path $zipDir 'iex-wrapper.ps1'
        Set-Content -LiteralPath $wrapper -Value @(
            'function Invoke-WebRequest { param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing) Set-Content -LiteralPath $OutFile -Value "`$script:PortSyncVersion = ''0.0.0-download''" }'
            'function Read-Host { param([string]$Prompt) }'
            "Get-Content -LiteralPath '$installer' -Raw | Invoke-Expression"
        )
        & $wrapper 6>&1 | Out-Null
        Get-Content -LiteralPath (Join-Path $dir 'port-sync.ps1') -Raw | Should -Match "PortSyncVersion = '0.0.0-download'"
    }

    It 'uninstalls, run from that folder too: task and both folders gone' {
        & $zipInstaller -Uninstall
        Get-ScheduledTask -TaskName 'port-sync' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path -LiteralPath $dir       | Should -BeFalse
        Test-Path -LiteralPath $legacyDir | Should -BeFalse
    }
}
