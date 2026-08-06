# ProvenMetal Altium Plugin

Sends an Altium project's BOM to ProvenMetal Central, sources every part against
distributor stock and lead time, and flags anything that is not in stock for the
full build or sourceable within one week.

This is the Altium port of the ProvenMetal KiCad plugin. It talks to the same
ProvenMetal Central endpoints (`/api/kicad/*`) and uses the same sign-in flow, so
no server changes are required.

## Two editions

- **`extension/` — compiled C# extension (recommended).** Installs like a real
  Altium add-in (Extensions & Updates), adds a **Source with ProvenMetal** button
  to the Schematic/PCB Tools menus, and does everything in‑process (no PowerShell).
  Needs a one‑time build in Windows (Visual Studio Build Tools). See
  [`extension/README.md`](extension/README.md).
- **`plugin/` — DelphiScript script + PowerShell helper.** No build toolchain
  required; open the `.PrjScr` and run it. Documented below. Good as a fallback or
  for quick trials.

The rest of this file documents the DelphiScript edition.

## How it works

1. Run **Source with ProvenMetal** in Altium (DXP > Run Script, or a toolbar
   button you bind to it).
2. The plugin compiles the project and reads the flattened BOM (designators,
   Comment/value, footprint, and MPN / Manufacturer / LCSC / Digikey / Mouser
   parameters), honouring the active assembly variant and "No BOM" components.
3. A branded ProvenMetal window opens immediately and shows live progress while it
   signs you in (browser, once) and sends the BOM.
4. The server sources each part and returns a result:
   - **pass**: in stock for the whole build, or sourceable within a week.
   - **review**: not enough data to decide (left for manual sourcing).
   - **fail**: not stocked anywhere, or out of stock with a long lead.
5. The same window fills in the verdict (parts / pass / review / fail, with the
   fail count in signal red) and the full report opens in your browser. An
   "Open report" button reopens it.

## Architecture

Altium plugins are written in **DelphiScript** (Altium's scripting language), which
has full access to the design API but is poor at HTTPS/OAuth/JSON. So the work is
split, exactly mirroring how the KiCad plugin shelled out to `kicad-cli`:

- **DelphiScript** (`plugin/*.pas`) reads the BOM from the project via the Design
  Manager API, groups it into orderable lines, shows the UI, and (optionally)
  writes results back into schematic parameters.
- **PowerShell** (`plugin/helper/pm_client.ps1`) does everything network-shaped:
  fetch server config, Supabase loopback-PKCE sign-in, token cache/refresh, the
  authenticated BOM push, and all JSON. It ships with Windows; nothing to install.

DelphiScript writes the request as JSON and reads back a flat `key=value` result
file, so it never has to parse JSON.

```
plugin/
  ProvenMetal.PrjScr           Altium script project (open this)
  ProvenMetal_Main.pas         entry points (Source / Login / Logout / SetBaseUrl)
  ProvenMetal_Bom.pas          read the flattened BOM via the Design Manager API
  ProvenMetal_Fields.pas       parameter-name -> canonical column mapping
  ProvenMetal_Grouping.pas     rows -> orderable lines (line_key, ref-ranges, DNP)
  ProvenMetal_Verdict.pas      local mirror of the server verdict rule
  ProvenMetal_Settings.pas     settings.json, %APPDATA% paths, sidecar
  ProvenMetal_Json.pas         JSON build + tolerant scalar reader
  ProvenMetal_Client.pas       bridge to the PowerShell helper
  ProvenMetal_UI.pas           results dialog, progress, errors, browser, log
  ProvenMetal_Writeback.pas    optional: write PM_* params onto components
  helper/pm_client.ps1         config / login / push / latest / logout
```

## Requirements

- Altium Designer (Windows). Uses the Design Manager (Workspace Manager) API and
  the Schematic API, both present in current Altium versions.
- Windows PowerShell 5.1 (bundled with Windows) or PowerShell 7.
- Access to a ProvenMetal Central instance.

## Install

### One command (recommended, esp. on Parallels)

From Windows, run the bundled installer against this repo. It copies the plugin to
a local folder (don't run it off a Parallels/network share) and unblocks the files
so the PowerShell helper can run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

It installs to `C:\ProvenMetal\provenmetal-altium\plugin` by default (override with
`-Dest "D:\path"`) and prints the exact `ProvenMetal.PrjScr` path to open. Then do
step 2 below.

### Manual

1. Copy the `plugin/` folder to a local Windows path (e.g.
   `C:\ProvenMetal\provenmetal-altium\plugin\`). Keep `helper\pm_client.ps1`
   alongside the `.pas` files. If it came from a shared folder, unblock it:
   `Get-ChildItem -Recurse C:\ProvenMetal\provenmetal-altium\plugin | Unblock-File`.
2. In Altium: **File > Open Project…** and choose `ProvenMetal.PrjScr`. It appears
   in the Projects panel and its scripts become runnable.
3. Run it: **DXP (or the top-left menu) > Run Script…**, pick `ProvenMetal_Main.pas`
   > `SourceWithProvenMetal`.

Optional — add a toolbar/menu button: **DXP > Customize…**, find the script under
the *Scripts* category, and drag it onto a toolbar so it runs in one click.

If you install the scripts globally (Preferences > System > Scripting) instead of
opening the project, the plugin can't auto-locate the helper; set `helper_path` in
`settings.json` (see below) or copy `pm_client.ps1` into the settings folder.

## First run

1. Open your PCB project and make it the focused project.
2. Run `SourceWithProvenMetal`. A browser opens for sign-in the first time; the
   token is cached and refreshed after that.
3. The BOM is pushed and sourced, a summary dialog appears, and the full report
   opens in your browser.

You can also sign in ahead of time with the `ProvenMetalLogin` entry point.

## Settings

The only setting most people touch is the ProvenMetal Central URL, which defaults
to `https://central.provenmetal.com`. Everything for sign-in is fetched from the
server. Settings live at:

```
%APPDATA%\provenmetal-altium\settings.json
```

```jsonc
{
  "base_url": "https://central.provenmetal.com",
  "oauth_provider": "google",
  "board_count": 10,            // default build quantity (drives "in stock >= build qty")
  "exclude_dnp": true,          // drop not-fitted / No-BOM parts
  "writeback": false,           // write results into schematic parameters (see below)
  "writeback_field_prefix": "PM",
  "helper_path": "",            // set only if auto-discovery of pm_client.ps1 fails
  "field_map": {                // set if your schematic uses non-standard names
    "mpn": "Manufacturer Part Number",
    "lcsc": "LCSC Part #"
  }
}
```

Set the URL without editing the file via the `ProvenMetalSetBaseUrl` entry point.

### Parameter names detected automatically

Sourcing matches on **MPN** or **LCSC**; Digikey and Mouser numbers are kept as
extra data. These parameter names are recognised out of the box (pin exact names
with `field_map` if yours differ):

- MPN: `MPN`, `Manufacturer Part Number`, `MFR#`, `Mfr Part #`, `Part Number`
- Manufacturer: `Manufacturer`, `Mfr`, `MFN`, `Mfg`
- LCSC: `LCSC`, `LCSC Part #`, `LCSC Part Number`, `JLCPCB Part #`
- Digikey: `Digikey`, `Digi-Key`, `DigiKey Part Number`, `DK Part #`
- Mouser: `Mouser`, `Mouser Part Number`, `Mouser #`

The **value** comes from the component Comment (or a `Value` parameter), the
**footprint** from the current footprint, and the **description** from the
component Description. Value + description let the server source passives that have
no MPN (e.g. "10 uF 16V X5R 0603").

## Sourcing without MPNs

Most schematics don't carry manufacturer part numbers, and that's fine. The plugin
sends the value, footprint and description, and the server sources passives from
those. Parts that genuinely can't be identified (no MPN, LCSC, or usable value)
come back as **review** — the signal that they need a part number.

## Project link

The link between an Altium project and its ProvenMetal project is stored in
`<project>.provenmetal.json` next to the project file. It's safe to commit.

## Writeback (optional)

Set `"writeback": true` to write `PM_Status`, `PM_Stock`, `PM_Lead_Days`,
`PM_Supplier` and `PM_Checked` onto each schematic component (matched by
designator), as hidden parameters, in one undoable transaction. It is best-effort
and never blocks the sourcing result.

## Assembly variants

If a project variant is active, components that are **Not Fitted** in that variant
are treated as DNP (dropped when `exclude_dnp` is true). "Standard (No BOM)",
graphical and net-tie components are always excluded.

## Sign-in details (server side)

Same contract as the KiCad plugin. The server must:

1. Serve `GET /api/kicad/config`, accept `POST /api/kicad/bom` and
   `GET /api/kicad/bom/[projectId]` (bearer token).
2. Allow-list these Supabase Auth redirect URLs for the desktop sign-in:
   ```
   http://127.0.0.1:53682/callback
   http://127.0.0.1:53683/callback
   http://127.0.0.1:53684/callback
   http://127.0.0.1:8976/callback
   ```

## Troubleshooting

- **"Could not find helper\pm_client.ps1"** — open `ProvenMetal.PrjScr` as a
  project, or set `helper_path` in `settings.json`.
- **"Compile the project…"** — Project > Compile, then run again.
- **Sign-in window doesn't return** — check that the loopback redirect URLs above
  are on the Supabase allow-list.
- **Logs** — `%APPDATA%\provenmetal-altium\last-run.log`, and the raw request /
  result files in the same folder.

## Running the helper standalone (dev)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File plugin\helper\pm_client.ps1 -Command login
powershell -NoProfile -ExecutionPolicy Bypass -File plugin\helper\pm_client.ps1 -Command config
powershell -NoProfile -ExecutionPolicy Bypass -File plugin\helper\pm_client.ps1 -Command logout
```
