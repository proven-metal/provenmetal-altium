This folder holds the two Altium SDK assemblies the build references:

    Altium.SDK.dll
    Altium.SDK.Interfaces.dll

They are NOT committed and NOT shipped in the extension - Altium provides them at
runtime. Build.ps1 copies them here automatically from your Altium installation
(C:\Program Files\Altium\AD<version>\). If auto-detection fails, copy those two
DLLs here by hand and re-run Build.ps1.
