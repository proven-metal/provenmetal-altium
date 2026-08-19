#Requires -Version 5.1
<#
.SYNOPSIS
    Build (and optionally code-sign) the ProvenMetal Altium GUI installer .exe.

.DESCRIPTION
    1. Builds + stages the extension (runs ..\Build.ps1 and ..\Package.ps1) unless
       -SkipBuild is given and extension\dist already exists.
    2. Locates the Inno Setup compiler (ISCC.exe) and compiles ProvenMetal.iss into
       ProvenMetal-Altium-Setup-v<version>.exe.
    3. If a code-signing certificate is supplied, Authenticode-signs the installer
       (and the bundled ProvenMetal.dll) via Set-AuthenticodeSignature - no signtool
       or Windows SDK required.

    Signing is what clears the Windows SmartScreen "unknown publisher" warning, but
    only with a certificate from a trusted CA (OV/EV code-signing, or Azure Trusted
    Signing). A self-signed cert proves the pipeline but does NOT satisfy SmartScreen
    on other machines.

.PARAMETER Version
    Version stamped into the installer (default: read from ProvenMetal AssemblyInfo).

.PARAMETER SignPfx
    Path to a .pfx code-signing certificate. Defaults to $env:PM_SIGN_PFX.

.PARAMETER SignPass
    Password for the .pfx. Defaults to $env:PM_SIGN_PASS.

.PARAMETER SignThumbprint
    Alternatively, the thumbprint of a code-signing cert already in the certificate
    store (Cert:\CurrentUser\My). Defaults to $env:PM_SIGN_THUMBPRINT.

.PARAMETER TimestampUrl
    RFC-3161 timestamp server (default DigiCert).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Build-Installer.ps1

.EXAMPLE
    # With a real code-signing certificate:
    $env:PM_SIGN_PFX='C:\certs\provenmetal.pfx'; $env:PM_SIGN_PASS='...'
    powershell -ExecutionPolicy Bypass -File Build-Installer.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$SignPfx = $env:PM_SIGN_PFX,
    [string]$SignPass = $env:PM_SIGN_PASS,
    [string]$SignThumbprint = $env:PM_SIGN_THUMBPRINT,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root    = $PSScriptRoot                       # extension\installer
$ExtDir  = Split-Path $Root -Parent            # extension
$Dist    = Join-Path $ExtDir 'dist'
$Iss     = Join-Path $Root 'ProvenMetal.iss'

function Fail($m) { Write-Host "[ERR] $m" -ForegroundColor Red; exit 1 }
function Ok($m)   { Write-Host "[OK]  $m" -ForegroundColor Green }
function Info($m) { Write-Host "      $m" -ForegroundColor Gray }

# --- version ------------------------------------------------------------------

if (-not $Version) {
    $ai = Join-Path $ExtDir 'ProvenMetal\Properties\AssemblyInfo.cs'
    if ((Test-Path $ai) -and ((Get-Content $ai -Raw) -match 'AssemblyVersion\("(\d+\.\d+\.\d+)')) {
        $Version = $Matches[1]
    } else { $Version = '1.0.0' }
}
Info "Version: $Version"

# --- 1. build + stage payload -------------------------------------------------

if (-not $SkipBuild -or -not (Test-Path (Join-Path $Dist 'ProvenMetal.dll'))) {
    Write-Host "`n  Building + staging the extension" -ForegroundColor Cyan
    & (Join-Path $ExtDir 'Build.ps1')
    if ($LASTEXITCODE -ne 0) { Fail "Build.ps1 failed." }
    & (Join-Path $ExtDir 'Package.ps1')
    if ($LASTEXITCODE -ne 0) { Fail "Package.ps1 failed." }
}
if (-not (Test-Path (Join-Path $Dist 'ProvenMetal.dll'))) { Fail "dist\ProvenMetal.dll missing - build first." }

# --- 2. locate ISCC + compile -------------------------------------------------

Write-Host "`n  Locating Inno Setup (ISCC.exe)" -ForegroundColor Cyan
$iscc = $null
foreach ($p in @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe")) {
    if ($p -and (Test-Path $p)) { $iscc = $p; break }
}
if (-not $iscc) {
    $cmd = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $iscc = $cmd.Source }
}
if (-not $iscc) {
    Fail "Inno Setup 6 not found. Install it from https://jrsoftware.org/isdl.php (or 'winget install JRSoftware.InnoSetup')."
}
Ok "ISCC: $iscc"

Write-Host "`n  Compiling installer" -ForegroundColor Cyan
& $iscc "/DMyAppVersion=$Version" $Iss
if ($LASTEXITCODE -ne 0) { Fail "ISCC compile failed." }

$exe = Join-Path $Root "ProvenMetal-Altium-Setup-v$Version.exe"
if (-not (Test-Path $exe)) { Fail "Expected installer not found: $exe" }
Ok "Built installer: $exe"

# --- 3. optional code-signing -------------------------------------------------

$cert = $null
if ($SignPfx) {
    if (-not (Test-Path $SignPfx)) { Fail "SignPfx not found: $SignPfx" }
    Info "Signing with PFX: $SignPfx"
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
        $SignPfx, $SignPass, 'Exportable,PersistKeySet'
}
elseif ($SignThumbprint) {
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $SignThumbprint } | Select-Object -First 1
    if (-not $cert) { Fail "No cert with thumbprint $SignThumbprint in Cert:\CurrentUser\My." }
    Info "Signing with store cert: $SignThumbprint"
}

if ($cert) {
    # Sign the bundled DLL first (defence in depth), then the installer itself.
    $targets = @((Join-Path $Dist 'ProvenMetal.dll'), $exe)
    foreach ($t in $targets) {
        if (-not (Test-Path $t)) { continue }
        $sig = Set-AuthenticodeSignature -FilePath $t -Certificate $cert `
            -HashAlgorithm SHA256 -TimestampServer $TimestampUrl
        if ($sig.Status -ne 'Valid') { Fail "Signing $t failed: $($sig.Status) - $($sig.StatusMessage)" }
        Ok "Signed: $(Split-Path $t -Leaf)  [$($sig.SignerCertificate.Subject)]"
    }
    if ($SignPfx -or $SignThumbprint) {
        # If we signed the DLL, rebuild the installer so it bundles the signed DLL.
        Write-Host "`n  Recompiling installer to embed the signed DLL" -ForegroundColor Cyan
        & $iscc "/DMyAppVersion=$Version" $Iss | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "ISCC recompile failed." }
        $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert `
            -HashAlgorithm SHA256 -TimestampServer $TimestampUrl
        if ($sig.Status -ne 'Valid') { Fail "Re-signing installer failed: $($sig.Status)" }
        Ok "Signed installer (final): $(Split-Path $exe -Leaf)"
    }
}
else {
    Write-Host ""
    Write-Host "  [!] Not signed. Windows SmartScreen will warn users ('unknown publisher')." -ForegroundColor Yellow
    Write-Host "      Provide a code-signing cert to sign it:" -ForegroundColor DarkGray
    Write-Host "        `$env:PM_SIGN_PFX='<path.pfx>'; `$env:PM_SIGN_PASS='<pw>'; .\Build-Installer.ps1 -SkipBuild" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Installer: $exe" -ForegroundColor Green
Write-Host ""
