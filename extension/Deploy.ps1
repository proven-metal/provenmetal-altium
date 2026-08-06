#Requires -Version 5.1
<#
.SYNOPSIS
    Install the ProvenMetal extension from dist\ into Altium Designer and register
    it, so it appears under Extensions & Updates with a "Source with ProvenMetal"
    menu/toolbar command.

.DESCRIPTION
    Copies dist\ into  C:\ProgramData\Altium\Altium Designer {GUID}\Extensions\ProvenMetal\
    and adds/refreshes the entry in ExtensionsRegistry.xml. The Altium install is
    discovered automatically. Restart Altium after deploying.

    Self-contained: ship this script next to the dist\ folder.

.PARAMETER Force
    Deploy even if Altium is running (restart required to load it).
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$ExtRoot = ''   # explicit path to the Altium ...\Extensions folder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Hrid        = 'ProvenMetal'
$PluginGuid  = 'A7D3F2C1-9E4B-4A6D-8C2E-1F5B7A9C0D31'
$PluginVer   = 'C4E8B1A2-6F3D-4E92-A7B5-2D9C8E0F1A63'
$Dist        = Join-Path $PSScriptRoot 'dist'

function Fail($m) { Write-Host "[ERR] $m" -ForegroundColor Red; exit 1 }
function Ok($m)   { Write-Host "[OK]  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!!]  $m" -ForegroundColor Yellow }

# --- find the Altium Extensions root -----------------------------------------

function Find-ExtRoot {
    if ($ExtRoot -and (Test-Path $ExtRoot)) { return $ExtRoot }

    # 1. Any AD data folder under ProgramData\Altium that has an Extensions subfolder
    #    (works for 'Altium Designer {GUID}', 'ADDevelop {GUID}', etc.).
    $base = 'C:\ProgramData\Altium'
    if (Test-Path $base) {
        $c = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'Extensions') } |
            Sort-Object LastWriteTime -Descending
        if ($c) { return Join-Path $c[0].FullName 'Extensions' }
    }

    # 2. Locate ExtensionsRegistry.xml anywhere reasonable; its folder IS the root.
    $searchBases = @($base, "$env:LOCALAPPDATA\Altium", "$env:APPDATA\Altium") | Where-Object { $_ -and (Test-Path $_) }
    foreach ($b in $searchBases) {
        $reg = Get-ChildItem $b -Recurse -Depth 4 -Filter 'ExtensionsRegistry.xml' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($reg) { return Split-Path $reg.FullName -Parent }
    }

    # 3. Any folder literally named Extensions under ProgramData\Altium.
    if (Test-Path $base) {
        $ext = Get-ChildItem $base -Recurse -Depth 3 -Directory -Filter 'Extensions' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($ext) { return $ext.FullName }
    }

    return $null
}

# --- pre-flight --------------------------------------------------------------

if (-not (Test-Path (Join-Path $Dist 'ProvenMetal.dll'))) {
    Fail "dist\ProvenMetal.dll not found. Run .\Build.ps1 then .\Package.ps1 first."
}

$running = Get-Process -Name 'X2' -ErrorAction SilentlyContinue
if ($running -and -not $Force) {
    Warn "Altium Designer is running. It must be restarted to load the extension."
    $a = Read-Host "  Continue anyway? [y/N]"
    if ($a -notmatch '^[Yy]') { Write-Host "  Aborted."; exit 0 }
} elseif ($running) {
    Warn "Altium is running - restart it after deploy."
}

$extRoot = Find-ExtRoot
if (-not $extRoot) {
    Fail "Couldn't locate the Altium Extensions folder. Find it (it contains ExtensionsRegistry.xml) and pass it explicitly:  .\Deploy.ps1 -ExtRoot `"<path>\Extensions`""
}
Ok "Extensions root: $extRoot"

# --- copy files --------------------------------------------------------------

$deployDir = Join-Path $extRoot $Hrid
New-Item -ItemType Directory -Force -Path $deployDir | Out-Null
Get-ChildItem $Dist -File | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $deployDir $_.Name) -Force
    Ok "Copied $($_.Name)"
}

# --- register in ExtensionsRegistry.xml --------------------------------------

$registry = Join-Path $extRoot 'ExtensionsRegistry.xml'
if (-not (Test-Path $registry)) {
    Warn "ExtensionsRegistry.xml not found - files copied, but you may need to install once via Extensions & Updates > (gear) > Install from folder."
} else {
    [xml]$xml = Get-Content $registry -Encoding UTF8
    $existing = $xml.Extensions.Item | Where-Object { $_.HRID -eq $Hrid }
    if ($existing) {
        $pathNode = $existing.SelectSingleNode('Path')
        if (-not $pathNode) { $pathNode = $xml.CreateElement('Path'); $existing.AppendChild($pathNode) | Out-Null }
        $pathNode.InnerText = $deployDir
        Ok "Registry: refreshed existing $Hrid entry."
    } else {
        $item = $xml.CreateElement('Item')
        $item.SetAttribute('HRID', $Hrid)
        $item.SetAttribute('Guid', $PluginGuid)
        $oleDate = ([datetime]::Today - [datetime]'1899-12-30').TotalDays.ToString('F7')
        $fields = [ordered]@{
            Path = $deployDir; Status = '0'; VaultGuid = ''; CreatedBy = 'ProvenMetal'
            CategoryGuid = '793A1F67-0B22-4E01-A5DE-3176A1E8C60D'; CategoryName = ''
            ReadMe = ''; Help = ''; Requirements = ''; Title = $Hrid
            ShortDescription = 'ProvenMetal BOM sourcing'
            LongDescription = 'Push a project BOM to ProvenMetal Central and flag parts not in stock or sourceable within a week.'
            SmallImage = ''; LargeImage = ''; Version = '1.0.0.0'; VersionGuid = $PluginVer
            ReleasedDate = $oleDate; ReleaseNotes = ''; DateInstalled = $oleDate
        }
        foreach ($k in $fields.Keys) {
            $el = $xml.CreateElement($k); $el.InnerText = $fields[$k]; $item.AppendChild($el) | Out-Null
        }
        $pv = $xml.CreateElement('PlatformVersions')
        foreach ($n in @('DXP', 'EDP', 'MaxDXP', 'MaxEDP')) {
            $el = $xml.CreateElement($n)
            $el.SetAttribute('BuildNumber', $(if ($n -like 'Max*') { '0.0.0.0' } else { '1.0.16.41' }))
            $pv.AppendChild($el) | Out-Null
        }
        $item.AppendChild($pv) | Out-Null
        $xml.Extensions.AppendChild($item) | Out-Null
        Ok "Registry: added $Hrid entry."
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true; $settings.IndentChars = '  '
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $w = [System.Xml.XmlWriter]::Create($registry, $settings)
    try { $xml.Save($w) } finally { $w.Flush(); $w.Close() }
}

Write-Host "`n  Deployed to $deployDir" -ForegroundColor White
Write-Host "  Restart Altium, then look for 'Source with ProvenMetal' in the Schematic/PCB Tools menu." -ForegroundColor Gray
Write-Host "  (Verify in Extensions & Updates > Installed.)`n" -ForegroundColor Gray
