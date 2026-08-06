{..............................................................................}
{ ProvenMetal_Client.pas                                                         }
{                                                                              }
{ Bridge between the DelphiScript plugin and the bundled PowerShell helper       }
{ (helper\pm_client.ps1). PowerShell owns everything network-shaped - fetching   }
{ server config, the Supabase loopback-PKCE login, token cache/refresh, the      }
{ authenticated BOM push and JSON parsing - exactly the jobs api.py / auth.py /  }
{ _http.py / config.py did in the KiCad plugin. That keeps DelphiScript free of  }
{ HTTPS/OAuth/JSON parsing, none of which it does well.                          }
{                                                                              }
{ Contract:                                                                      }
{   * DelphiScript WRITES the request as JSON (it only ever builds JSON).        }
{   * PowerShell WRITES a flat key=value result file that DelphiScript reads      }
{     without any JSON parsing:                                                   }
{        OK=1|0                                                                   }
{        ERROR=<message>            (when OK=0)                                   }
{        STATUS=sourced|degraded|no-sourcing                                      }
{        PROJECT_ID / REF / REPORT_URL                                           }
{        SUMMARY_TOTAL / SUMMARY_PASS / SUMMARY_REVIEW / SUMMARY_FAIL             }
{        SOURCING_ERROR=<optional>                                               }
{        WARN=<optional, repeatable>                                             }
{        LINE=<verdict>\t<ref>\t<part>\t<stock>\t<lead>\t<reqQty>\t<supplier>\t   }
{             <sourceStatus>\t<reason>   (repeatable)                            }
{..............................................................................}


{ JSON for one grouped line (see ProvenMetal_Grouping for the line shape). }
function PM_LineJson(Line : TStringList) : String;
var
    refs   : String;
    arr    : String;
    tok    : String;
    i      : Integer;
    c      : Char;
    first  : Boolean;
begin
    { references: comma-joined -> JSON array of strings }
    refs := Line.Values['references'];
    arr := '';
    first := True;
    tok := '';
    for i := 1 to Length(refs) + 1 do
    begin
        if i <= Length(refs) then c := refs[i] else c := ',';
        if c = ',' then
        begin
            if Trim(tok) <> '' then
            begin
                if not first then arr := arr + ',';
                arr := arr + PM_JsonStr(Trim(tok));
                first := False;
            end;
            tok := '';
        end
        else
            tok := tok + c;
    end;

    Result :=
        '{' +
        '"line_key":' + PM_JsonStr(Line.Values['line_key']) + ',' +
        '"references":[' + arr + '],' +
        '"mpn":' + PM_JsonStrOrNull(Line.Values['mpn']) + ',' +
        '"manufacturer":' + PM_JsonStrOrNull(Line.Values['manufacturer']) + ',' +
        '"lcsc":' + PM_JsonStrOrNull(Line.Values['lcsc']) + ',' +
        '"value":' + PM_JsonStrOrNull(Line.Values['value']) + ',' +
        '"footprint":' + PM_JsonStrOrNull(Line.Values['footprint']) + ',' +
        '"description":' + PM_JsonStrOrNull(Line.Values['description']) + ',' +
        '"quantity_per_board":' + IntToStr(PM_ParseIntOr(Line.Values['quantity_per_board'], 1)) + ',' +
        '"digikey":' + PM_JsonStrOrNull(Line.Values['digikey']) + ',' +
        '"mouser":' + PM_JsonStrOrNull(Line.Values['mouser']) +
        '}';
end;


{ Full request body for POST /api/kicad/bom. }
function PM_BuildRequestJson(const Name : String; BoardCount : Integer;
                             const ProjectId : String; Lines : TStringList) : String;
var
    i    : Integer;
    body : String;
    line : TStringList;
begin
    body := '{';
    body := body + '"name":' + PM_JsonStr(Name) + ',';
    body := body + '"boardCount":' + IntToStr(BoardCount) + ',';
    body := body + '"clientVersion":' + PM_JsonStr(PM_CLIENT_VERSION) + ',';
    if Trim(ProjectId) <> '' then
        body := body + '"projectId":' + PM_JsonStr(ProjectId) + ',';
    body := body + '"lines":[';
    for i := 0 to Lines.Count - 1 do
    begin
        line := TStringList(Lines.Objects[i]);
        if i > 0 then body := body + ',';
        body := body + PM_LineJson(line);
    end;
    body := body + ']}';
    Result := body;
end;


{ Directory that contains the plugin (and therefore helper\pm_client.ps1). We     }
{ find it the way XIA_Utils does: by locating our own open script project.        }
function PM_LocatePluginDir(Settings : TStringList) : String;
var
    Workspace : IWorkspace;
    i         : Integer;
    Prj       : IProject;
    full      : String;
begin
    Result := '';
    Workspace := GetWorkspace;
    if Workspace <> nil then
    begin
        for i := 0 to Workspace.DM_ProjectCount - 1 do
        begin
            Prj := Workspace.DM_Projects(i);
            full := Prj.DM_ProjectFullPath;
            if Pos('ProvenMetal.PrjScr', full) > 0 then
            begin
                Result := ExtractFilePath(full);
                Exit;
            end;
        end;
    end;

    { fall back to the directory of an explicit helper_path, then settings dir }
    if Settings.Values['helper_path'] <> '' then
        Result := ExtractFilePath(Settings.Values['helper_path'])
    else
        Result := PM_SettingsDir;
end;


{ Full path to pm_client.ps1, or '' if it can't be found. }
function PM_HelperPath(Settings : TStringList) : String;
var
    hp   : String;
    dir  : String;
    cand : String;
begin
    Result := '';

    hp := Settings.Values['helper_path'];
    if (hp <> '') and FileExists(hp) then
    begin
        Result := hp;
        Exit;
    end;

    dir := PM_LocatePluginDir(Settings);

    cand := PM_EnsureTrailingSlash(dir) + 'helper\pm_client.ps1';
    if FileExists(cand) then begin Result := cand; Exit; end;

    cand := PM_EnsureTrailingSlash(dir) + 'pm_client.ps1';
    if FileExists(cand) then begin Result := cand; Exit; end;

    cand := PM_SettingsDir + 'pm_client.ps1';
    if FileExists(cand) then begin Result := cand; Exit; end;
end;


{ Base of the powershell command line, with the given command verb. }
function PM_HelperCmd(const Ps1, Command : String) : String;
begin
    Result := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + Ps1 +
              '" -Command ' + Command +
              ' -SettingsDir "' + PM_NoTrailingSlash(PM_SettingsDir) + '"';
end;


{ Launch the helper (hidden, async) and poll for its result file. Returns True    }
{ if the result file appeared before TimeoutSecs. UI stays responsive because we  }
{ pump messages while waiting.                                                    }
function PM_RunHelperPolled(const Cmd, ResultFile : String; TimeoutSecs : Integer) : Boolean;
var
    Shell    : Variant;
    deadline : TDateTime;
begin
    Result := False;

    if FileExists(ResultFile) then DeleteFile(ResultFile);

    Shell := PM_Shell;
    Shell.Run(Cmd, 0, False);   { 0 = hidden window, False = don't wait }

    deadline := Now + (TimeoutSecs / 86400.0);
    while Now < deadline do
    begin
        if FileExists(ResultFile) then
        begin
            Result := True;
            Exit;
        end;
        try
            Application.ProcessMessages;
        except
        end;
        Sleep(250);
    end;

    Result := FileExists(ResultFile);
end;


{ Window-aware push runner: launch the helper (hidden, async), pulse the branded  }
{ window's progress bar, stream any lines the helper appends to ProgressFile into  }
{ the window, and poll for ResultFile. Returns True when the result appears.       }
{ Aborts early (returns False) if the user closes the window.                      }
function PM_RunHelperPush(const Cmd, ResultFile, ProgressFile : String;
                          TimeoutSecs : Integer) : Boolean;
var
    Shell    : Variant;
    deadline : TDateTime;
    prog     : TStringList;
    shown    : Integer;
    j        : Integer;
begin
    Result := False;

    if FileExists(ResultFile) then DeleteFile(ResultFile);
    if (ProgressFile <> '') and FileExists(ProgressFile) then DeleteFile(ProgressFile);

    Shell := PM_Shell;
    Shell.Run(Cmd, 0, False);

    shown := 0;
    deadline := Now + (TimeoutSecs / 86400.0);
    while Now < deadline do
    begin
        PM_WinPulse;

        { stream new progress lines from the helper into the window }
        if (ProgressFile <> '') and FileExists(ProgressFile) then
        begin
            prog := TStringList.Create;
            try
                try
                    prog.LoadFromFile(ProgressFile);
                    for j := shown to prog.Count - 1 do
                        PM_WinLog(prog[j]);
                    if prog.Count > shown then shown := prog.Count;
                except
                end;
            finally
                prog.Free;
            end;
        end;

        if FileExists(ResultFile) then
        begin
            Result := True;
            Exit;
        end;

        try
            Application.ProcessMessages;
        except
        end;

        if not PM_WinAlive then Exit;   { user closed the window }

        Sleep(200);
    end;

    Result := FileExists(ResultFile);
end;


{ Read a scalar (first-occurrence) value from a loaded flat-result list. }
function PM_ResultScalar(ResultLines : TStringList; const Key : String) : String;
begin
    Result := ResultLines.Values[Key];
end;
