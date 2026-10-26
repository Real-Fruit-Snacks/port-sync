# Pester 5. Run from the repo root:
#   Invoke-Pester ./tests
# The 'Qbit' tests need a real qBittorrent Web UI and are skipped without one:
#   $env:PORT_SYNC_TEST_QBIT_URL  = 'http://127.0.0.1:8080'
#   $env:PORT_SYNC_TEST_QBIT_PASS = '<Web UI password for admin>'
# They change that qBittorrent's listening port, so don't point them at the one you use.

BeforeAll {
    $script:Root   = Split-Path -Parent $PSScriptRoot
    $script:Sync   = Join-Path $Root 'port-sync.ps1'
    $script:Work   = Join-Path ([IO.Path]::GetTempPath()) ("port-sync-tests-" + [guid]::NewGuid().ToString('N'))
    $script:Logs   = Join-Path $Work 'logs'
    $script:State  = Join-Path $Work 'state'
    New-Item -ItemType Directory -Path $Logs, $State -Force | Out-Null
    $script:QbitUrl = if ($env:PORT_SYNC_TEST_QBIT_URL) { $env:PORT_SYNC_TEST_QBIT_URL } else { 'http://127.0.0.1:1' }

    . $Sync -ProtonLogs $Logs -StateDir $State -Adapter '' -QbitUrl $QbitUrl -RecheckSec 60

    function Write-ProtonLog([string[]]$Lines, [string]$Name = 'client-logs.txt') {
        Set-Content -LiteralPath (Join-Path $Logs $Name) -Value $Lines
    }
    function Write-PasswordFile([string]$Plain) {
        ConvertTo-SecureString $Plain -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $PassFile
    }
    function Clear-SyncState {
        $script:LastPort = $null; $script:LastCheck = [datetime]::MinValue
        $script:AuthFailedFor = $null; $script:AuthFailedAt = [datetime]::MinValue; $script:LastNote = ''
    }
    function Get-QbitPreference {
        $s = $null
        Invoke-WebRequest -Uri "$QbitUrl/api/v2/auth/login" -Method Post -UseBasicParsing -SessionVariable s `
            -Body @{ username = 'admin'; password = $env:PORT_SYNC_TEST_QBIT_PASS } | Out-Null
        $p = Invoke-RestMethod -Uri "$QbitUrl/api/v2/app/preferences" -WebSession $s
        return @{ Prefs = $p; Session = $s }
    }
    function Write-QbitPort([int]$Port) {
        $c = Get-QbitPreference
        Invoke-RestMethod -Uri "$QbitUrl/api/v2/app/setPreferences" -Method Post -WebSession $c.Session `
            -Body @{ json = ('{{"listen_port":{0}}}' -f $Port) } | Out-Null
    }
}

AfterAll {
    if ($Work -and (Test-Path -LiteralPath $Work)) { Remove-Item -LiteralPath $Work -Recurse -Force }
}

Describe 'Get-ProtonPort' {
    BeforeEach { Get-ChildItem -LiteralPath $Logs | Remove-Item -Force }

    It 'returns $null when the log folder has no logs' {
        Get-ProtonPort | Should -BeNullOrEmpty
    }

    It 'takes the newest port pair' {
        Write-ProtonLog @('a Port pair 40000->40000', 'b noise', 'c Port pair 40001->40002')
        Get-ProtonPort | Should -Be 40002
    }

    It 'reads the rotated file first, so the current file wins' {
        Write-ProtonLog @('Port pair 41000->41000') -Name 'client-logs.1.txt'
        Write-ProtonLog @('Port pair 42000->42000')
        Get-ProtonPort | Should -Be 42000
    }

    It 'falls back to the rotated file when the current one has no pair yet' {
        Write-ProtonLog @('Port pair 41000->41000') -Name 'client-logs.1.txt'
        Write-ProtonLog @('Status updated to Connecting')
        Get-ProtonPort | Should -Be 41000
    }

    It 'forgets the port after a disconnect' {
        Write-ProtonLog @('Port pair 43000->43000', 'Status updated to Disconnected')
        Get-ProtonPort | Should -BeNullOrEmpty
    }

    It 'forgets the port when port forwarding stops' {
        Write-ProtonLog @('Port pair 43000->43000', "Port forwarding status changed from 'Running' to 'Stopped'")
        Get-ProtonPort | Should -BeNullOrEmpty
    }

    It 'picks up the new port after a reconnect' {
        Write-ProtonLog @('Port pair 43000->43000', 'Status updated to Disconnected', 'Port pair 44000->44000')
        Get-ProtonPort | Should -Be 44000
    }

    It 'rejects a port outside 1-65535' {
        Write-ProtonLog @('Port pair 1->70000')
        Get-ProtonPort | Should -BeNullOrEmpty
    }

    It 'finds the pair at the end of a log larger than the 256 KB tail' {
        $filler = 'x' * 1000
        Write-ProtonLog ((1..400 | ForEach-Object { $filler }) + 'Port pair 45000->45000')
        (Get-Item (Join-Path $Logs 'client-logs.txt')).Length | Should -BeGreaterThan 262144
        Get-ProtonPort | Should -Be 45000
    }

    It 'reads the log while another process holds it open for writing' {
        $path = Join-Path $Logs 'client-logs.txt'
        $fs = [IO.File]::Open($path, 'Create', 'Write', 'ReadWrite, Delete')
        try {
            $w = New-Object IO.StreamWriter($fs)
            $w.WriteLine('Port pair 46000->46000'); $w.Flush()
            Get-ProtonPort | Should -Be 46000
        } finally { $fs.Dispose() }
    }
}

Describe 'Write-SyncLog' {
    It 'rotates sync.log past 1 MB' {
        Set-Content -LiteralPath $SyncLog -Value ('y' * 1100000)
        Write-SyncLog 'after rotation'
        Test-Path -LiteralPath "$SyncLog.1" | Should -BeTrue
        (Get-Content -LiteralPath $SyncLog) | Should -HaveCount 1
        (Get-Content -LiteralPath $SyncLog) | Should -Match '\[port-sync\] after rotation$'
    }
}

Describe 'Get-QbitPassword' {
    AfterEach { Remove-Item -LiteralPath $PassFile -Force -ErrorAction SilentlyContinue }

    It 'says the file is missing' {
        { Get-QbitPassword } | Should -Throw '*password file missing*'
    }

    It 'says the file cannot be decrypted, instead of blaming qBittorrent' {
        Set-Content -LiteralPath $PassFile -Value 'not-a-dpapi-blob'
        { Get-QbitPassword } | Should -Throw "*can't decrypt*"
    }

    It 'round-trips a password' {
        Write-PasswordFile 'p4ss'
        Get-QbitPassword | Should -Be 'p4ss'
    }
}

Describe 'Sync-Port without a reachable qBittorrent' {
    BeforeEach { Clear-SyncState; Write-ProtonLog @('Port pair 47000->47000') }
    AfterEach  { Remove-Item -LiteralPath $PassFile -Force -ErrorAction SilentlyContinue }

    It 'reports a bad password file as such' {
        Set-Content -LiteralPath $PassFile -Value 'garbage'
        Sync-Port | Should -BeFalse
        $script:LastNote | Should -Match "can't decrypt"
    }

    It 'returns $false while the Proton log has no port' {
        Write-ProtonLog @('Status updated to Disconnected')
        Sync-Port | Should -BeFalse
        $script:LastNote | Should -Match 'no forwarded port'
    }

    It 'returns $false when nothing listens at QbitUrl' -Skip:([bool]$env:PORT_SYNC_TEST_QBIT_URL) {
        Write-PasswordFile 'whatever'
        Sync-Port | Should -BeFalse
        $script:LastNote | Should -Match 'not reachable'
    }
}

Describe '-Once exit codes' {
    It 'exits 1 when there is nothing to sync' {
        Write-ProtonLog @('Status updated to Disconnected')
        $ps = (Get-Process -Id $PID).Path
        & $ps -NoProfile -File $Sync -ProtonLogs $Logs -StateDir $State -Adapter '' -QbitUrl 'http://127.0.0.1:1' -Once | Out-Null
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'Sync-Port against qBittorrent' -Tag 'Qbit' -Skip:(-not $env:PORT_SYNC_TEST_QBIT_URL) {
    BeforeEach {
        Clear-SyncState
        Write-PasswordFile $env:PORT_SYNC_TEST_QBIT_PASS
        Write-QbitPort 6881
    }

    It 'sets the listening port and turns off random port and UPnP' {
        Write-ProtonLog @('Port pair 48000->48001')
        Sync-Port | Should -BeTrue
        $p = (Get-QbitPreference).Prefs
        $p.listen_port | Should -Be 48001
        $p.random_port | Should -BeFalse
        $p.upnp        | Should -BeFalse
        (Get-Content -LiteralPath $SyncLog -Tail 1) | Should -Match 'listening port updated: 6881 -> 48001'
    }

    It 'leaves a correct port alone' {
        Write-QbitPort 48100
        Write-ProtonLog @('Port pair 48100->48100')
        Sync-Port | Should -BeTrue
        (Get-Content -LiteralPath $SyncLog -Tail 1) | Should -Match 'already correct: 48100'
    }

    It 'puts the port back after someone changes it in qBittorrent, at the next recheck' {
        Write-ProtonLog @('Port pair 48200->48200')
        Sync-Port | Should -BeTrue
        Write-QbitPort 6999
        Sync-Port | Should -BeTrue                       # within RecheckSec: no API call
        (Get-QbitPreference).Prefs.listen_port | Should -Be 6999
        $script:LastCheck = (Get-Date).AddSeconds(-61)   # recheck due
        Sync-Port | Should -BeTrue
        (Get-QbitPreference).Prefs.listen_port | Should -Be 48200
    }

    It 'follows a new port immediately, without waiting for the recheck' {
        Write-ProtonLog @('Port pair 48300->48300')
        Sync-Port | Should -BeTrue
        Write-ProtonLog @('Port pair 48300->48300', 'Status updated to Disconnected', 'Port pair 48301->48301')
        Sync-Port | Should -BeTrue
        (Get-QbitPreference).Prefs.listen_port | Should -Be 48301
    }

    It 'stops trying after a rejected login until the password file changes' {
        Write-ProtonLog @('Port pair 48400->48400')
        Write-PasswordFile 'definitely-wrong'
        Sync-Port | Should -BeFalse
        (Get-Content -LiteralPath $SyncLog -Tail 1) | Should -Match 'login rejected'
        $before = (Get-Content -LiteralPath $SyncLog).Count
        $script:LastCheck = [datetime]::MinValue
        Sync-Port | Should -BeFalse                      # same file: no second login attempt
        (Get-Content -LiteralPath $SyncLog).Count | Should -Be $before

        Start-Sleep -Milliseconds 50
        Write-PasswordFile $env:PORT_SYNC_TEST_QBIT_PASS       # new file: tries again
        Sync-Port | Should -BeTrue
        (Get-QbitPreference).Prefs.listen_port | Should -Be 48400
    }

    It 'tries again 30 minutes after a rejected login even if the file is unchanged' {
        Write-ProtonLog @('Port pair 48500->48500')
        Write-PasswordFile 'definitely-wrong'
        Sync-Port | Should -BeFalse
        $script:AuthFailedAt = (Get-Date).AddSeconds(-1801)
        $before = (Get-Content -LiteralPath $SyncLog).Count
        Sync-Port | Should -BeFalse
        (Get-Content -LiteralPath $SyncLog).Count | Should -Be ($before + 1)
    }

    It 'exits 0 from -Once when in sync' {
        Write-ProtonLog @('Port pair 48600->48600')
        $ps = (Get-Process -Id $PID).Path
        & $ps -NoProfile -File $Sync -ProtonLogs $Logs -StateDir $State -Adapter '' -QbitUrl $QbitUrl -Once | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-QbitPreference).Prefs.listen_port | Should -Be 48600
    }
}
