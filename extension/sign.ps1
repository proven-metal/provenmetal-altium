#Requires -Version 5.1
<#
.SYNOPSIS
    Authenticode-sign the built extension DLL in dist\.

.DESCRIPTION
    Signs dist\ProvenMetal.dll with your code-signing certificate and timestamps
    it. Run after Package.ps1, before Deploy.ps1.

.PARAMETER Pfx
    Path to your .pfx code-signing certificate. If omitted, uses the best
    available cert in your certificate store (signtool /a).

.PARAMETER Password
    Password for the .pfx (if using -Pfx).

.PARAMETER TimestampUrl
    RFC3161 timestamp server (default: DigiCert).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File sign.ps1 -Pfx C:\certs\proven.pfx -Password ****
    powershell -ExecutionPolicy Bypass -File sign.ps1     # use store cert
#>
[CmdletBinding()]
param(
    [string]$Pfx,
    [string]$Password,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dll = Join-Path $PSScriptRoot 'dist\ProvenMetal.dll'
if (-not (Test-Path $dll)) { Write-Host "[ERR] $dll not found. Run Package.ps1 first." -ForegroundColor Red; exit 1 }

# Locate signtool (Windows SDK).
$signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue
if (-not $signtool) {
    $cand = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'x64' } | Sort-Object FullName -Descending | Select-Object -First 1
    if ($cand) { $signtool = $cand } else { Write-Host "[ERR] signtool.exe not found (install the Windows SDK)." -ForegroundColor Red; exit 1 }
}
$stPath = $signtool.Source; if (-not $stPath) { $stPath = $signtool.FullName }

$args = @('sign', '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256')
if ($Pfx) {
    $args += @('/f', $Pfx)
    if ($Password) { $args += @('/p', $Password) }
} else {
    $args += '/a'   # auto-select best cert from the store
}
$args += $dll

Write-Host "  Signing $dll ..." -ForegroundColor Cyan
& $stPath @args
if ($LASTEXITCODE -ne 0) { Write-Host "[ERR] Signing failed." -ForegroundColor Red; exit 1 }
Write-Host "[OK]  Signed and timestamped." -ForegroundColor Green
