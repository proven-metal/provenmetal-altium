#Requires -Version 5.1
<#
.SYNOPSIS
    Stage the built extension into dist\ ready for Deploy.ps1.

.DESCRIPTION
    Copies ProvenMetal.dll, the .Ins / .rcs manifests, and Newtonsoft.Json.dll
    into dist\. The Altium SDK assemblies are NOT copied - Altium provides them.

.PARAMETER Configuration
    Debug or Release (default Release).
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root   = $PSScriptRoot
$BinDir = Join-Path $Root "ProvenMetal\bin\$Configuration"
$Dist   = Join-Path $Root 'dist'

function Fail($m) { Write-Host "[ERR] $m" -ForegroundColor Red; exit 1 }
function Ok($m)   { Write-Host "[OK]  $m" -ForegroundColor Green }

if (-not (Test-Path (Join-Path $BinDir 'ProvenMetal.dll'))) {
    Fail "ProvenMetal.dll not found in $BinDir. Run .\Build.ps1 first."
}

if (Test-Path $Dist) { Remove-Item $Dist -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

$wanted = @('ProvenMetal.dll', 'ProvenMetal.pdb', 'ProvenMetal.Ins', 'ProvenMetal.rcs', 'Newtonsoft.Json.dll')
foreach ($n in $wanted) {
    $src = Join-Path $BinDir $n
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $Dist $n) -Force
        Ok $n
    }
    elseif ($n -eq 'ProvenMetal.pdb') {
        # symbols optional
    }
    else {
        Fail "Missing expected build output: $n"
    }
}

Write-Host "`n  Staged -> $Dist" -ForegroundColor White
Write-Host "  Next: .\sign.ps1 (optional)  then  .\Deploy.ps1`n" -ForegroundColor Gray
