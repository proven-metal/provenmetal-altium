# ProvenMetal Altium Plugin — Specification

An Altium Designer plugin that reads a project's BOM, pushes it to **ProvenMetal
Central**, has it sourced server-side (via the "Bob" sourcing service), and reports
whether every part is **in stock somewhere or sourceable within one week** — so
long-lead parts get flagged proactively and the BOM can be pre-sourced.

This is a port of the ProvenMetal KiCad plugin to Altium. The server contract is
unchanged; only the CAD-side implementation differs.

---

## 1. Goal & scope

- Extract the BOM from the **focused Altium project** (compiled, flattened).
- Push it to ProvenMetal Central over an authenticated API.
- Central sources each line through Bob (Digikey / Mouser / LCSC identity), then
  computes a per-line **verdict**.
- Pull the verdict back and show a pass / needs-review / fail summary in the
  plugin, with a link to the full web report.
- Optional: write the verdict back into schematic component parameters.

---

## 2. Confirmed product decisions

| Area          | Decision |
|---------------|----------|
| CAD target    | Altium Designer (Windows). |
| Implementation| **DelphiScript** script project (`.PrjScr` + `.pas`); no SDK/compiler. |
| BOM source    | The compiled, flattened project via the **Design Manager API** (`DM_DocumentFlattened` -> `DM_Components`), which does hierarchy/multi-channel expansion. Field values via `DM_GetParameterByName`. |
| Backend       | Talk to **provenmetal-central** only (never Bob directly). Same `/api/kicad/*`. |
| Auth          | Loopback **PKCE -> Supabase user JWT**, run by a bundled PowerShell helper; bearer auth on `/api/kicad/*`. |
| Network/JSON  | Done in **PowerShell** (`pm_client.ps1`), which ships with Windows. DelphiScript builds JSON and reads a flat result file; it never parses JSON. |
| Data flow     | Push BOM -> server sources via Bob -> pull verdict back. |
| Writeback     | Opt-in write of `PM_Status`/`PM_Stock`/`PM_Lead_Days`/`PM_Supplier`/`PM_Checked` into schematic component parameters via the Schematic API. |
| Part identity | MPN (+manufacturer) or LCSC for sourcing; Digikey/Mouser PNs are metadata. |
| "In stock"    | `stock >= required build qty` (qty/board × boardCount). |
| DNP           | Not-fitted in the active variant, plus "Standard (No BOM)" / graphical / net-tie components. |

### Why the Design Manager (flattened) API and not raw schematic reads
`Project.DM_DocumentFlattened` gives the fully expanded, project-wide component
list (hierarchy + multi-channel), which is exactly what BOM sourcing needs. It is
the Altium analogue of `kicad-cli sch export bom` in the KiCad plugin: let the tool
do the flattening rather than reimplementing it over raw sheet reads.

### Why a PowerShell helper
DelphiScript can read the Altium design model but is weak at HTTPS + TLS, OAuth
PKCE (needs a loopback HTTP listener), and JSON. PowerShell (bundled with Windows)
does all three cleanly with `Invoke-WebRequest`, `System.Net.HttpListener` and
`ConvertTo/From-Json`. This mirrors the KiCad plugin shelling out to `kicad-cli`,
and keeps the exact same server contract (no server changes).

---

## 3. Architecture

```
Altium Designer (focused project)
  └─ Run Script action "SourceWithProvenMetal"  (DelphiScript)
       1. GetWorkspace.DM_FocusedProject; compile; DM_DocumentFlattened
       2. iterate DM_Components -> rows (designator, comment, footprint, MPN, Mfr,
          LCSC, Digikey, Mouser); honour variant fitted-state + "No BOM"
       3. group rows -> orderable lines (line_key), drop DNP
       4. write request.json; launch helper (hidden, async); poll for result.txt
       5. show verdict dialog + open report; optional writeback

pm_client.ps1 (bundled PowerShell helper)
       a. GET  /api/kicad/config              supabase url + anon key for PKCE
       b. loopback PKCE -> Supabase user JWT  (cached at %APPDATA%\provenmetal-altium)
       c. POST /api/kicad/bom                 push + source + verdict (round trip)
       d. write <project>.provenmetal.json sidecar; write flat result.txt

provenmetal-central (unchanged)
       GET  /api/kicad/config              (public)
       POST /api/kicad/bom                 (bearer) push + source + verdict
       GET  /api/kicad/bom/[projectId]     (bearer) latest verdict + lines
```

---

## 4. Verdict logic (server-side, authoritative)

Per line, after Bob returns `stock` + `lead_time_days`:

- `required_qty  = quantity_per_board × boardCount`
- `in_stock      = stock != null && stock >= required_qty`
- `sourceable_1w = lead_time_days != null && lead_time_days <= 7`
- `PASS   = in_stock || sourceable_1w`
- `REVIEW = !PASS && (source_status == 'manual' || no data)`
- `FAIL   = otherwise`

A project passes overall when every non-DNP line is `PASS`. `ProvenMetal_Verdict.pas`
mirrors this for local re-computation; the server value is authoritative.

---

## 5. API contract

### `GET /api/kicad/config`  (public)
```json
{ "supabaseUrl": "https://xxxx.supabase.co", "supabaseAnonKey": "sb_publishable_...",
  "appUrl": "https://central.provenmetal.com" }
```

### `POST /api/kicad/bom`  (Authorization: Bearer <supabase access token>)
```jsonc
{
  "projectId": "uuid | null",       // null on first push -> creates a design
  "name": "FlightControllerV1",
  "boardCount": 10,
  "clientVersion": "0.1.0",
  "lines": [{
    "line_key": "stm32h743vit6",
    "references": ["U1"],
    "mpn": "STM32H743VIT6",
    "manufacturer": "STMicroelectronics",
    "lcsc": "C123",
    "value": "MCU",
    "footprint": "LQFP-100",
    "description": "...",
    "quantity_per_board": 1,
    "digikey": "497-...",
    "mouser": "511-..."
  }]
}
```
Response (see the KiCad plugin SPEC for full shape): `{ projectId, revisionId,
reportUrl, status, summary:{total,pass,review,fail}, lines:[{ line_key, reference,
mpn, verdict, reason, stock, leadTimeDays, requiredQty, supplier, sourceStatus }] }`.

### `GET /api/kicad/bom/[projectId]`  (bearer)
Latest `{ summary, lines, reportUrl, revisionId, updatedAt }`.

---

## 6. Helper result contract (PowerShell -> DelphiScript)

`pm_client.ps1` writes a flat, atomically-renamed `result.txt` that DelphiScript
reads without JSON parsing:

```
OK=1|0
ERROR=<message>                     (when OK=0)
STATUS=sourced|degraded|no-sourcing
PROJECT_ID / REF / REPORT_URL
SUMMARY_TOTAL / SUMMARY_PASS / SUMMARY_REVIEW / SUMMARY_FAIL
SOURCING_ERROR=<optional>
WARN=<optional, repeatable>
LINE=<line_key>\t<verdict>\t<reference>\t<part>\t<stock>\t<lead>\t<reqQty>\t<supplier>\t<sourceStatus>\t<reason>
```

---

## 7. Component -> canonical mapping

| Canonical    | Source in Altium |
|--------------|------------------|
| reference    | `IPart.DM_PhysicalDesignator` |
| value        | parameter `Comment`, then `Value` |
| footprint    | `IPart.DM_Footprint` |
| description  | `IPart.DM_Description`, then parameter `Description` |
| mpn          | parameters: MPN, Manufacturer Part Number, MFR#, Mfr Part #, Part Number |
| manufacturer | parameters: Manufacturer, Mfr, MFN, Mfg |
| lcsc         | parameters: LCSC, LCSC Part #, LCSC Part Number, JLCPCB Part # |
| digikey      | parameters: Digikey, Digi-Key, DigiKey Part Number, DK Part # |
| mouser       | parameters: Mouser, Mouser Part Number, Mouser # |

`field_map` in `settings.json` pins an exact parameter name per canonical column.

---

## 8. Known risks / assumptions

- PowerShell is present on Windows; `System.Net.HttpListener` on
  `http://127.0.0.1:<port>/` works for a standard user (no admin/urlacl needed).
- The project must be compilable; the plugin compiles it before reading the
  flattened BOM.
- Bob sources on MPN/LCSC (and value/description for passives); parts lacking all
  of these come back `review`/`fail`.
- Sourcing runs synchronously (~up to 60s) inside `POST /api/kicad/bom`; the plugin
  shows a progress window and polls for the result.
- Writeback and full variant handling are best-effort and non-fatal.
