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
        $root      = Split-Path -Parent $PSScriptRoot
        $installer = Join-Path $root 'install.ps1'
        $source    = Join-Path $root 'port-sync.ps1'
        $dir       = Join-Path $env:LOCALAPPDATA 'port-sync'
        $legacyDir = Join-Path $env:LOCALAPPDATA 'proton-qbit-port-sync'
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

    It 'uninstalls: task and both folders gone' {
        & $installer -Uninstall
        Get-ScheduledTask -TaskName 'port-sync' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path -LiteralPath $dir       | Should -BeFalse
        Test-Path -LiteralPath $legacyDir | Should -BeFalse
    }
}
