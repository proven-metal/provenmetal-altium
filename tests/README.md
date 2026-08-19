# Tests

Unit tests for the port-critical, CAD-independent core logic — the verdict rule,
field-name mapping, and BOM row grouping. They are the C# counterpart of the
KiCad plugin's `tests/` and assert identical behaviour so the two plugins stay in
sync.

## Why they run without Altium

The extension proper (`../extension/`) targets .NET Framework 4.8 and references
Altium's proprietary SDK DLLs, so it can only be built on Windows with Altium
installed. The logic under test, however, only touches the BCL, so
`ProvenMetal.Core.Tests` links those source files directly
(`extension/ProvenMetal/Core/*.cs`) and targets `net8.0`. That means the tests
build and run anywhere the .NET SDK is present — dev laptop or Linux CI — with no
Altium and no Windows.

## Run

With the [.NET SDK](https://dotnet.microsoft.com/download) (8.0+) installed:

```sh
dotnet test tests/ProvenMetal.Core.Tests/ProvenMetal.Core.Tests.csproj
```

CI runs the same command on every push / PR to `main`
(`.github/workflows/ci.yml`).

## Coverage

- `VerdictTests` — pass / review / fail decision (`Core/Verdict.cs`).
- `FieldsTests` — canonical column candidate lists + `field_map` override
  (`Core/Fields.cs`).
- `GroupingTests` — rows → orderable lines: DNP/empty dropping, MPN/LCSC/value
  line-key precedence, duplicate merging, reference-range expansion, distributor
  metadata (`Core/Grouping.cs`). Exercises both a small inline scenario and the
  shared `FlightControllerV1_MPN.csv` BOM fixture.

`fixtures/FlightControllerV1_MPN.csv` is copied from the KiCad plugin so both
suites grind the same real-world BOM.
