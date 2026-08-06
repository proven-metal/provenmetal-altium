# ProvenMetal for Altium Designer

Checks your BOM against real distributor stock, from inside Altium. One click:
it reads the compiled BOM of the focused project, sources every line, and tells
you which parts are in stock for your build quantity — before you order boards.

- **pass** — in stock for the whole build, or lead time within 7 days
- **review** — not enough data to decide (usually: no part number)
- **fail** — out of stock everywhere, or a long/unknown lead time

The verdict shows in a window in Altium; a full report opens in your browser.

## Install

Windows, Altium Designer. In PowerShell:

```powershell
irm https://raw.githubusercontent.com/proven-metal/provenmetal-altium/main/install.ps1 | iex
```

Restart Altium. Done — no admin rights, no build tools. The script downloads
the latest release and registers it with Altium.

Prefer to see what you're running? Download the zip from
[Releases](https://github.com/proven-metal/provenmetal-altium/releases),
extract, and run the `install.ps1` inside.

Uninstall: `.\install.ps1 -Uninstall`

## Use

1. Open your PCB project, and open a schematic or the PCB (the command lives in
   the editor's menus).
2. **Tools → Source with ProvenMetal**.
3. First run: a browser opens to sign in. After that it's cached.
4. Read the verdict; **Open report** has the full per-part breakdown.

Build quantity defaults to 1 board. Set `board_count` in settings (below); it's
remembered per project after the first push.

If it says it can't read the BOM, run **Project → Validate** (compile) once and
try again.

### Part numbers

Sourcing matches on **MPN** or **LCSC**. These parameter names are picked up
automatically:

- MPN: `MPN`, `Manufacturer Part Number`, `MFR#`, `Mfr Part #`, `Part Number`
- Manufacturer: `Manufacturer`, `Mfr`, `MFN`, `Mfg`
- LCSC: `LCSC`, `LCSC Part #`, `LCSC Part Number`, `JLCPCB Part #`
- Digikey / Mouser part numbers are carried along as metadata.

No MPNs in your schematic? Fine — value + footprint + description is enough to
source passives ("10uF 16V X5R 0603" finds a real part). Parts that can't be
identified at all come back as **review**, which is your signal to add a part
number.

If your library uses different parameter names, pin them with `field_map` in
settings.

## What gets sent

Designators, values, footprints, descriptions, quantities, and any
MPN / Manufacturer / LCSC / Digikey / Mouser parameters from the focused
project. Nothing else — no netlists, no geometry, no files. The link between
your project and its report is a small `<project>.provenmetal.json` next to
your project file; it's safe to commit.

## Settings

`%APPDATA%\provenmetal-altium\settings.json` — all keys optional:

```jsonc
{
  "base_url": "https://central.provenmetal.com",
  "board_count": 10,
  "exclude_dnp": true,                    // drop parts a variant marks Not Fitted
  "field_map": { "mpn": "PartNumber" },   // your parameter name -> canonical column
  "debug": false                          // verbose per-component logging
}
```

Log file: `%APPDATA%\provenmetal-altium\last-run.log`

## Troubleshooting

- **"Compile the project"** — Project → Validate (Compile PCB Project), run again.
- **No menu item** — open a schematic/PCB document first; the Home page has no
  Tools menu. Confirm "ProvenMetal" is listed under Extensions and Updates →
  Installed.
- **Sign-in never completes** — the login uses a localhost callback on ports
  53682/53683/53684/8976; a proxy or firewall that blocks those will stall it.
- Anything else: check the log above, then open an issue with its tail.

## Building from source

The extension is C# (.NET Framework 4.8) in `extension/`. `Build.ps1` copies the
two SDK DLLs out of your Altium install and builds with MSBuild — see
[extension/README.md](extension/README.md).

There is also a script-only edition in `plugin/` (DelphiScript + a PowerShell
helper) that needs no compiler at all: [plugin/README.md](plugin/README.md).

Want to try it without a real design? `sample/MakeSampleBom.pas` drops six test
components with part numbers onto a blank schematic.

## Server

Talks to ProvenMetal Central over HTTPS — the same `/api/kicad/*` API as our
[KiCad plugin](https://github.com/proven-metal/provenmetal-kicad). Run your own
instance? Point `base_url` at it.

## License

MIT
