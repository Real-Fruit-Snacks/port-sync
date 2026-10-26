# install.ps1 - sets up port-sync for the current Windows account.
#
#   irm rfs.sh/port-sync | iex                                        install or update
#   & ([scriptblock]::Create((irm rfs.sh/port-sync))) -Uninstall      remove everything
#   .\install.ps1 -Source .\port-sync.ps1                             install from a local copy
#
# Run it in a normal (not admin) PowerShell window as the account you torrent with.
# One UAC prompt appears for the scheduled task. Safe to re-run: an existing password
# file is kept, the script is replaced, the task is re-registered.
# ASCII only and no 'exit': under 'irm | iex' an exit would close your PowerShell window.
param(
    [switch]$Uninstall,
    [string]$Source,     # local port-sync.ps1 to install instead of downloading
    [switch]$NoPrompt    # don't wait for Enter before the test run
)

function Install-RfsPortSync {
    param([switch]$Uninstall, [string]$Source, [switch]$NoPrompt)

    $ErrorActionPreference = 'Stop'
    $raw        = 'https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/port-sync.ps1'
    $taskName   = 'port-sync'
    $legacyTask = 'Proton qBittorrent port sync'
    if ($env:OS -ne 'Windows_NT') { Write-Host 'port-sync runs on Windows only.'; return }
    $dir       = Join-Path $env:LOCALAPPDATA 'port-sync'
    $legacyDir = Join-Path $env:LOCALAPPDATA 'proton-qbit-port-sync'
    $target    = Join-Path $dir 'port-sync.ps1'
    $passFile  = Join-Path $dir 'qbit-pass.txt'
    $user      = "$env:USERDOMAIN\$env:USERNAME"
    $qUser     = $user -replace "'", "''"     # for embedding in single-quoted strings below

    function Say([string]$m) { Write-Host "[port-sync] $m" }

    # Runs a block of task-scheduler commands elevated (one UAC prompt). Returns $true on success.
    function Invoke-Elevated([string]$Body) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            try { & ([scriptblock]::Create($Body)); return $true } catch { Say "$_"; return $false }
        }
        $wrapped = "`$ErrorActionPreference = 'Stop'; try { $Body; exit 0 } catch { Write-Host `$_; Start-Sleep 8; exit 1 }"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))
        try {
            $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
                    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
            return ($p.ExitCode -eq 0)
        } catch {
            Say 'The UAC prompt was declined or failed.'
            return $false
        }
    }

    # Task Scheduler wants admin rights to create a sign-in trigger, even for your own account.
    $removeTasks = @"
foreach (`$n in '$taskName', '$legacyTask') {
    if (Get-ScheduledTask -TaskName `$n -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName `$n -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName `$n -Confirm:`$false
    }
}
"@

    if ($Uninstall) {
        if (-not (Invoke-Elevated $removeTasks)) { Say "Couldn't remove the scheduled task. In an admin PowerShell: Unregister-ScheduledTask $taskName -Confirm:`$false"; return }
        Start-Sleep -Seconds 2   # let the stopped script release sync.log
        foreach ($d in $dir, $legacyDir) {
            if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force; Say "removed $d" }
        }
        Say 'Uninstalled. qBittorrent keeps the last port it was given; its Web UI settings are unchanged.'
        return
    }

    # 1. Folder and script
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $tmp = "$target.download"
    if ($Source) {
        Copy-Item -LiteralPath $Source -Destination $tmp -Force
    } else {
        # Windows PowerShell 5.1 on older builds still defaults to TLS 1.0; GitHub needs 1.2.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $raw -OutFile $tmp -UseBasicParsing
    }
    if (-not (Select-String -LiteralPath $tmp -SimpleMatch 'PortSyncVersion' -Quiet)) {
        Remove-Item -LiteralPath $tmp -Force
        Say "The downloaded file isn't port-sync.ps1. Nothing changed."; return
    }
    Move-Item -LiteralPath $tmp -Destination $target -Force
    $ver = (Select-String -LiteralPath $target -Pattern "PortSyncVersion = '([^']+)'").Matches[0].Groups[1].Value
    Say "installed port-sync $ver to $target"

    # 2. Web UI password, encrypted to this Windows account (DPAPI)
    $legacyPass = Join-Path $legacyDir 'qbit-pass.txt'
    if (-not (Test-Path -LiteralPath $passFile) -and (Test-Path -LiteralPath $legacyPass)) {
        Copy-Item -LiteralPath $legacyPass -Destination $passFile
        Say "copied the password file from $legacyDir"
    }
    $newPassword = $null
    if (Test-Path -LiteralPath $passFile) {
        try {
            (Get-Content -LiteralPath $passFile -Raw).Trim() | ConvertTo-SecureString | Out-Null
            Say 'keeping the existing Web UI password file'
        } catch {
            Move-Item -LiteralPath $passFile -Destination "$passFile.unreadable" -Force
            Say 'the existing password file belongs to another account; making a new one'
        }
    }
    if (-not (Test-Path -LiteralPath $passFile)) {
        $bytes = New-Object byte[] 12
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $newPassword = -join ($bytes | ForEach-Object { $_.ToString('x2') })
        ConvertTo-SecureString $newPassword -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $passFile
        try { $newPassword | Set-Clipboard } catch { }
        Write-Host ''
        Write-Host "  Web UI password (copied to the clipboard): $newPassword"
        Write-Host ''
        Write-Host '  In qBittorrent: Tools > Options > Web UI'
        Write-Host '    - tick Web User Interface (Remote control)'
        Write-Host '    - IP address 127.0.0.1, port 8080'
        Write-Host '    - username admin, password = the one above'
        Write-Host '    - leave "Bypass authentication for clients on localhost" unticked'
        Write-Host ''
    }

    # 3. One test run, before the task starts, so a wrong password doesn't trigger qBittorrent's ban
    $ok = $false
    if (-not $NoPrompt) {
        [void](Read-Host 'Press Enter when qBittorrent is open with the Web UI on and Proton VPN is connected with port forwarding')
        $ps = (Get-Process -Id $PID).Path
        & $ps -NoProfile -ExecutionPolicy Bypass -File $target -Once
        $ok = ($LASTEXITCODE -eq 0)
        if ($ok) { Say 'test run: qBittorrent has the forwarded port' }
        else     { Say 'test run did not sync; the lines above say why. The task will keep trying.' }
    }

    $qTarget = $target -replace "'", "''"

    # 4. Scheduled task at sign-in, as this account, not elevated
    $register = $removeTasks + @"

`$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$qTarget"'
`$trigger   = New-ScheduledTaskTrigger -AtLogOn -User '$qUser'
`$principal = New-ScheduledTaskPrincipal -UserId '$qUser' -LogonType Interactive -RunLevel Limited
`$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName '$taskName' -Action `$action -Trigger `$trigger -Principal `$principal -Settings `$settings -Description 'Keeps qBittorrent''s port synced to Proton VPN' | Out-Null
Start-ScheduledTask -TaskName '$taskName'
"@
    if (Invoke-Elevated $register) {
        Say "scheduled task '$taskName' registered for $user and started"
    } else {
        Say "Task not registered. Re-run the installer and accept the UAC prompt, or run it from an admin PowerShell as $user."
        return
    }

    Write-Host ''
    Say "log:       Get-Content `"$dir\sync.log`" -Wait -Tail 20"
    Say "restart:   Stop-ScheduledTask $taskName; Start-ScheduledTask $taskName"
    Say 'uninstall: & ([scriptblock]::Create((irm rfs.sh/port-sync))) -Uninstall'
    if ($newPassword -and -not $ok -and $NoPrompt) { Say 'Set the Web UI password above in qBittorrent, then restart the task.' }
}

Install-RfsPortSync -Uninstall:$Uninstall -Source $Source -NoPrompt:$NoPrompt
