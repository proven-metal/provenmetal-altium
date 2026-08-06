{..............................................................................}
{ ProvenMetal_Settings.pas                                                       }
{                                                                              }
{ On-disk settings + small filesystem/environment helpers.                      }
{                                                                              }
{ Like the KiCad plugin, the ONLY setting the user must think about is the       }
{ ProvenMetal Central base URL (defaults to central.provenmetal.com). Supabase   }
{ login details are fetched from the server at runtime by the PowerShell helper. }
{                                                                              }
{ Settings + cached credentials live under %APPDATA%\provenmetal-altium\ so the  }
{ DelphiScript plugin and the PowerShell helper agree on one location.           }
{                                                                              }
{ settings.json (all keys optional):                                            }
{ {                                                                             }
{   "base_url": "https://central.provenmetal.com",                             }
{   "oauth_provider": "google",                                                }
{   "board_count": 10,                                                         }
{   "exclude_dnp": true,                                                       }
{   "writeback": false,                                                        }
{   "writeback_field_prefix": "PM",                                            }
{   "helper_path": "",              // set only if auto-discovery fails         }
{   "field_map": { "mpn": "My Part Number", "lcsc": "LCSC Part #" }            }
{ }                                                                             }
{..............................................................................}

const
    PM_DEFAULT_BASE_URL   = 'https://central.provenmetal.com';
    PM_DEFAULT_PROVIDER   = 'google';
    PM_SETTINGS_SUBDIR    = 'provenmetal-altium';
    PM_SIDECAR_SUFFIX     = '.provenmetal.json';
    PM_CLIENT_VERSION     = '0.1.0';


{ A WScript.Shell OLE object (for env expansion + launching processes). }
function PM_Shell : Variant;
begin
    Result := CreateOleObject('WScript.Shell');
end;


{ Expand %VARS% in a path using the Windows environment. }
function PM_EnvExpand(const S : String) : String;
begin
    try
        Result := PM_Shell.ExpandEnvironmentStrings(S);
    except
        Result := S;
    end;
end;


function PM_EnsureTrailingSlash(const S : String) : String;
begin
    if (S <> '') and (S[Length(S)] <> '\') then
        Result := S + '\'
    else
        Result := S;
end;


{ Remove a trailing backslash. Needed when a path is placed inside double quotes  }
{ on a Windows command line: `"C:\dir\"` mis-parses because the \" is read as an   }
{ escaped quote, so we pass `"C:\dir"` instead.                                    }
function PM_NoTrailingSlash(const S : String) : String;
begin
    Result := S;
    while (Result <> '') and (Result[Length(Result)] = '\') do
        Result := Copy(Result, 1, Length(Result) - 1);
end;


{ %APPDATA%\provenmetal-altium\  (created if needed). }
function PM_SettingsDir : String;
var
    dir : String;
begin
    dir := PM_EnsureTrailingSlash(PM_EnvExpand('%APPDATA%')) + PM_SETTINGS_SUBDIR;
    if not DirectoryExists(dir) then
        ForceDirectories(dir);
    Result := PM_EnsureTrailingSlash(dir);
end;


function PM_SettingsPath : String;
begin
    Result := PM_SettingsDir + 'settings.json';
end;


{ Read an entire text file into a string ('' if missing/unreadable). }
function PM_ReadFileText(const Path : String) : String;
var
    sl : TStringList;
begin
    Result := '';
    if not FileExists(Path) then Exit;
    sl := TStringList.Create;
    try
        try
            sl.LoadFromFile(Path);
            Result := sl.Text;
        except
            Result := '';
        end;
    finally
        sl.Free;
    end;
end;


{ Overwrite a text file with the given content. }
procedure PM_WriteFileText(const Path, Content : String);
var
    sl : TStringList;
begin
    sl := TStringList.Create;
    try
        sl.Text := Content;
        sl.SaveToFile(Path);
    finally
        sl.Free;
    end;
end;


{ Set Sl.Values[Key] only when Val is non-empty (keeps defaults otherwise). }
procedure PM_SetIfNonEmpty(Sl : TStringList; const Key, Val : String);
begin
    if Trim(Val) <> '' then Sl.Values[Key] := Trim(Val);
end;


{ Load settings into a Name=Value TStringList, applying defaults. field_map      }
{ entries are flattened to keys 'fieldmap_<canonical>'. Caller frees.            }
function PM_LoadSettings : TStringList;
var
    text  : String;
    block : String;
    s     : TStringList;
begin
    s := TStringList.Create;

    { defaults }
    s.Values['base_url']               := PM_DEFAULT_BASE_URL;
    s.Values['oauth_provider']         := PM_DEFAULT_PROVIDER;
    s.Values['board_count']            := '1';
    s.Values['exclude_dnp']            := '1';
    s.Values['writeback']              := '0';
    s.Values['writeback_field_prefix'] := 'PM';
    s.Values['helper_path']            := '';

    text := PM_ReadFileText(PM_SettingsPath);
    if text <> '' then
    begin
        PM_SetIfNonEmpty(s, 'base_url', PM_JsonGetString(text, 'base_url'));
        PM_SetIfNonEmpty(s, 'oauth_provider', PM_JsonGetString(text, 'oauth_provider'));
        s.Values['board_count'] := IntToStr(PM_JsonGetInt(text, 'board_count', 1));
        if PM_JsonGetBool(text, 'exclude_dnp', True) then s.Values['exclude_dnp'] := '1' else s.Values['exclude_dnp'] := '0';
        if PM_JsonGetBool(text, 'writeback', False) then s.Values['writeback'] := '1' else s.Values['writeback'] := '0';
        PM_SetIfNonEmpty(s, 'writeback_field_prefix', PM_JsonGetString(text, 'writeback_field_prefix'));
        PM_SetIfNonEmpty(s, 'helper_path', PM_JsonGetString(text, 'helper_path'));

        { normalize base_url: strip a trailing slash }
        while (s.Values['base_url'] <> '') and (s.Values['base_url'][Length(s.Values['base_url'])] = '/') do
            s.Values['base_url'] := Copy(s.Values['base_url'], 1, Length(s.Values['base_url']) - 1);

        block := PM_JsonGetObjectBlock(text, 'field_map');
        if block <> '' then
        begin
            PM_SetIfNonEmpty(s, 'fieldmap_mpn',          PM_JsonGetString(block, 'mpn'));
            PM_SetIfNonEmpty(s, 'fieldmap_manufacturer', PM_JsonGetString(block, 'manufacturer'));
            PM_SetIfNonEmpty(s, 'fieldmap_lcsc',         PM_JsonGetString(block, 'lcsc'));
            PM_SetIfNonEmpty(s, 'fieldmap_digikey',      PM_JsonGetString(block, 'digikey'));
            PM_SetIfNonEmpty(s, 'fieldmap_mouser',       PM_JsonGetString(block, 'mouser'));
            PM_SetIfNonEmpty(s, 'fieldmap_value',        PM_JsonGetString(block, 'value'));
            PM_SetIfNonEmpty(s, 'fieldmap_footprint',    PM_JsonGetString(block, 'footprint'));
            PM_SetIfNonEmpty(s, 'fieldmap_description',  PM_JsonGetString(block, 'description'));
        end;
    end;

    Result := s;
end;


function PM_SettingBool(Settings : TStringList; const Key : String) : Boolean;
begin
    Result := Settings.Values[Key] = '1';
end;


{ ---- <project>.provenmetal.json sidecar (link to the Central project) ------- }

function PM_SidecarPath(const ProjectDir, ProjectName : String) : String;
begin
    Result := PM_EnsureTrailingSlash(ProjectDir) + ProjectName + PM_SIDECAR_SUFFIX;
end;


function PM_SidecarProjectId(const ProjectDir, ProjectName : String) : String;
var
    text : String;
begin
    text := PM_ReadFileText(PM_SidecarPath(ProjectDir, ProjectName));
    Result := PM_JsonGetString(text, 'projectId');
end;


function PM_SidecarBoardCount(const ProjectDir, ProjectName : String; Default : Integer) : Integer;
var
    text : String;
begin
    text := PM_ReadFileText(PM_SidecarPath(ProjectDir, ProjectName));
    if text = '' then Result := Default
    else Result := PM_JsonGetInt(text, 'boardCount', Default);
end;
