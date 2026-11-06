# lint.ps1 - PSScriptAnalyzer with the repo's settings, and the ASCII check, the way CI runs them.
#   ./tools/lint.ps1
# Skips offline\ (the dev kit's bundled modules), dist\ (built downloads) and .venv\.
# In the dev kit PSScriptAnalyzer loads from offline\powershell; in a clone, from the installed
# copy of the version in tools/versions.psd1. Exits 1 on any finding.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pin  = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'versions.psd1')).Modules | Where-Object { $_.Name -eq 'PSScriptAnalyzer' }

$kitCopy = [IO.Path]::Combine($root, 'offline', 'powershell', 'PSScriptAnalyzer', $pin.Version, 'PSScriptAnalyzer.psd1')
if (Test-Path -LiteralPath $kitCopy) { $m = Import-Module $kitCopy -Force -PassThru }
else { $m = Import-Module PSScriptAnalyzer -RequiredVersion $pin.Version -Force -PassThru }
if ($m.Version -ne [version]$pin.Version) { throw "loaded PSScriptAnalyzer $($m.Version), want $($pin.Version)" }
Write-Host "PSScriptAnalyzer $($m.Version) from $($m.ModuleBase)"

$files = @(Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and
                   $_.FullName.Substring($root.Length + 1) -notmatch '^(offline|dist|\.venv|\.git)[\\/]' })
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$found = @($files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings })
if ($found) { $found | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host }

# Windows PowerShell 5.1 reads a BOM-less file as the system code page, so one curly quote breaks it.
$notAscii = @($files | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '[^\x00-\x7F]' })
foreach ($f in $notAscii) { Write-Host "not ASCII: $($f.FullName)" }

Write-Host "$($files.Count) files: $($found.Count) analyzer finding(s), $($notAscii.Count) not ASCII"
if ($found -or $notAscii) { exit 1 }
