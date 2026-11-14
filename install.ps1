# install.ps1 - sets up port-sync for the current Windows account.
#
#   irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1 | iex
#       install or update
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1))) -Uninstall
#       remove everything
#   .\install.ps1 -Source .\port-sync.exe                              install from a local copy
#   powershell -ExecutionPolicy Bypass -File .\install.ps1              in the offline zip's folder:
#       installs the port-sync.exe next to it; add -Uninstall to remove
#
# Run it in a normal (not admin) PowerShell window as the account you torrent with. It needs no
# admin rights: port-sync starts at sign-in from your own Run key. Upgrading from 2.x, one UAC
# prompt removes the old scheduled task. Safe to re-run: an existing password file is kept and
# the program is replaced.
# ASCII only and no 'exit': under 'irm | iex' an exit would close your PowerShell window.
param(
    [switch]$Uninstall,
    [string]$Source,     # local port-sync.exe to install instead of downloading; run as a file,
                         # the one next to install.ps1 if there is one
    [switch]$NoPrompt,   # don't wait for Enter before the test run (and skip it)
    [switch]$NoStart     # don't start the tray app at the end
)

function Install-RfsPortSync {
    param([switch]$Uninstall, [string]$Source, [switch]$NoPrompt, [switch]$NoStart)

    $ErrorActionPreference = 'Stop'
    $release    = 'https://github.com/Real-Fruit-Snacks/port-sync/releases/latest/download'
    $taskName   = 'port-sync'
    $legacyTask = 'Proton qBittorrent port sync'
    if ($env:OS -ne 'Windows_NT') { Write-Host 'port-sync runs on Windows only.'; return }
    $dir       = Join-Path $env:LOCALAPPDATA 'port-sync'
    $legacyDir = Join-Path $env:LOCALAPPDATA 'proton-qbit-port-sync'
    $target    = Join-Path $dir 'port-sync.exe'
    $oldScript = Join-Path $dir 'port-sync.ps1'
    $passFile  = Join-Path $dir 'qbit-pass.txt'
    $runKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runValue  = 'port-sync'
    $shortcut  = Join-Path ([Environment]::GetFolderPath('Programs')) 'port-sync.lnk'   # Start menu

    function Say([string]$m) { Write-Host "[port-sync] $m" }

    # Run as a file (from the offline zip, or a clone), this function knows its file; under
    # 'irm | iex' it has none, so that path downloads.
    $self = $PSCommandPath
    $uninstallLine = '& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Real-Fruit-Snacks/port-sync/main/install.ps1))) -Uninstall'
    if ($self) { $uninstallLine = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Uninstall" }

    # port-sync.exe is a Windows (not console) program, so the sign-in start shows no window.
    # Piping its output makes PowerShell wait for it and set $LASTEXITCODE.
    function Invoke-PortSync([string]$Exe, [string[]]$Arguments) {
        & $Exe @Arguments | ForEach-Object { Write-Host "  $_" }
        return $LASTEXITCODE
    }

    function Exit-RunningTray {
        if (Test-Path -LiteralPath $target) { & $target --quit | Out-Null }
        # One that didn't answer, or one started from another copy of the exe in this folder
        Get-Process -Name 'port-sync' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $target } | ForEach-Object {
            $_ | Stop-Process -Force
            $_.WaitForExit(5000) | Out-Null
        }
    }

    # Runs a block elevated (one UAC prompt). Returns $true on success.
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

    # 2.x and 1.x ran from a scheduled task. Task Scheduler wants admin rights to remove one, so
    # that is the only step with a UAC prompt, and only when one of them is there.
    $oldTasks = @($taskName, $legacyTask | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue })
    $removeTasks = @"
foreach (`$n in '$taskName', '$legacyTask') {
    if (Get-ScheduledTask -TaskName `$n -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName `$n -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName `$n -Confirm:`$false
    }
}
"@

    # Settings changed in 1.x or 2.x: parameters added to the task's arguments (how the 2.x
    # README said to change one), or defaults edited in the script itself. They become
    # config.json, which the program reads. Read now, before the task is removed.
    function Get-OldSetting {
        $keys = [ordered]@{ QbitUrl = 'qbitUrl'; QbitUser = 'qbitUser'; ProtonLogs = 'protonLogs'; Adapter = 'adapter'; IntervalSec = 'intervalSec'; RecheckSec = 'recheckSec' }
        $defaults = @{ qbitUrl = 'http://127.0.0.1:8080'; qbitUser = 'admin'; adapter = 'ProtonVPN'; intervalSec = 15; recheckSec = 60 }
        $found = [ordered]@{}
        foreach ($f in (Join-Path $legacyDir 'proton-qbit-port-sync.ps1'), $oldScript) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $text = Get-Content -LiteralPath $f -Raw
            foreach ($k in $keys.Keys) {
                if ($text -match ('\[string\]\$' + $k + "\s*=\s*'([^']*)'")) { $found[$keys[$k]] = $Matches[1] }
                elseif ($text -match ('\[int\]\$' + $k + '\s*=\s*(\d+)')) { $found[$keys[$k]] = [int]$Matches[1] }
            }
        }
        foreach ($n in $oldTasks) {
            $a = (@((Get-ScheduledTask -TaskName $n).Actions) | ForEach-Object { $_.Arguments }) -join ' '
            foreach ($k in $keys.Keys) {
                if ($a -match ('-' + $k + "\s+(?:'([^']*)'|`"([^`"]*)`"|([^\s'`"]+))")) {
                    $v = @($Matches[1], $Matches[2], $Matches[3]) | Where-Object { $null -ne $_ } | Select-Object -First 1
                    if ($k -like '*Sec') { $v = [int]$v }
                    $found[$keys[$k]] = $v
                }
            }
        }
        $changed = [ordered]@{}
        foreach ($k in $found.Keys) { if ($found[$k] -ne $defaults[$k]) { $changed[$k] = $found[$k] } }
        return $changed
    }
    $oldSettings = Get-OldSetting

    if ($Uninstall) {
        Exit-RunningTray
        Remove-ItemProperty -Path $runKey -Name $runValue -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
        if ($oldTasks) {
            if (-not (Invoke-Elevated $removeTasks)) { Say "Couldn't remove the old scheduled task. In an admin PowerShell: Unregister-ScheduledTask $taskName -Confirm:`$false"; return }
            Start-Sleep -Seconds 2   # let the stopped 2.x script release sync.log
        }
        foreach ($d in $dir, $legacyDir) {
            if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force; Say "removed $d" }
        }
        Say 'Uninstalled. qBittorrent keeps the last port it was given; its Web UI settings are unchanged.'
        return
    }

    # 1. The program, checked before anything else changes
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $tmp = Join-Path $dir 'port-sync.new.exe'   # .exe, so the check below runs it rather than opening it
    if (-not $Source -and $self) {
        $beside = Join-Path (Split-Path -Parent $self) 'port-sync.exe'
        if (Test-Path -LiteralPath $beside) { $Source = $beside; Say "installing $beside" }
    }
    if ($Source) {
        Copy-Item -LiteralPath $Source -Destination $tmp -Force
        try { Unblock-File -LiteralPath $tmp } catch { }   # a file from a downloaded zip keeps the internet mark
    } else {
        # Windows PowerShell 5.1 on older builds still defaults to TLS 1.0; GitHub needs 1.2.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $sums = Join-Path $dir 'SHA256SUMS.txt.download'
        Invoke-WebRequest -Uri "$release/port-sync.exe" -OutFile $tmp -UseBasicParsing
        Invoke-WebRequest -Uri "$release/SHA256SUMS.txt" -OutFile $sums -UseBasicParsing
        $line = @(Get-Content -LiteralPath $sums | Where-Object { $_ -match '^([0-9a-fA-F]{64})\s+\*?port-sync\.exe\s*$' })
        Remove-Item -LiteralPath $sums -Force
        $want = if ($line) { ($line[0] -split '\s+')[0].ToLower() } else { '' }
        $have = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
        if (-not $want -or $want -ne $have) {
            Remove-Item -LiteralPath $tmp -Force
            Say "The download doesn't match the release's SHA256SUMS.txt. Nothing changed."; return
        }
    }
    $ver = ''
    try { $ver = (@(& $tmp --version | ForEach-Object { "$_" }) -join ' ').Trim() } catch { }
    if ($ver -notmatch '^port-sync (\S+)$') {
        Remove-Item -LiteralPath $tmp -Force
        Say "That file isn't port-sync.exe. Nothing changed."; return
    }
    $newVersion = $Matches[1]

    # 2. Stop what runs now: this version's tray, and 2.x's scheduled task
    if ($oldTasks) {
        Say "removing the old scheduled task ($($oldTasks -join ', ')); Windows asks for admin rights for that"
        if (-not (Invoke-Elevated $removeTasks)) {
            Remove-Item -LiteralPath $tmp -Force
            Say "The old task is still there, so nothing changed. Re-run the installer and accept the UAC prompt."; return
        }
        Start-Sleep -Seconds 2   # let the stopped script release sync.log
    }
    Exit-RunningTray
    Move-Item -LiteralPath $tmp -Destination $target -Force
    Say "installed port-sync $newVersion to $target"
    $config = Join-Path $dir 'config.json'
    if ($oldSettings.Count -and -not (Test-Path -LiteralPath $config)) {
        [IO.File]::WriteAllText($config, ($oldSettings | ConvertTo-Json) + "`r`n", (New-Object Text.UTF8Encoding $false))
        Say "kept the settings you changed: $(($oldSettings.Keys | ForEach-Object { "$_ = $($oldSettings[$_])" }) -join ', ') (in $config)"
    }
    if (Test-Path -LiteralPath $oldScript) { Remove-Item -LiteralPath $oldScript -Force; Say 'removed the 2.x port-sync.ps1' }

    # 3. Web UI password, encrypted to this Windows account (DPAPI)
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

    # 4. One test run, before the tray starts, so a wrong password doesn't trigger qBittorrent's ban
    $ok = $false
    if (-not $NoPrompt) {
        [void](Read-Host 'Press Enter when qBittorrent is open with the Web UI on and Proton VPN is connected with port forwarding')
        $ok = ((Invoke-PortSync $target @('--once')) -eq 0)
        if ($ok) { Say 'test run: qBittorrent has the forwarded port' }
        else     { Say 'test run did not sync; the lines above say why. The tray app will keep trying.' }
    }

    # 5. Start at sign-in, from this account's Run key (no admin rights), and start now
    if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey | Out-Null }
    Set-ItemProperty -Path $runKey -Name $runValue -Value "`"$target`" --autostart"
    Say 'starts at sign-in (untick Start at sign-in in its menu to stop that)'
    # A Start menu entry, to start it again after Quit
    try {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
        $sc.TargetPath = $target
        $sc.WorkingDirectory = $dir
        $sc.Description = 'Keeps qBittorrent''s port synced to Proton VPN'
        $sc.Save()
    } catch { Say "couldn't add the Start menu entry: $($_.Exception.Message)" }
    if (-not $NoStart) {
        Start-Process -FilePath $target
        Say 'running: its icon is in the notification area, by the clock (it may be under the ^ arrow);'
        Say 'after Quit, start it again from the Start menu (port-sync)'
    }

    Write-Host ''
    Say "log:       Get-Content `"$dir\sync.log`" -Wait -Tail 20"
    Say "one sync:  & `"$target`" --once | Write-Output"
    Say "uninstall: $uninstallLine"
    if ($newPassword -and -not $ok -and $NoPrompt) { Say 'Set the Web UI password above in qBittorrent; the tray app picks it up within 15 s.' }
}

Install-RfsPortSync -Uninstall:$Uninstall -Source $Source -NoPrompt:$NoPrompt -NoStart:$NoStart
