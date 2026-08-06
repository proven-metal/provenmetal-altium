<#
  install.ps1 - set up the ProvenMetal Altium plugin on Windows in one step.

  Copies the plugin into a local folder (so it isn't run off a Parallels/network
  share) and "unblocks" the files - Parallels shared folders tag files with the
  "downloaded from another computer" mark, which otherwise stops Windows from
  running the bundled PowerShell helper (pm_client.ps1).

  Run from Windows (e.g. inside your Parallels VM), pointing at this repo:

    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

  Choose a different destination with:

    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Dest "D:\Tools\ProvenMetal"
#>

[CmdletBinding()]
param(
    [string]$Dest = 'C:\ProvenMetal\provenmetal-altium'
)

$ErrorActionPreference = 'Stop'

$srcPlugin = Join-Path $PSScriptRoot 'plugin'
if (-not (Test-Path $srcPlugin)) {
    Write-Error "Could not find a 'plugin' folder next to install.ps1 ($srcPlugin)."
    exit 1
}

$destPlugin = Join-Path $Dest 'plugin'

Write-Host "ProvenMetal Altium plugin - install"
Write-Host "  from : $srcPlugin"
Write-Host "  to   : $destPlugin"
Write-Host ""

# Fresh copy (Remove first so we don't nest plugin\plugin on re-runs).
if (Test-Path $destPlugin) {
    Write-Host "Replacing existing install ..."
    Remove-Item -Recurse -Force $destPlugin
}
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Copy-Item -Recurse -Force $srcPlugin $destPlugin

# Clear the mark-of-the-web on every copied file.
Get-ChildItem -Recurse -File $destPlugin | Unblock-File -ErrorAction SilentlyContinue

$prj = Join-Path $destPlugin 'ProvenMetal.PrjScr'
$ps1 = Join-Path $destPlugin 'helper\pm_client.ps1'

if (-not (Test-Path $prj)) { Write-Error "Copy finished but $prj is missing."; exit 1 }
if (-not (Test-Path $ps1)) { Write-Error "Copy finished but $ps1 is missing."; exit 1 }

Write-Host ""
Write-Host "Done. Installed to $destPlugin"
Write-Host ""
Write-Host "Next steps"
Write-Host "  1) In Altium:  File > Open Project...  and choose:"
Write-Host "        $prj"
Write-Host "  2) DXP > Run Script...  >  ProvenMetal_Main.pas  >  SourceWithProvenMetal"
Write-Host "     (or bind SourceWithProvenMetal to a toolbar button via DXP > Customize)"
Write-Host ""
Write-Host "Optional smoke test (sign in without Altium):"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -Command login"
