{..............................................................................}
{ ProvenMetal_Json.pas                                                         }
{                                                                              }
{ Minimal JSON helpers for the ProvenMetal Altium plugin.                      }
{                                                                              }
{ DelphiScript has no JSON library, so we do two small jobs here:              }
{   * BUILD  request JSON (string escaping + null helpers) - the plugin only   }
{            ever WRITES well-formed JSON, so this is easy and complete.       }
{   * READ   a handful of scalar values out of small, well-formed JSON files   }
{            that WE control (settings.json and the <project>.provenmetal.json }
{            sidecar). This is a tolerant scanner, NOT a full parser - the     }
{            full server response is parsed in PowerShell (pm_client.ps1) and  }
{            handed back to us as a flat key=value file, so DelphiScript never  }
{            has to parse arbitrary JSON.                                       }
{..............................................................................}


{ Escape a string for embedding inside a JSON double-quoted string. }
function PM_JsonEscape(const S : String) : String;
var
    i   : Integer;
    c   : Char;
    r   : String;
begin
    r := '';
    for i := 1 to Length(S) do
    begin
        c := S[i];
        if c = '"' then
            r := r + '\"'
        else if c = '\' then
            r := r + '\\'
        else if c = #8 then
            r := r + '\b'
        else if c = #9 then
            r := r + '\t'
        else if c = #10 then
            r := r + '\n'
        else if c = #12 then
            r := r + '\f'
        else if c = #13 then
            r := r + '\r'
        else if c < ' ' then
            r := r + '\u00' + IntToHex(Ord(c), 2)
        else
            r := r + c;
    end;
    Result := r;
end;


{ A JSON string literal: "escaped". }
function PM_JsonStr(const S : String) : String;
begin
    Result := '"' + PM_JsonEscape(S) + '"';
end;


{ A JSON string, or the literal null when the value is empty. Mirrors the      }
{ Python plugin's `_clean(...) or None`.                                       }
function PM_JsonStrOrNull(const S : String) : String;
begin
    if Trim(S) = '' then
        Result := 'null'
    else
        Result := PM_JsonStr(S);
end;


{ ------------------------------------------------------------------ }
{ Tolerant readers for small, controlled JSON documents.             }
{ ------------------------------------------------------------------ }

{ Skip JSON whitespace starting at position i (1-based). }
function PM_JsonSkipWs(const Src : String; i : Integer) : Integer;
begin
    while (i <= Length(Src)) and
          ((Src[i] = ' ') or (Src[i] = #9) or (Src[i] = #10) or (Src[i] = #13)) do
        i := i + 1;
    Result := i;
end;


{ Return the string value for "Key" in Src, or '' if not found / not a string.}
{ Handles the common escapes (\" \\ \n \t \r \/).                               }
function PM_JsonGetString(const Src, Key : String) : String;
var
    p, i : Integer;
    val  : String;
    c    : Char;
begin
    Result := '';
    p := Pos('"' + Key + '"', Src);
    if p = 0 then Exit;

    i := p + Length(Key) + 2;          { just past the closing quote of the key }
    { advance to the ':' }
    while (i <= Length(Src)) and (Src[i] <> ':') do i := i + 1;
    i := i + 1;                        { past ':' }
    i := PM_JsonSkipWs(Src, i);

    if (i > Length(Src)) or (Src[i] <> '"') then Exit;  { not a string value }
    i := i + 1;                        { past opening quote }

    val := '';
    while (i <= Length(Src)) and (Src[i] <> '"') do
    begin
        c := Src[i];
        if c = '\' then
        begin
            i := i + 1;
            if i <= Length(Src) then
            begin
                c := Src[i];
                if c = 'n' then val := val + #10
                else if c = 't' then val := val + #9
                else if c = 'r' then val := val + #13
                else val := val + c;   { \" \\ \/ and anything else -> literal }
            end;
        end
        else
            val := val + c;
        i := i + 1;
    end;
    Result := val;
end;


{ Return the integer value for "Key" in Src, or Default if absent / unparsable.}
function PM_JsonGetInt(const Src, Key : String; Default : Integer) : Integer;
var
    p, i : Integer;
    num  : String;
begin
    Result := Default;
    p := Pos('"' + Key + '"', Src);
    if p = 0 then Exit;

    i := p + Length(Key) + 2;
    while (i <= Length(Src)) and (Src[i] <> ':') do i := i + 1;
    i := i + 1;
    i := PM_JsonSkipWs(Src, i);

    num := '';
    if (i <= Length(Src)) and ((Src[i] = '-') or (Src[i] = '+')) then
    begin
        num := num + Src[i];
        i := i + 1;
    end;
    while (i <= Length(Src)) and (Src[i] >= '0') and (Src[i] <= '9') do
    begin
        num := num + Src[i];
        i := i + 1;
    end;
    if num <> '' then
        Result := StrToIntDef(num, Default);
end;


{ Return the boolean value for "Key" (true/false), or Default if absent. }
function PM_JsonGetBool(const Src, Key : String; Default : Boolean) : Boolean;
var
    p, i : Integer;
begin
    Result := Default;
    p := Pos('"' + Key + '"', Src);
    if p = 0 then Exit;
    i := p + Length(Key) + 2;
    while (i <= Length(Src)) and (Src[i] <> ':') do i := i + 1;
    i := i + 1;
    i := PM_JsonSkipWs(Src, i);
    if Copy(Src, i, 4) = 'true' then Result := True
    else if Copy(Src, i, 5) = 'false' then Result := False;
end;


{ Extract the raw text of the object value for "Key" (the "{ ... }" block),     }
{ so a caller can read scalar sub-keys out of it with PM_JsonGetString. Naive   }
{ brace matching - fine for the flat field_map object we control.               }
function PM_JsonGetObjectBlock(const Src, Key : String) : String;
var
    p, i, depth : Integer;
    startPos    : Integer;
begin
    Result := '';
    p := Pos('"' + Key + '"', Src);
    if p = 0 then Exit;
    i := p + Length(Key) + 2;
    while (i <= Length(Src)) and (Src[i] <> '{') do
    begin
        { bail if we hit the value separator's end without an object }
        if (Src[i] = ',') then Exit;
        i := i + 1;
    end;
    if (i > Length(Src)) then Exit;
    startPos := i;
    depth := 0;
    while i <= Length(Src) do
    begin
        if Src[i] = '{' then depth := depth + 1
        else if Src[i] = '}' then
        begin
            depth := depth - 1;
            if depth = 0 then
            begin
                Result := Copy(Src, startPos, i - startPos + 1);
                Exit;
            end;
        end;
        i := i + 1;
    end;
end;
