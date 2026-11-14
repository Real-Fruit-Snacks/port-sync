# The versions CI and the dev kit use, in one place so they can't drift. Read by
# .github/workflows/ci.yml and offline.yml, tools/lint.ps1, tools/test.ps1,
# tools/third-party-licences.ps1, tools/build-dev-kit.ps1 and the kit's offline\setup.ps1.
# The panel's Python packages are pinned in docs/art/requirements.txt, the Rust crates in
# Cargo.lock.
@{
    # The toolchain that builds port-sync.exe (x86_64-pc-windows-msvc).
    Rust = '1.99.1'

    # Writes THIRD-PARTY-LICENSES.txt for the downloads, with the checksum of its Windows
    # release archive from github.com/EmbarkStudios/cargo-about/releases.
    CargoAbout = @{ Version = '0.9.3'; Sha256 = '9e2942533ef1c592c4a70bdb384cae1550a3f5fc9ae40379b6662e3d2f16fe02' }

    # For the installer's lint and tests; port-sync itself needs no modules.
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
