; Inno Setup script for the ProvenMetal Altium extension.
;
; Produces a conventional "double-click -> Next -> Finish" Windows installer that
; bundles the built extension payload (ProvenMetal.dll, manifests, Newtonsoft.Json)
; and the repo's install.ps1, then runs install.ps1 to copy the files into Altium's
; Extensions folder and register them in ExtensionsRegistry.xml - i.e. the exact
; same, tested install path as the one-line PowerShell installer, just wrapped in a
; GUI. Uninstall runs install.ps1 -Uninstall so Altium is properly de-registered.
;
; Build it with extension\installer\Build-Installer.ps1 (locates ISCC, passes the
; version, and optionally code-signs the result).

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#define MyAppName "ProvenMetal for Altium"
#define MyAppPublisher "ProvenMetal"
#define MyAppURL "https://github.com/proven-metal/provenmetal-altium"

[Setup]
; A stable, installer-specific AppId (distinct from the extension's own GUID).
AppId={{7F3E2A11-2C4D-4B8E-9A1F-3D6C8E0B2A44}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
; Staging dir for the payload; the real install target is Altium's Extensions folder.
DefaultDirName={autopf}\ProvenMetal Altium
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=no
Uninstallable=yes
OutputDir=.
OutputBaseFilename=ProvenMetal-Altium-Setup-v{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; No admin needed - install.ps1 writes to the per-machine Altium Extensions folder,
; which Altium provisions writable; matches the no-admin one-line installer.
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
SetupLogging=yes

[Messages]
WelcomeLabel2=This will install [name] into Altium Designer.%n%nClose Altium Designer before continuing - it locks the extension files while running.

[Files]
Source: "..\dist\ProvenMetal.dll";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\ProvenMetal.Ins";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\ProvenMetal.rcs";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\Newtonsoft.Json.dll";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\ProvenMetal.pdb";        DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\..\install.ps1";              DestDir: "{app}"; Flags: ignoreversion

[Run]
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"""; \
  StatusMsg: "Registering the extension with Altium Designer..."; \
  Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -Uninstall"; \
  Flags: runhidden waituntilterminated; RunOnceId: "ProvenMetalUnregister"

[Code]
// True if Altium Designer (X2.exe) is currently running - it locks ProvenMetal.dll.
function IsAltiumRunning(): Boolean;
var
  ResultCode: Integer;
begin
  // "tasklist | find" exits 0 only when a matching line is found.
  Result := Exec(ExpandConstant('{cmd}'),
    '/C tasklist /FI "IMAGENAME eq X2.exe" | find /I "X2.exe"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

// Block the install while Altium is open; let the user close it and retry.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  while IsAltiumRunning() do
  begin
    if MsgBox('Altium Designer is running and must be closed before ProvenMetal can be installed '
      + '(it holds the extension files open).' + #13#10#13#10
      + 'Close Altium Designer, then click Retry.',
      mbError, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := 'Setup was cancelled because Altium Designer was still running.';
      Exit;
    end;
  end;
end;
