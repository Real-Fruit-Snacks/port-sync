# release-notes.ps1 - the GitHub release notes for a version, from its CHANGELOG.md section, in
# the shape earlier releases used: the summary paragraph, then every entry as one list, with the
# ### headings and the closing full stops dropped.
#   ./tools/release-notes.ps1 -Version 2.1.0 [-Out notes.md]
# Fails if CHANGELOG.md has no '## [<version>] - <date>' section or port-sync.ps1 is another
# version, so a tag can't publish without its changelog entry.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$sync = Get-Content -LiteralPath (Join-Path $root 'port-sync.ps1') -Raw
if ($sync -notmatch "PortSyncVersion = '([^']+)'") { throw 'no PortSyncVersion in port-sync.ps1' }
if ($Matches[1] -ne $Version) { throw "port-sync.ps1 is $($Matches[1]), not $Version" }

$lines = @(Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Encoding UTF8)
$head  = '^## \[' + [regex]::Escape($Version) + '\] - \d{4}-\d{2}-\d{2}\s*$'
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $head) { $start = $i; break } }
if ($start -lt 0) { throw "CHANGELOG.md has no '## [$Version] - <date>' section" }
$end = $lines.Count
for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^## \[|^\[[^\]]+\]: ') { $end = $i; break } }

$kept = @($lines[($start + 1)..($end - 1)] | Where-Object { $_ -notmatch '^### ' } | ForEach-Object {
    if ($_ -match '^- ') { $_.TrimEnd() -replace '\.$', '' } else { $_.TrimEnd() }
})
# One list: drop the blank lines left between the groups, then collapse the rest
$notes = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $kept.Count; $i++) {
    if ($kept[$i] -eq '') {
        $prev = if ($notes.Count) { $notes[$notes.Count - 1] } else { '' }
        $next = ''
        for ($j = $i + 1; $j -lt $kept.Count; $j++) { if ($kept[$j] -ne '') { $next = $kept[$j]; break } }
        if ($prev -eq '' -or ($prev -match '^- ' -and $next -match '^- ')) { continue }
    }
    $notes.Add($kept[$i])
}
$text = ($notes -join "`n").Trim()
if (-not $text) { throw "CHANGELOG.md's $Version section is empty" }

if ($Out) { [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out), "$text`n") }
else { $text }
