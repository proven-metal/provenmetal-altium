#Requires -Version 5.1
<#
.SYNOPSIS
    Build the release zip for GitHub Releases.

.DESCRIPTION
    Runs Build.ps1 + Package.ps1, then zips dist\ together with the repo's
    install.ps1 into ProvenMetal-Altium-v<version>.zip. Upload that zip as a
    release asset; the one-line installer downloads it.

.PARAMETER Version
    Release version, e.g. 1.0.0 (default: read from Properties\AssemblyInfo.cs).
#>
[CmdletBinding()]
param([string]$Version = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot

if (-not $Version) {
    $ai = Get-Content (Join-Path $Root 'ProvenMetal\Properties\AssemblyInfo.cs') -Raw
    if ($ai -match 'AssemblyVersion\("(\d+\.\d+\.\d+)') { $Version = $Matches[1] }
    else { $Version = '1.0.0' }
}

& (Join-Path $Root 'Build.ps1')
if ($LASTEXITCODE -ne 0) { exit 1 }
& (Join-Path $Root 'Package.ps1')
if ($LASTEXITCODE -ne 0) { exit 1 }

$staging = Join-Path $Root "release-staging"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null

Copy-Item (Join-Path $Root 'dist\*') $staging -Force
Copy-Item (Join-Path (Split-Path $Root -Parent) 'install.ps1') $staging -Force

$zip = Join-Path $Root ("ProvenMetal-Altium-v$Version.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
Remove-Item $staging -Recurse -Force

Write-Host ""
Write-Host "Release asset: $zip" -ForegroundColor Green
Write-Host ""
Write-Host "Publish it (from a machine with gh):" -ForegroundColor Gray
Write-Host "  gh release create v$Version `"$zip`" --repo proven-metal/provenmetal-altium --title `"v$Version`" --notes `"...`"" -ForegroundColor Gray
Write-Host ""
