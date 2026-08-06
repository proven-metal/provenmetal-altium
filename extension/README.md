# ProvenMetal — Altium Designer extension (C#)

A compiled Altium Designer extension that reads a project's BOM, pushes it to
**ProvenMetal Central** for sourcing, and flags anything that isn't in stock for
the full build or sourceable within one week.

This is the **recommended** way to ship ProvenMetal for Altium. It installs like
any Altium add-in (appears in **Extensions & Updates**), adds a **Source with
ProvenMetal** command to the Schematic and PCB **Tools** menus, and does
everything in‑process: BOM read, HTTPS + Supabase PKCE sign‑in, and the results
window. No DelphiScript, no PowerShell helper. It talks to the same
`/api/kicad/*` endpoints as the KiCad plugin, so no server changes are needed.

> The DelphiScript version under `../plugin/` still works and needs no build
> toolchain, but this compiled extension is the cleaner product.

## What you need to build it (once, in the Windows VM)

- Altium Designer installed (the build borrows two SDK DLLs from it).
- **Visual Studio 2019/2022** or **Build Tools for Visual Studio** (for MSBuild).
- Internet access on first build (NuGet restores Newtonsoft.Json).
- Optional: a code‑signing certificate (`signtool`).

## Build → package → deploy

From `extension\` in a Windows PowerShell prompt:

```powershell
powershell -ExecutionPolicy Bypass -File Build.ps1      # copies SDK DLLs + builds Release
powershell -ExecutionPolicy Bypass -File Package.ps1    # stages dist\ (dll, .Ins, .rcs, Newtonsoft)
powershell -ExecutionPolicy Bypass -File sign.ps1       # optional: Authenticode-sign dist\ProvenMetal.dll
powershell -ExecutionPolicy Bypass -File Deploy.ps1     # installs into Altium + registers it
```

Then **restart Altium**. Open a schematic or PCB and run **Tools → Source with
ProvenMetal** (also in the main Schematic/PCB menus). Confirm it's listed under
**Extensions & Updates → Installed**.

To distribute to other users, ship the `dist\` folder plus `Deploy.ps1`; they run
`Deploy.ps1` and restart Altium. (A single self‑extracting installer can wrap
that later.)

## How it works

```
ProvenMetal (extension DLL)
  PluginFactory            COM entry Altium calls to load the server module
  ProvenMetalModule        registers the "SourceBom" command (wired by ProvenMetal.rcs)
  Altium/AltiumApi         Client + Workspace (Design Manager) access
  Altium/BomExtractor      compile + flattened BOM via DM_* interfaces
  Altium/Writeback         optional PM_* params back onto components (see below)
  Core/Fields|Grouping|Verdict   parameter mapping, line grouping, verdict mirror
  Central/Settings         settings.json (%APPDATA%\provenmetal-altium) + sidecar
  Central/Auth             Supabase loopback‑PKCE sign‑in, token cache/refresh
  Central/CentralClient    GET /api/kicad/config, POST /api/kicad/bom
  UI/ResultsForm           branded WinForms window with live progress
```

The command opens the branded window immediately, reads + groups the BOM on the
UI thread, then does sign‑in + push on a background thread (window stays live),
and fills in the verdict. The report also opens in your browser.

## Settings

`%APPDATA%\provenmetal-altium\settings.json` (all keys optional):

```jsonc
{
  "base_url": "https://central.provenmetal.com",
  "oauth_provider": "google",
  "board_count": 10,
  "exclude_dnp": true,
  "writeback": false,
  "writeback_field_prefix": "PM",
  "field_map": { "mpn": "Manufacturer Part Number", "lcsc": "LCSC Part #" }
}
```

Sourcing matches on MPN or LCSC; value + footprint + description let the server
source passives with no MPN. The Altium ↔ Central link is stored in
`<project>.provenmetal.json` next to the project (safe to commit). Supabase Auth
must allow‑list the loopback redirects `http://127.0.0.1:{53682,53683,53684,8976}/callback`.

## Writeback (optional, compile flag)

Writing `PM_Status`/`PM_Stock`/`PM_Lead_Days`/`PM_Supplier`/`PM_Checked` back onto
schematic components uses the schematic‑editing API, which is the least‑verified
C# surface. It's therefore gated behind the `PM_WRITEBACK` compile symbol and off
by default so the core extension always builds. To enable and finalize it:

```powershell
powershell -ExecutionPolicy Bypass -File Build.ps1 -Writeback
```

Then set `"writeback": true` in settings.json. If the SCH iterator/parameter calls
need adjusting for your Altium version, they're isolated in `Altium/Writeback.cs`.

## Notes / risks

Built and reviewed on macOS, so it hasn't been compiled here. The most likely
first‑build fixups are the exact shapes of a few Design Manager members in
`Altium/BomExtractor.cs` (property vs method) — they're centralized there on
purpose. The plugin‑loading skeleton, SCH parameter API, and packaging mirror a
current shipping C# extension.

Logs: `%APPDATA%\provenmetal-altium\last-run.log`.
