# GUI installer (`.exe`)

A conventional **double-click → Next → Finish** Windows installer for the
ProvenMetal Altium extension, built with [Inno Setup](https://jrsoftware.org/isinfo.php).

It bundles the built extension payload plus the repo's `install.ps1` and simply runs
that script under the hood, so it uses the exact same tested install path as the
one-line PowerShell installer (copy files into Altium's `Extensions\ProvenMetal\`
folder + register in `ExtensionsRegistry.xml`). Uninstalling runs
`install.ps1 -Uninstall`, so Altium is properly de-registered.

Nice touches: it refuses to install while Altium (`X2.exe`) is running (that locks
the extension DLL) and prompts you to close it, and it needs **no admin rights**.

## Build

On a Windows box that already builds the extension (see `../README.md`), plus
[Inno Setup 6](https://jrsoftware.org/isdl.php) (`winget install JRSoftware.InnoSetup`):

```powershell
cd extension\installer
powershell -ExecutionPolicy Bypass -File Build-Installer.ps1
# -> ProvenMetal-Altium-Setup-v<version>.exe
```

`Build-Installer.ps1` runs `..\Build.ps1` + `..\Package.ps1` first (pass `-SkipBuild`
if `..\dist` is already staged), then compiles `ProvenMetal.iss`.

## Code signing (clears SmartScreen)

An unsigned installer triggers the Windows SmartScreen "unknown publisher" prompt.
To sign it, pass a code-signing certificate — no `signtool`/Windows SDK needed, it
uses `Set-AuthenticodeSignature`:

```powershell
$env:PM_SIGN_PFX  = 'C:\certs\provenmetal.pfx'
$env:PM_SIGN_PASS = '<pfx password>'
powershell -ExecutionPolicy Bypass -File Build-Installer.ps1
```

Or reference a cert already in `Cert:\CurrentUser\My` via `-SignThumbprint` /
`$env:PM_SIGN_THUMBPRINT`.

**SmartScreen only clears with a certificate from a trusted CA** — an OV/EV
code-signing cert, or [Azure Trusted Signing](https://learn.microsoft.com/azure/trusted-signing/).
A self-signed cert proves the pipeline works but will still be untrusted on other
machines. (EV certs / Trusted Signing build SmartScreen reputation fastest.)

## Why not a "native Altium extension package"?

Altium Designer has no supported "install this file" button for third-party
extensions. Per Altium's docs, the **Extensions & Updates** page installs from a
configured *source* only:

1. **Altium's cloud Global Extensions Gallery** — you publish through the paid
   **Altium Developer** extension + the AltiumLive **Partner Dashboard**
   (`apps.live.altium.com`); Altium signs/licenses and distributes it. Users then
   install it from within Altium.
2. **A self-hosted local extension repository** pointed to by each user under
   *Preferences → System → Installation*.

Both are heavyweight (vendor onboarding, or hosting + per-user configuration).
Importantly, the on-disk result of any of these is exactly what our installer
already produces: `…\Extensions\ProvenMetal\` + an `ExtensionsRegistry.xml` entry.
So this `.exe` (and the one-line `install.ps1`) already perform the standard
offline install; the gallery route is only worth it for wide public distribution.
