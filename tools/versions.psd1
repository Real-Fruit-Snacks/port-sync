# The versions CI and the dev kit use, in one place so they can't drift. Read by
# .github/workflows/ci.yml and offline.yml, tools/lint.ps1, tools/test.ps1,
# tools/build-dev-kit.ps1 and the kit's offline\setup.ps1. The panel's Python packages are
# pinned in docs/art/requirements.txt.
@{
    # For development only; port-sync itself needs no modules.
    Modules = @(
        @{ Name = 'Pester';           Version = '5.7.1' }
        @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0' }
    )

    # CPython for docs/art/make-panel.py: CI's art job, and the wheels in the dev kit.
    Python = '3.13.17'

    # For the tests against a real Web UI. CI installs Ubuntu 24.04's package, on Linux only,
    # and checks it is this version.
    QbittorrentNox = '4.6.3'
}
