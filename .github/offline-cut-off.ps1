# offline-cut-off.ps1 - for .github/workflows/offline.yml: cuts the job's later steps off from
# the internet and the package registries, then checks the cut holds. Dead proxies, dead
# registries, empty caches, no PowerShell Gallery. The runner's own link to GitHub is untouched:
# it doesn't read these variables, and nothing here changes the firewall or system proxy.
$ErrorActionPreference = 'Stop'
$dead  = 'http://127.0.0.1:9'
$fresh = Join-Path $env:RUNNER_TEMP 'fresh-caches'
$vars  = [ordered]@{
    HTTP_PROXY                    = $dead
    HTTPS_PROXY                   = $dead
    ALL_PROXY                     = $dead
    NO_PROXY                      = 'localhost,127.0.0.1'
    PIP_INDEX_URL                 = "$dead/simple"
    PIP_NO_INDEX                  = '1'
    PIP_DISABLE_PIP_VERSION_CHECK = '1'
    PIP_CACHE_DIR                 = Join-Path $fresh 'pip'
    npm_config_registry           = "$dead/"
    npm_config_cache              = Join-Path $fresh 'npm'
    NUGET_PACKAGES                = Join-Path $fresh 'nuget'
}
foreach ($k in $vars.Keys) {
    [IO.File]::AppendAllText($env:GITHUB_ENV, "$k=$($vars[$k])`n")
    Set-Item -Path "env:$k" -Value $vars[$k]
    Write-Host "$k=$($vars[$k])"
}
foreach ($d in 'pip', 'npm', 'nuget') { New-Item -ItemType Directory -Path (Join-Path $fresh $d) -Force | Out-Null }

# No PowerShell Gallery in either PowerShell: PowerShellGet in each, and PSResourceGet
$unregister = 'if (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) { Unregister-PSRepository -Name PSGallery }; ' +
              'if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) { ' +
              'if (Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue) { Unregister-PSResourceRepository -Name PSGallery } }; ' +
              '$left = @(Get-PSRepository -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq ''PSGallery'' }); ' +
              'if ($left) { throw ''PSGallery is still registered'' }; Write-Host "PSGallery: unregistered in PowerShell $($PSVersionTable.PSVersion)"'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($unregister))
foreach ($shell in 'powershell.exe', 'pwsh.exe') {
    & $shell -NoProfile -NonInteractive -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw "couldn't unregister PSGallery in $shell" }
}

# The cut holds: PowerShell 7 reads the proxy variables, so the gallery is out of reach
$reached = $true
try { Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2' -UseBasicParsing -TimeoutSec 20 | Out-Null }
catch { $reached = $false; Write-Host "internet: cut off ($($_.Exception.Message))" }
if ($reached) { throw 'the PowerShell Gallery is still reachable' }
