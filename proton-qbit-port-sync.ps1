# proton-qbit-port-sync.ps1
# Keeps qBittorrent's listening port equal to the port Proton VPN forwards (Windows).
# Works with Windows PowerShell 5.1 (built in) and PowerShell 7.
#
# Where the port comes from: the Proton VPN app writes a line like
#   "... Port pair 54692->54692 ..." to its client log every few seconds.
# Where it goes: qBittorrent's Web UI API (app/setPreferences).
param(
    [string]$QbitUrl     = 'http://127.0.0.1:8080',
    [string]$QbitUser    = 'admin',
    [string]$ProtonLogs  = (Join-Path $env:LOCALAPPDATA 'Proton\Proton VPN\Logs'),
    [string]$Adapter     = 'ProtonVPN',   # 'ProtonVPN TUN' for OpenVPN; '' skips the check
    [string]$StateDir    = (Join-Path $env:LOCALAPPDATA 'proton-qbit-port-sync'),
    [int]$IntervalSec    = 15,            # how often to look at the Proton log
    [int]$RecheckSec     = 60,            # how often to re-verify qBittorrent's port
    [switch]$Once                         # run one cycle and exit (for testing)
)

$ErrorActionPreference = 'Stop'
$PassFile = Join-Path $StateDir 'qbit-pass.txt'
$SyncLog  = Join-Path $StateDir 'sync.log'
$script:LastPort      = $null
$script:LastCheck     = [datetime]::MinValue
$script:AuthFailedFor = $null
$script:LastNote      = ''

function Write-Log([string]$Message) {
    $line = '{0} [port-sync] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        if ((Test-Path -LiteralPath $SyncLog) -and (Get-Item -LiteralPath $SyncLog).Length -gt 1MB) {
            Move-Item -LiteralPath $SyncLog -Destination "$SyncLog.1" -Force
        }
        Add-Content -LiteralPath $SyncLog -Value $line
    } catch { }
}

# Log a recurring condition only when it changes, so the log doesn't fill with repeats.
function Write-Note([string]$Message) {
    if ($Message -ne $script:LastNote) { Write-Log $Message; $script:LastNote = $Message }
}

function Read-LogTail([string]$Path, [int]$MaxBytes = 262144) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    # Shared open: Proton keeps writing to (and rotating) this file while we read it.
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        if ($fs.Length -gt $MaxBytes) { [void]$fs.Seek(-$MaxBytes, 'End') }
        $reader = New-Object IO.StreamReader($fs)
        return @($reader.ReadToEnd() -split "`r?`n")
    } finally { $fs.Dispose() }
}

function Test-VpnUp {
    if (-not $Adapter) { return $true }
    $a = Get-NetAdapter -Name $Adapter -ErrorAction SilentlyContinue
    return [bool]($a -and $a.Status -eq 'Up')
}

# Latest forwarded port, or $null if the VPN has disconnected since it was reported.
function Get-ProtonPort {
    $lines = @(Read-LogTail (Join-Path $ProtonLogs 'client-logs.1.txt')) +
             @(Read-LogTail (Join-Path $ProtonLogs 'client-logs.txt'))
    $port = $null
    foreach ($l in $lines) {
        if ($l -match 'Port pair \d+->(\d+)') { $port = [int]$Matches[1] }
        elseif ($l -match "Status updated to Disconnected|Port forwarding status changed from '[^']+' to 'Stopped'") { $port = $null }
    }
    if ($port -and ($port -lt 1 -or $port -gt 65535)) { return $null }
    return $port
}

function Get-QbitPassword {
    if (-not (Test-Path -LiteralPath $PassFile)) { throw "password file missing: $PassFile" }
    $secure = (Get-Content -LiteralPath $PassFile -Raw).Trim() | ConvertTo-SecureString
    return (New-Object Net.NetworkCredential('', $secure)).Password
}

# Returns a logged-in web session, $null if qBittorrent isn't reachable,
# or throws 'AUTH' if qBittorrent rejected the credentials.
function Connect-Qbit {
    $session = $null
    try {
        $r = Invoke-WebRequest -Uri "$QbitUrl/api/v2/auth/login" -Method Post -UseBasicParsing `
                -Body @{ username = $QbitUser; password = (Get-QbitPassword) } -SessionVariable session
    } catch {
        if ($_.Exception.Response) { throw 'AUTH' }   # got an HTTP error (401/403): bad login or banned
        if ("$_" -like 'password file missing*') { throw }
        return $null                                  # connection refused: qBittorrent not running
    }
    # qBittorrent 4.x answers 200 "Ok." / 200 "Fails."; newer 5.x answers an empty 204.
    if ("$($r.Content)" -match 'Fails') { throw 'AUTH' }
    return $session
}

function Sync-Port {
    if (-not (Test-VpnUp)) { Write-Note "VPN adapter '$Adapter' is not up - waiting"; return }
    $port = Get-ProtonPort
    if (-not $port) { Write-Note 'no forwarded port in the Proton VPN log yet - waiting'; return }

    $due = ((Get-Date) - $script:LastCheck).TotalSeconds -ge $RecheckSec
    if ($port -eq $script:LastPort -and -not $due) { return }

    # After a rejected login, don't retry until the password file changes
    # (qBittorrent bans an address after 5 failed logins).
    $stamp = $null
    if (Test-Path -LiteralPath $PassFile) { $stamp = (Get-Item -LiteralPath $PassFile).LastWriteTimeUtc }
    if ($script:AuthFailedFor -and $script:AuthFailedFor -eq $stamp) { return }

    try { $session = Connect-Qbit }
    catch {
        if ("$_" -eq 'AUTH') {
            $script:AuthFailedFor = $stamp
            Write-Log 'Web UI login rejected (wrong password, or address banned). Fix the password file, fully quit and reopen qBittorrent; not retrying until the file changes.'
            return
        }
        Write-Note "$_"; return
    }
    $script:AuthFailedFor = $null
    if (-not $session) { Write-Note 'qBittorrent Web UI not reachable (not running?) - will retry'; return }

    $current = (Invoke-RestMethod -Uri "$QbitUrl/api/v2/app/preferences" -WebSession $session).listen_port
    $script:LastCheck = Get-Date
    if ($current -eq $port) {
        if ($script:LastPort -ne $port) { Write-Log "listening port already correct: $port" }
        $script:LastPort = $port; $script:LastNote = ''
        return
    }

    $json = '{{"listen_port":{0},"random_port":false,"upnp":false}}' -f $port
    Invoke-RestMethod -Uri "$QbitUrl/api/v2/app/setPreferences" -Method Post -WebSession $session -Body @{ json = $json } | Out-Null
    $after = (Invoke-RestMethod -Uri "$QbitUrl/api/v2/app/preferences" -WebSession $session).listen_port
    if ($after -eq $port) {
        Write-Log "listening port updated: $current -> $port"
        $script:LastPort = $port; $script:LastNote = ''
    } else {
        Write-Log "failed to set port (qBittorrent still reports $after)"
    }
}

if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
Write-Log "watching $ProtonLogs"
while ($true) {
    try { Sync-Port } catch { Write-Note "error: $_" }
    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSec
}
