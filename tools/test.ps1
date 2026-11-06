# test.ps1 - runs the Pester suite with the pinned Pester, the way CI does.
#   ./tools/test.ps1
# In the dev kit Pester loads from offline\powershell; in a clone, from the installed copy of
# the version in tools/versions.psd1. Exits non-zero when a test fails.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pin  = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'versions.psd1')).Modules | Where-Object { $_.Name -eq 'Pester' }

$kitCopy = [IO.Path]::Combine($root, 'offline', 'powershell', 'Pester', $pin.Version, 'Pester.psd1')
if (Test-Path -LiteralPath $kitCopy) { $m = Import-Module $kitCopy -Force -PassThru }
else { $m = Import-Module Pester -RequiredVersion $pin.Version -Force -PassThru }
if ($m.Version -ne [version]$pin.Version) { throw "loaded Pester $($m.Version), want $($pin.Version)" }
Write-Host "Pester $($m.Version) from $($m.ModuleBase)"

$c = New-PesterConfiguration
$c.Run.Path = Join-Path $root 'tests'
$c.Run.Exit = $true
$c.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $c
