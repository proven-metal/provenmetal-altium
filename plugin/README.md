# ProvenMetal for Altium — script edition (DelphiScript)

The no-compiler edition of the ProvenMetal Altium plugin. Same behavior as the
compiled extension in `../extension/` (which is what most people should use):
reads the focused project's BOM, pushes it to ProvenMetal Central, shows the
sourcing verdict. Kept for people who want to read/tweak every line of what
runs, or can't install a compiled extension.

It is a DelphiScript script project plus a PowerShell helper. The scripts read
the BOM and drive the UI inside Altium; `helper/pm_client.ps1` does the network
side (server config, browser sign-in, token cache, the push). PowerShell ships
with Windows, so there is nothing to install.

## Install

1. Copy this `plugin\` folder somewhere stable, e.g.
   `C:\ProvenMetal\plugin\`. If it came from a download, unblock it:
   `Get-ChildItem -Recurse C:\ProvenMetal\plugin | Unblock-File`
2. In Altium: **File → Open Project…** → `ProvenMetal.PrjScr`.
3. Run it: **File → Run Script…** → `ProvenMetal_Main.pas` →
   `SourceWithProvenMetal`. (DXP → Customize lets you put it on a toolbar.)

Other entry points: `ProvenMetalLogin`, `ProvenMetalLogout`,
`ProvenMetalSetBaseUrl`.

## Settings

Same file as the compiled extension: `%APPDATA%\provenmetal-altium\settings.json`.
Two extra keys are specific to this edition:

```jsonc
{
  "helper_path": "",              // explicit path to pm_client.ps1 if not auto-found
  "writeback": false,             // write PM_* verdict params onto components
  "writeback_field_prefix": "PM"
}
```

The helper is auto-located when `ProvenMetal.PrjScr` is open as a project.

## Files

```
ProvenMetal.PrjScr           script project (open this)
ProvenMetal_Main.pas         entry points
ProvenMetal_Bom.pas          flattened BOM via the Design Manager API
ProvenMetal_Fields.pas       parameter-name mapping
ProvenMetal_Grouping.pas     rows -> orderable lines
ProvenMetal_Verdict.pas      local mirror of the server verdict
ProvenMetal_Settings.pas     settings + project sidecar
ProvenMetal_Json.pas         JSON build + minimal readers
ProvenMetal_Client.pas       bridge to the PowerShell helper
ProvenMetal_UI.pas           progress/results window
ProvenMetal_Writeback.pas    optional writeback of PM_* params
helper/pm_client.ps1         config / login / push / logout
```

Log: `%APPDATA%\provenmetal-altium\last-run.log`.
