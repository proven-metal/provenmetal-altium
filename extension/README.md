# Building the ProvenMetal Altium extension

Users don't need any of this — `install.ps1` at the repo root installs the
prebuilt release. This is for working on the extension itself.

## Prerequisites

- Windows with Altium Designer installed (the build borrows two SDK DLLs from it)
- Visual Studio 2019/2022 or Build Tools for Visual Studio, with the
  ".NET desktop build tools" workload
- Internet on first build (NuGet pulls Newtonsoft.Json)

## Build → deploy

```powershell
cd extension
powershell -ExecutionPolicy Bypass -File Build.ps1      # copies SDK DLLs, builds Release
powershell -ExecutionPolicy Bypass -File Package.ps1    # stages dist\
powershell -ExecutionPolicy Bypass -File Deploy.ps1     # installs into Altium + registers
```

Restart Altium. The command appears as **Tools → Source with ProvenMetal** in
the schematic and PCB editors.

`Build.ps1 -Writeback` also compiles the optional schematic writeback
(`PM_WRITEBACK` symbol) — the schematic-editing API is the least-verified
surface, so it's off by default.

`sign.ps1` Authenticode-signs `dist\ProvenMetal.dll` if you have a cert.

## Cutting a release

```powershell
powershell -ExecutionPolicy Bypass -File release.ps1        # -> ProvenMetal-Altium-v<ver>.zip
gh release create v<ver> ProvenMetal-Altium-v<ver>.zip --title "v<ver>" --notes "..."
```

The root `install.ps1` downloads the latest `ProvenMetal-Altium-*.zip` release
asset, so publishing the zip is all it takes.

## Layout

```
ProvenMetal/
  PluginFactory.cs        COM entry Altium calls to load the module
  ProvenMetalModule.cs    registers the SourceBom command, orchestrates a run
  ProvenMetal.Ins/.rcs    extension manifest + menu wiring
  Altium/                 workspace access, BOM extraction (DM API), writeback
  Core/                   field mapping, line grouping, verdict, models
  Central/                settings, Supabase PKCE auth, HTTP client
  UI/ResultsForm.cs       progress/results window
```

Notes: the `DM_*` Design Manager members are methods in the C# SDK (call with
`()`); component parameters are read by iterating `DM_ParameterCount()` /
`DM_Parameters(i)`. The MSB3277 version-unification warnings during build are
expected (Altium.SDK references newer framework facades) and harmless.
