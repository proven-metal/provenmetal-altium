{..............................................................................}
{ ProvenMetal_Main.pas                                                           }
{                                                                              }
{ Entry points for the ProvenMetal Altium plugin. Run these from DXP -> Run      }
{ Script (or bind them to a menu/toolbar button, or the Panels -> Scripts panel).}
{                                                                              }
{   SourceWithProvenMetal   - the main action: read the BOM, push it to          }
{                             ProvenMetal Central, show the sourcing verdict.     }
{   ProvenMetalLogin        - sign in (opens your browser) and cache the token.   }
{   ProvenMetalLogout       - clear the cached credentials.                       }
{   ProvenMetalSetBaseUrl   - set the ProvenMetal Central base URL.               }
{                                                                              }
{ Orchestration mirrors the KiCad plugin's core.run(): extract -> group ->        }
{ authenticate+push (in PowerShell) -> show verdict -> optional writeback.        }
{..............................................................................}


{ Read a helper result file into a TStringList (nil if missing). }
function PM_ReadResultFile(const Path : String) : TStringList;
begin
    Result := nil;
    if not FileExists(Path) then Exit;
    Result := TStringList.Create;
    try
        Result.LoadFromFile(Path);
    except
        Result.Free;
        Result := nil;
    end;
end;


procedure SourceWithProvenMetal;
var
    Settings    : TStringList;
    Project     : IProject;
    projFull    : String;
    projDir     : String;
    projName    : String;
    helper      : String;
    pluginDir   : String;
    logoPath    : String;
    rows        : TStringList;
    lines       : TStringList;
    boardCount  : Integer;
    projectId   : String;
    requestJson : String;
    reqFile     : String;
    resFile     : String;
    progFile    : String;
    cmd         : String;
    ok          : Boolean;
    R           : TStringList;
    wbCount     : Integer;
begin
    PM_Log('=== SourceWithProvenMetal invoked ===');
    Settings := PM_LoadSettings;
    rows := nil;
    lines := nil;
    R := nil;

    { Outer try/finally guarantees cleanup even on the early Exit calls below;   }
    { inner try/except turns any unexpected failure into a friendly message.     }
    try
      try
        Project := PM_GetFocusedProject;
        if Project = nil then
        begin
            PM_ShowError('No focused project. Open a PCB project in Altium and try again.');
            Exit;
        end;

        projFull := Project.DM_ProjectFullPath;
        projDir  := ExtractFilePath(projFull);
        projName := ChangeFileExt(ExtractFileName(projFull), '');
        PM_Log('project=' + projName + ' dir=' + projDir);

        helper := PM_HelperPath(Settings);
        if helper = '' then
        begin
            PM_ShowError('Could not find helper\pm_client.ps1. Open ProvenMetal.PrjScr as a ' +
                'project (recommended), or set "helper_path" in settings.json.');
            Exit;
        end;

        { --- open the branded window immediately (live progress) ----------- }
        pluginDir := PM_LocatePluginDir(Settings);
        logoPath := PM_EnsureTrailingSlash(pluginDir) + 'resources\icon_48.png';
        PM_WinOpen('Reading the BOM from ' + projName + ' ...', logoPath);
        PM_WinLog('Project: ' + projName);

        { --- BOM extraction ------------------------------------------------ }
        rows := PM_ExtractBom(Project, Settings);
        if rows = nil then
        begin
            PM_WinFinishError('Could not read the flattened BOM. Compile the project ' +
                '(Project > Compile) and try again.');
            PM_WinInteract;
            Exit;
        end;

        lines := PM_GroupRows(rows, PM_SettingBool(Settings, 'exclude_dnp'));
        PM_FreeCollection(rows); rows := nil;

        if lines.Count = 0 then
        begin
            PM_WinFinishError('No orderable parts found (every component lacked an MPN, ' +
                'LCSC code and value, or all were DNP / No-BOM).');
            PM_WinInteract;
            Exit;
        end;
        PM_WinLog('Found ' + IntToStr(lines.Count) + ' orderable part(s).');

        { --- resolve board count + linked project id ----------------------- }
        boardCount := PM_SidecarBoardCount(projDir, projName,
            StrToIntDef(Settings.Values['board_count'], 1));
        if boardCount < 1 then boardCount := 1;
        projectId := PM_SidecarProjectId(projDir, projName);

        { --- build request + call the helper (auth + push + source) -------- }
        requestJson := PM_BuildRequestJson(projName, boardCount, projectId, lines);
        reqFile  := PM_SettingsDir + 'request.json';
        resFile  := PM_SettingsDir + 'result.txt';
        progFile := PM_SettingsDir + 'progress.txt';
        PM_WriteFileText(reqFile, requestJson);

        PM_WinStatus('Sourcing ' + IntToStr(lines.Count) + ' part(s) for ' +
            IntToStr(boardCount) + ' board(s) ...');
        PM_WinLog('Pushing to ProvenMetal Central (a browser may open for sign-in) ...');

        cmd := PM_HelperCmd(helper, 'push') +
            ' -Request "' + reqFile + '"' +
            ' -Result "' + resFile + '"' +
            ' -Progress "' + progFile + '"' +
            ' -ProjectDir "' + PM_NoTrailingSlash(projDir) + '"' +
            ' -ProjectName "' + projName + '"' +
            ' -BoardCount ' + IntToStr(boardCount);

        ok := PM_RunHelperPush(cmd, resFile, progFile, 360);

        { user closed the window mid-run: nothing more to show }
        if not PM_WinAlive then Exit;

        if not ok then
        begin
            PM_WinFinishError('The sourcing helper did not respond in time. See the log at ' +
                PM_SettingsDir + 'last-run.log');
            PM_WinInteract;
            Exit;
        end;

        R := PM_ReadResultFile(resFile);
        if R = nil then
        begin
            PM_WinFinishError('The sourcing helper produced no readable result.');
            PM_WinInteract;
            Exit;
        end;

        if R.Values['OK'] = '0' then
        begin
            PM_WinFinishError(R.Values['ERROR']);
            PM_WinInteract;
            Exit;
        end;

        { --- optional writeback ------------------------------------------- }
        if PM_SettingBool(Settings, 'writeback') then
        begin
            try
                wbCount := PM_ApplyWriteback(Project, lines, R,
                    Settings.Values['writeback_field_prefix']);
                PM_WinLog('Wrote sourcing results into ' + IntToStr(wbCount) + ' component(s).');
            except
                PM_WinLog('Writeback skipped (error).');
            end;
        end;

        { open the web report immediately (reliable), then fill the window }
        if R.Values['REPORT_URL'] <> '' then PM_OpenUrl(R.Values['REPORT_URL']);
        PM_WinFinishOk(R);
        PM_WinInteract;

      except
        { last-resort guard: report inside the window if it's up, else a dialog }
        if PM_WinAlive then
        begin
            PM_WinFinishError('Unexpected error. See ' + PM_SettingsDir + 'last-run.log');
            PM_WinInteract;
        end
        else
            PM_ShowError('Unexpected error. See ' + PM_SettingsDir + 'last-run.log');
        PM_Log('SourceWithProvenMetal raised an exception');
      end;
    finally
        PM_WinClose;
        if rows <> nil then PM_FreeCollection(rows);
        if lines <> nil then PM_FreeCollection(lines);
        if R <> nil then R.Free;
        Settings.Free;
    end;
end;


procedure ProvenMetalLogin;
var
    Settings : TStringList;
    helper   : String;
    resFile  : String;
    cmd      : String;
    progress : TForm;
    ok       : Boolean;
    R        : TStringList;
begin
    Settings := PM_LoadSettings;
    try
        helper := PM_HelperPath(Settings);
        if helper = '' then
        begin
            PM_ShowError('Could not find helper\pm_client.ps1.');
            Exit;
        end;

        resFile := PM_SettingsDir + 'auth-result.txt';
        cmd := PM_HelperCmd(helper, 'login') + ' -Result "' + resFile + '"';

        progress := PM_ShowProgress('Opening your browser to sign in to ProvenMetal ...');
        ok := PM_RunHelperPolled(cmd, resFile, 300);
        PM_CloseProgress(progress);

        if not ok then begin PM_ShowError('Sign-in timed out.'); Exit; end;
        R := PM_ReadResultFile(resFile);
        try
            if (R <> nil) and (R.Values['OK'] = '1') then
                ShowMessage('Signed in to ProvenMetal.')
            else if R <> nil then
                PM_ShowError('Sign-in failed: ' + R.Values['ERROR'])
            else
                PM_ShowError('Sign-in produced no result.');
        finally
            if R <> nil then R.Free;
        end;
    finally
        Settings.Free;
    end;
end;


procedure ProvenMetalLogout;
var
    Settings : TStringList;
    helper   : String;
    resFile  : String;
    ok       : Boolean;
begin
    Settings := PM_LoadSettings;
    try
        helper := PM_HelperPath(Settings);
        if helper = '' then begin PM_ShowError('Could not find helper\pm_client.ps1.'); Exit; end;
        resFile := PM_SettingsDir + 'auth-result.txt';
        ok := PM_RunHelperPolled(PM_HelperCmd(helper, 'logout') + ' -Result "' + resFile + '"',
            resFile, 30);
        if ok then ShowMessage('Signed out of ProvenMetal.')
        else PM_ShowError('Logout did not complete.');
    finally
        Settings.Free;
    end;
end;


procedure ProvenMetalSetBaseUrl;
var
    Settings : TStringList;
    helper   : String;
    resFile  : String;
    current  : String;
    newUrl   : String;
begin
    Settings := PM_LoadSettings;
    try
        current := Settings.Values['base_url'];
        newUrl := InputBox('ProvenMetal', 'ProvenMetal Central base URL:', current);
        newUrl := Trim(newUrl);
        if (newUrl = '') or (newUrl = current) then Exit;

        helper := PM_HelperPath(Settings);
        if helper = '' then begin PM_ShowError('Could not find helper\pm_client.ps1.'); Exit; end;

        resFile := PM_SettingsDir + 'auth-result.txt';
        PM_RunHelperPolled(
            PM_HelperCmd(helper, 'set-base-url') + ' -Value "' + newUrl + '" -Result "' + resFile + '"',
            resFile, 30);
        ShowMessage('ProvenMetal Central base URL set to: ' + newUrl);
    finally
        Settings.Free;
    end;
end;
