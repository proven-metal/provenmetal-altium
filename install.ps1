<#
  ProvenMetal for Altium Designer - installer.

  Installs the ProvenMetal extension into Altium Designer. No build tools needed:
  it downloads the latest prebuilt release from GitHub and registers it.

  Quick install (PowerShell):

    irm https://raw.githubusercontent.com/proven-metal/provenmetal-altium/main/install.ps1 | iex

  Or download a release zip yourself and run the install.ps1 inside it, or:

    .\install.ps1 -ZipPath .\ProvenMetal-Altium-v1.0.0.zip

  Options:
    -ZipPath <file>   install from a local release zip instead of downloading
    -ExtRoot <dir>    your Altium ...\Extensions folder, if auto-detect fails
    -Uninstall        remove the extension
#>
[CmdletBinding()]
param(
    [string]$ZipPath = '',
    [string]$ExtRoot = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo       = 'proven-metal/provenmetal-altium'
$Hrid       = 'ProvenMetal'
$PluginGuid = 'A7D3F2C1-9E4B-4A6D-8C2E-1F5B7A9C0D31'
$VerGuid    = 'C4E8B1A2-6F3D-4E92-A7B5-2D9C8E0F1A63'

function Ok($m)   { Write-Host "[ok]  $m" -ForegroundColor Green }
function Info($m) { Write-Host "      $m" -ForegroundColor Gray }
function Warn($m) { Write-Host "[!]   $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[err] $m" -ForegroundColor Red; exit 1 }

# --- locate the Altium Extensions folder --------------------------------------

function Find-ExtRoot {
    if ($ExtRoot -and (Test-Path $ExtRoot)) { return (Resolve-Path $ExtRoot).Path }

    $base = 'C:\ProgramData\Altium'
    if (Test-Path $base) {
        $c = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'Extensions') } |
            Sort-Object LastWriteTime -Descending
        if ($c) { return Join-Path $c[0].FullName 'Extensions' }
    }

    foreach ($b in @($base, "$env:LOCALAPPDATA\Altium", "$env:APPDATA\Altium")) {
        if (-not ($b -and (Test-Path $b))) { continue }
        $reg = Get-ChildItem $b -Recurse -Depth 4 -Filter 'ExtensionsRegistry.xml' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($reg) { return Split-Path $reg.FullName -Parent }
    }
    return $null
}

function Save-Registry([xml]$xml, [string]$path) {
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true; $settings.IndentChars = '  '
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $w = [System.Xml.XmlWriter]::Create($path, $settings)
    try { $xml.Save($w) } finally { $w.Flush(); $w.Close() }
}

# --- uninstall -----------------------------------------------------------------

if ($Uninstall) {
    $root = Find-ExtRoot
    if (-not $root) { Die "Couldn't find the Altium Extensions folder. Pass it with -ExtRoot." }
    $dir = Join-Path $root $Hrid
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force; Ok "Removed $dir" } else { Info "No files at $dir" }
    $regPath = Join-Path $root 'ExtensionsRegistry.xml'
    if (Test-Path $regPath) {
        [xml]$xml = Get-Content $regPath -Encoding UTF8
        $item = $xml.Extensions.Item | Where-Object { $_.HRID -eq $Hrid }
        if ($item) { $item.ParentNode.RemoveChild($item) | Out-Null; Save-Registry $xml $regPath; Ok "Unregistered from ExtensionsRegistry.xml" }
    }
    Write-Host "`nUninstalled. Restart Altium." -ForegroundColor White
    exit 0
}

# --- get the release files -------------------------------------------------------

Write-Host "`nProvenMetal for Altium Designer - install`n" -ForegroundColor Cyan

$work = Join-Path $env:TEMP ("provenmetal-altium-" + [Guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$cleanupWork = $true

try {
    $srcDir = $null

    if ($ZipPath) {
        if (-not (Test-Path $ZipPath)) { Die "Zip not found: $ZipPath" }
        Info "Using local zip: $ZipPath"
        Expand-Archive -Path $ZipPath -DestinationPath $work -Force
        $srcDir = $work
    }
    elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'ProvenMetal.dll'))) {
        # Running from inside an extracted release zip.
        $srcDir = $PSScriptRoot
        Info "Installing from $srcDir"
    }
    else {
        Info "Fetching the latest release from github.com/$Repo ..."
        try {
            $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'provenmetal-installer' }
        } catch {
            Die "Couldn't query GitHub releases ($($_.Exception.Message)). Download the release zip from https://github.com/$Repo/releases and run:  .\install.ps1 -ZipPath <zip>"
        }
        $asset = $rel.assets | Where-Object { $_.name -like 'ProvenMetal-Altium-*.zip' } | Select-Object -First 1
        if (-not $asset) { Die "The latest release has no ProvenMetal-Altium-*.zip asset. See https://github.com/$Repo/releases" }
        $zip = Join-Path $work $asset.name
        Info "Downloading $($asset.name) ($([math]::Round($asset.size/1kb)) KB) ..."
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $work -Force
        $srcDir = $work
    }

    # The dll may be at the zip root or in a dist\ subfolder.
    $dll = Get-ChildItem $srcDir -Recurse -Filter 'ProvenMetal.dll' | Select-Object -First 1
    if (-not $dll) { Die "ProvenMetal.dll not found in the package." }
    $payload = Split-Path $dll.FullName -Parent

    foreach ($required in @('ProvenMetal.Ins', 'ProvenMetal.rcs', 'Newtonsoft.Json.dll')) {
        if (-not (Test-Path (Join-Path $payload $required))) { Die "Package is missing $required." }
    }

    # --- find Altium ------------------------------------------------------------

    $root = Find-ExtRoot
    if (-not $root) {
        Die "Couldn't find Altium Designer's Extensions folder (looked under C:\ProgramData\Altium). Is Altium installed? If it's somewhere unusual, re-run with -ExtRoot `"<...>\Extensions`""
    }
    Ok "Altium extensions folder: $root"

    if (Get-Process -Name 'X2' -ErrorAction SilentlyContinue) {
        Warn "Altium Designer is running. Finish the install, then restart Altium to load the extension."
    }

    # --- copy + register ----------------------------------------------------------

    $dest = Join-Path $root $Hrid
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $names = @('ProvenMetal.dll', 'ProvenMetal.Ins', 'ProvenMetal.rcs', 'Newtonsoft.Json.dll', 'ProvenMetal.pdb')
    foreach ($n in $names) {
        $src = Join-Path $payload $n
        if (Test-Path $src) { Copy-Item $src (Join-Path $dest $n) -Force }
    }
    Get-ChildItem $dest -File | Unblock-File -ErrorAction SilentlyContinue
    Ok "Copied files to $dest"

    $regPath = Join-Path $root 'ExtensionsRegistry.xml'
    if (-not (Test-Path $regPath)) {
        Set-Content -Path $regPath -Value "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<Extensions>`n</Extensions>" -Encoding UTF8
        Warn "ExtensionsRegistry.xml did not exist - created a new one."
    }

    [xml]$xml = Get-Content $regPath -Encoding UTF8
    $existing = $xml.Extensions.Item | Where-Object { $_.HRID -eq $Hrid }
    if ($existing) {
        $pathNode = $existing.SelectSingleNode('Path')
        if (-not $pathNode) { $pathNode = $xml.CreateElement('Path'); $existing.AppendChild($pathNode) | Out-Null }
        $pathNode.InnerText = $dest
        Ok "Registry entry refreshed."
    }
    else {
        $item = $xml.CreateElement('Item')
        $item.SetAttribute('HRID', $Hrid)
        $item.SetAttribute('Guid', $PluginGuid)
        $oleDate = ([datetime]::Today - [datetime]'1899-12-30').TotalDays.ToString('F7')
        $fields = [ordered]@{
            Path = $dest; Status = '0'; VaultGuid = ''; CreatedBy = 'ProvenMetal'
            CategoryGuid = '793A1F67-0B22-4E01-A5DE-3176A1E8C60D'; CategoryName = ''
            ReadMe = ''; Help = ''; Requirements = ''; Title = $Hrid
            ShortDescription = 'ProvenMetal BOM sourcing'
            LongDescription = 'Push a project BOM to ProvenMetal Central and flag parts not in stock or sourceable within a week.'
            SmallImage = ''; LargeImage = ''; Version = '1.0.0.0'; VersionGuid = $VerGuid
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
        $xml.SelectSingleNode('Extensions').AppendChild($item) | Out-Null
        Ok "Registered with Altium."
    }
    Save-Registry $xml $regPath

    Write-Host ""
    Write-Host "Installed. Restart Altium Designer, open a project, and run" -ForegroundColor White
    Write-Host "Tools > Source with ProvenMetal (with a schematic or PCB open)." -ForegroundColor White
    Write-Host ""
}
finally {
    if ($cleanupWork -and (Test-Path $work)) {
        try { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}
