# ProvenMetal for Altium Designer

Checks your BOM against real distributor stock without leaving Altium. It reads
the compiled BOM of the focused project, sources every line, and tells you which
parts are actually available for your build quantity before you order boards.

Each part gets one of three verdicts:

- **pass**: in stock for the whole build, or lead time within 7 days
- **review**: not enough data to decide (usually a missing part number)
- **fail**: out of stock everywhere, or a long/unknown lead time

The summary shows up in a window inside Altium, and a full report opens in your
browser.

## Install

You'll need Windows and Altium Designer. Run this in PowerShell:

```powershell
irm https://raw.githubusercontent.com/proven-metal/provenmetal-altium/main/install.ps1 | iex
```

Restart Altium and you're done. There's no admin rights or build tools needed;
the script grabs the latest release and registers it with Altium.

If you'd rather see what you're running first, download the zip from
[Releases](https://github.com/proven-metal/provenmetal-altium/releases), extract
it, and run the `install.ps1` inside.

To uninstall, run `.\install.ps1 -Uninstall`.

## Use

1. Open your PCB project, then open a schematic or the PCB (the command lives in
   the editor menus).
2. Go to **Tools → Source with ProvenMetal**.
3. The first run opens a browser to sign in. After that it's cached.
4. Read the verdict. **Open report** has the full per-part breakdown.

Build quantity defaults to 1 board. Set `board_count` in settings (see below);
it's remembered per project after the first push.

If it says it can't read the BOM, run **Project → Validate** (compile) once and
try again.

### Part numbers

Sourcing matches on MPN or LCSC. These parameter names are picked up
automatically:

- MPN: `MPN`, `Manufacturer Part Number`, `MFR#`, `Mfr Part #`, `Part Number`
- Manufacturer: `Manufacturer`, `Mfr`, `MFN`, `Mfg`
- LCSC: `LCSC`, `LCSC Part #`, `LCSC Part Number`, `JLCPCB Part #`
- Digikey and Mouser part numbers are carried along as metadata.

You don't strictly need MPNs in your schematic. Value, footprint, and
description are enough to source passives, so "10uF 16V X5R 0603" will find a
real part. Anything that can't be identified comes back as **review**, which is
your cue to add a part number.

If your library uses different parameter names, map them with `field_map` in
settings.

## What gets sent

Designators, values, footprints, descriptions, quantities, and any
MPN / Manufacturer / LCSC / Digikey / Mouser parameters from the focused
project. That's it: no netlists, no geometry, no files. The link between your
project and its report is a small `<project>.provenmetal.json` next to your
project file, and it's safe to commit.

## Settings

Settings live in `%APPDATA%\provenmetal-altium\settings.json`, and every key is
optional:

```jsonc
{
  "base_url": "https://central.provenmetal.com",
  "board_count": 10,
  "exclude_dnp": true,                    // drop parts a variant marks Not Fitted
  "field_map": { "mpn": "PartNumber" },   // your parameter name -> canonical column
  "debug": false                          // verbose per-component logging
}
```

The log file is at `%APPDATA%\provenmetal-altium\last-run.log`.

## Troubleshooting

- **"Compile the project"**: run Project → Validate (Compile PCB Project), then
  try again.
- **No menu item**: open a schematic or PCB document first, since the Home page
  has no Tools menu. Also confirm "ProvenMetal" is listed under Extensions and
  Updates → Installed.
- **Sign-in never completes**: the login uses a localhost callback on ports
  53682/53683/53684/8976, so a proxy or firewall that blocks those will stall
  it.
- Anything else: check the log above, then open an issue with its tail.

## Building from source

The extension is C# (.NET Framework 4.8) in `extension/`. `Build.ps1` copies the
two SDK DLLs out of your Altium install and builds with MSBuild. See
[extension/README.md](extension/README.md) for details.

There's also a script-only edition in `plugin/` (DelphiScript plus a PowerShell
helper) that needs no compiler at all: [plugin/README.md](plugin/README.md).

To try it without a real design, `sample/MakeSampleBom.pas` drops six test
components with part numbers onto a blank schematic.

## Server

It talks to ProvenMetal Central over HTTPS, using the same `/api/kicad/*` API as
our [KiCad plugin](https://github.com/proven-metal/provenmetal-kicad). If you run
your own instance, point `base_url` at it.

## License

MIT
