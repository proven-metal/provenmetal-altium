#Requires -Version 5.1
<#
.SYNOPSIS
    Build the ProvenMetal Altium extension.

.DESCRIPTION
    1. Locates your Altium Designer installation and copies the two SDK assemblies
       it needs (Altium.SDK.dll, Altium.SDK.Interfaces.dll) into .\Assemblies\.
       These are provided by Altium at runtime and are NOT shipped in the extension.
    2. Locates MSBuild (Visual Studio or Build Tools).
    3. Restores NuGet (Newtonsoft.Json) and builds Release.

.PARAMETER Configuration
    Debug or Release (default Release).

.PARAMETER Writeback
    Also compile the optional schematic writeback (PM_WRITEBACK). Off by default.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Build.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$Writeback,
    [string]$MSBuild = ''   # optional explicit path to MSBuild.exe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root       = $PSScriptRoot
$Proj       = Join-Path $Root 'ProvenMetal\ProvenMetal.csproj'
$AsmDir     = Join-Path $Root 'Assemblies'

function Fail($m) { Write-Host "[ERR] $m" -ForegroundColor Red; exit 1 }
function Ok($m)   { Write-Host "[OK]  $m" -ForegroundColor Green }
function Info($m) { Write-Host "      $m" -ForegroundColor Gray }

# --- 1. Altium SDK assemblies ------------------------------------------------

Write-Host "`n  Locating Altium SDK assemblies" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $AsmDir | Out-Null

$needed = @('Altium.SDK.dll', 'Altium.SDK.Interfaces.dll')
$haveAll = $true
foreach ($n in $needed) { if (-not (Test-Path (Join-Path $AsmDir $n))) { $haveAll = $false } }

if (-not $haveAll) {
    $altiumBase = 'C:\Program Files\Altium'
    $install = $null
    if (Test-Path $altiumBase) {
        $install = Get-ChildItem $altiumBase -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'X2.exe') } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $install) {
        Fail "Altium install not found under $altiumBase. Copy Altium.SDK.dll and Altium.SDK.Interfaces.dll into $AsmDir manually, then re-run."
    }
    Info "Altium: $($install.FullName)"
    foreach ($n in $needed) {
        $dest = Join-Path $AsmDir $n
        if (Test-Path $dest) { Ok "$n (already present)"; continue }
        $src = Get-ChildItem $install.FullName -Recurse -Filter $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $src) { Fail "Could not find $n under $($install.FullName)." }
        Copy-Item $src.FullName $dest -Force
        Ok "$n <- $($src.FullName)"
    }
} else {
    foreach ($n in $needed) { Ok "$n (already present)" }
}

# --- 2. MSBuild --------------------------------------------------------------

Write-Host "`n  Locating MSBuild" -ForegroundColor Cyan
$msbuild = $null

if ($MSBuild -and (Test-Path $MSBuild)) {
    $msbuild = $MSBuild
}

# vswhere (installed by VS / Build Tools) - try both Program Files locations and
# with/without the MSBuild component requirement.
if (-not $msbuild) {
    $vswheres = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
    )
    foreach ($vw in $vswheres) {
        if (-not (Test-Path $vw)) { continue }
        foreach ($qa in @(
            @('-latest', '-products', '*', '-requires', 'Microsoft.Component.MSBuild', '-find', 'MSBuild\**\Bin\MSBuild.exe'),
            @('-latest', '-products', '*', '-find', 'MSBuild\**\Bin\MSBuild.exe'))) {
            $p = & $vw @qa 2>$null | Select-Object -First 1
            if ($p -and (Test-Path $p)) { $msbuild = $p; break }
        }
        if ($msbuild) { break }
    }
}

# Explicit globs, then PATH.
if (-not $msbuild) {
    $globs = @(
        "C:\Program Files\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\*\MSBuild\Current\Bin\MSBuild.exe"
    )
    foreach ($g in $globs) {
        $m = Get-ChildItem $g -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { $msbuild = $m.FullName; break }
    }
}
if (-not $msbuild) {
    $cmd = Get-Command 'MSBuild.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $msbuild = $cmd.Source }
}

if (-not $msbuild) {
    Write-Host ""
    Write-Host "  Looked for MSBuild via vswhere, VS 2019/2022 folders, and PATH." -ForegroundColor DarkGray
    Write-Host "  If it is installed, pass it explicitly:  .\Build.ps1 -MSBuild `"<path to MSBuild.exe>`"" -ForegroundColor DarkGray
    Fail "MSBuild not found. Install the 'Build Tools for Visual Studio' with the .NET desktop build tools workload."
}
Ok "MSBuild: $msbuild"

# --- 3. Restore + build ------------------------------------------------------

$defines = 'TRACE'
if ($Writeback) { $defines = "$defines;PM_WRITEBACK"; Info "Writeback: ENABLED (PM_WRITEBACK)" }

Write-Host "`n  Restoring packages" -ForegroundColor Cyan
& $msbuild $Proj /t:Restore /v:minimal /nologo
if ($LASTEXITCODE -ne 0) { Fail "Restore failed." }

Write-Host "`n  Building ($Configuration)" -ForegroundColor Cyan
& $msbuild $Proj "/p:Configuration=$Configuration" '/p:Platform=AnyCPU' "/p:DefineConstants=$defines" /t:Build /v:minimal /nologo
if ($LASTEXITCODE -ne 0) { Fail "Build failed." }

$outDir = Join-Path $Root "ProvenMetal\bin\$Configuration"
Ok "Built -> $outDir"
Write-Host "`n  Next: .\Package.ps1  then  .\Deploy.ps1`n" -ForegroundColor Gray
