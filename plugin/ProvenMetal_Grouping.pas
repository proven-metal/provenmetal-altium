{..............................................................................}
{ ProvenMetal_Grouping.pas                                                      }
{                                                                              }
{ Turn raw (canonical) BOM rows into orderable lines for the push. Direct port  }
{ of the KiCad plugin's grouping.py so the server sees identical line shapes.    }
{                                                                              }
{ Data representation in DelphiScript:                                          }
{   * A "row"  is a TStringList of Name=Value pairs over the canonical columns   }
{     (reference, value, footprint, mpn, manufacturer, lcsc, digikey, mouser,    }
{      description, qty, dnp).                                                   }
{   * A "rows collection" is a TStringList whose Objects[i] hold the row lists.   }
{   * A grouped "line" is a TStringList of Name=Value pairs, with references     }
{     kept as a comma-joined string in Values['references'].                     }
{   * The returned "lines collection" is a TStringList whose Objects[i] hold the }
{     line lists, ordered by (first reference, line_key).                        }
{..............................................................................}


function PM_IsAlpha(c : Char) : Boolean;
begin
    Result := ((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z'));
end;


function PM_IsDigit(c : Char) : Boolean;
begin
    Result := (c >= '0') and (c <= '9');
end;


{ Placeholder strings that mean "no value" (test points, un-sourced pads, ...). }
function PM_IsPlaceholder(const V : String) : Boolean;
var
    low : String;
begin
    low := LowerCase(Trim(V));
    if (low = '') or (low = '-') or (low = '--') or
       (low = 'n/a') or (low = 'na') or (low = 'tbd') or
       (low = '?') or (low = 'none') then
    begin
        Result := True;
        Exit;
    end;
    { a lone unicode dash (en/em dash, figure/non-breaking hyphen, ...) as "none" }
    if (Length(low) = 1) and (Ord(low[1]) >= 8208) and (Ord(low[1]) <= 8213) then
    begin
        Result := True;
        Exit;
    end;
    Result := False;
end;


{ Trim, collapsing placeholder strings to empty. Mirrors grouping._clean. }
function PM_Clean(const V : String) : String;
begin
    if PM_IsPlaceholder(V) then
        Result := ''
    else
        Result := Trim(V);
end;


{ Truthy spellings for a DNP flag. }
function PM_IsTruthyDnp(const V : String) : Boolean;
var
    low : String;
begin
    low := LowerCase(Trim(V));
    Result := (low = '1') or (low = 'true') or (low = 'yes') or
              (low = 'dnp') or (low = 'x') or (low = 'y');
end;


{ Parse an integer (tolerating "3" or "3.0"); fall back to Default. }
function PM_ParseIntOr(const V : String; Default : Integer) : Integer;
var
    s     : String;
    dotP  : Integer;
begin
    s := Trim(V);
    dotP := Pos('.', s);
    if dotP > 0 then s := Copy(s, 1, dotP - 1);   { truncate towards zero }
    if s = '' then
        Result := Default
    else
        Result := StrToIntDef(s, Default);
end;


{ Expand a reference range token ("C11-C18" -> C11..C18); pass anything else     }
{ through unchanged. Returns a TStringList (caller frees).                       }
function PM_ExpandRefToken(const Token : String) : TStringList;
var
    t         : String;
    i, n      : Integer;
    prefix    : String;
    startS    : String;
    endPrefix : String;
    endS      : String;
    startN    : Integer;
    endN      : Integer;
begin
    Result := TStringList.Create;
    t := Trim(Token);

    i := 1;
    prefix := '';
    while (i <= Length(t)) and PM_IsAlpha(t[i]) do begin prefix := prefix + t[i]; i := i + 1; end;
    startS := '';
    while (i <= Length(t)) and PM_IsDigit(t[i]) do begin startS := startS + t[i]; i := i + 1; end;
    while (i <= Length(t)) and (t[i] = ' ') do i := i + 1;

    if (i > Length(t)) or (t[i] <> '-') then begin Result.Add(Token); Exit; end;
    i := i + 1;
    while (i <= Length(t)) and (t[i] = ' ') do i := i + 1;

    endPrefix := '';
    while (i <= Length(t)) and PM_IsAlpha(t[i]) do begin endPrefix := endPrefix + t[i]; i := i + 1; end;
    endS := '';
    while (i <= Length(t)) and PM_IsDigit(t[i]) do begin endS := endS + t[i]; i := i + 1; end;

    { the whole token must be consumed and the shape must be well-formed }
    if (i <= Length(t)) or (prefix = '') or (startS = '') or (endS = '') then
    begin Result.Add(Token); Exit; end;
    if (endPrefix <> '') and (endPrefix <> prefix) then
    begin Result.Add(Token); Exit; end;

    startN := StrToIntDef(startS, -1);
    endN   := StrToIntDef(endS, -1);
    if (startN < 0) or (endN < 0) or (endN < startN) or ((endN - startN) > 100000) then
    begin Result.Add(Token); Exit; end;

    for n := startN to endN do
        Result.Add(prefix + IntToStr(n));
end;


{ Split a reference field (comma/space separated, may contain ranges) into a     }
{ flat TStringList of individual designators (caller frees).                     }
function PM_SplitRefs(const Value : String) : TStringList;
var
    i        : Integer;
    tok      : String;
    c        : Char;
    expanded : TStringList;
    j        : Integer;
begin
    Result := TStringList.Create;
    if Trim(Value) = '' then Exit;

    tok := '';
    for i := 1 to Length(Value) + 1 do
    begin
        if i <= Length(Value) then c := Value[i] else c := ',';   { flush at end }
        if (c = ',') or (c = ' ') or (c = #9) or (c = #10) or (c = #13) then
        begin
            if Trim(tok) <> '' then
            begin
                expanded := PM_ExpandRefToken(Trim(tok));
                try
                    for j := 0 to expanded.Count - 1 do
                        Result.Add(expanded[j]);
                finally
                    expanded.Free;
                end;
            end;
            tok := '';
        end
        else
            tok := tok + c;
    end;
end;


{ Stable per-line identity, mirroring the server (mpn || lcsc || value). }
function PM_LineKeyFor(const Mpn, Lcsc, Value : String) : String;
var
    v : String;
begin
    Result := '';
    v := PM_Clean(Mpn);
    if v <> '' then begin Result := LowerCase(v); Exit; end;
    v := PM_Clean(Lcsc);
    if v <> '' then begin Result := LowerCase(v); Exit; end;
    v := PM_Clean(Value);
    if v <> '' then begin Result := LowerCase(v); Exit; end;
end;


{ First designator in a comma-joined reference string. }
function PM_FirstRef(const Refs : String) : String;
var
    p : Integer;
begin
    p := Pos(',', Refs);
    if p = 0 then Result := Refs
    else Result := Copy(Refs, 1, p - 1);
end;


{ True if Ref is already present in the comma-joined reference string. }
function PM_RefsContain(const Refs, Ref : String) : Boolean;
begin
    Result := Pos(',' + Ref + ',', ',' + Refs + ',') > 0;
end;


{ Consolidate canonical rows into orderable snapshot lines.                     }
{ Rows: a TStringList whose Objects[i] are row TStringLists.                     }
{ Returns: a TStringList whose Objects[i] are line TStringLists, ordered by      }
{ (first reference, line_key). Caller frees the returned list AND its objects.   }
function PM_GroupRows(Rows : TStringList; ExcludeDnp : Boolean) : TStringList;
var
    merged   : TStringList;
    outList  : TStringList;
    i, j, k  : Integer;
    row      : TStringList;
    line     : TStringList;
    key      : String;
    refsList : TStringList;
    refs     : String;
    qty      : Integer;
    idx      : Integer;
    fldName  : String;
    fldVal   : String;
    curRefs  : String;
    curQty   : Integer;
    fields   : TStringList;
    sortKey  : String;
begin
    merged := TStringList.Create;
    merged.Sorted := True;
    merged.Duplicates := dupError;   { line_key is unique in `merged` }

    { canonical fields carried onto each line (references + qty handled apart) }
    fields := TStringList.Create;
    fields.Add('mpn');
    fields.Add('manufacturer');
    fields.Add('lcsc');
    fields.Add('value');
    fields.Add('footprint');
    fields.Add('description');
    fields.Add('digikey');
    fields.Add('mouser');

    try
        for i := 0 to Rows.Count - 1 do
        begin
            row := TStringList(Rows.Objects[i]);
            if row = nil then Continue;

            if ExcludeDnp and PM_IsTruthyDnp(row.Values['dnp']) then Continue;

            key := PM_LineKeyFor(row.Values['mpn'], row.Values['lcsc'], row.Values['value']);
            if key = '' then Continue;   { nothing orderable on this row }

            refsList := PM_SplitRefs(row.Values['reference']);
            try
                qty := PM_ParseIntOr(row.Values['qty'], refsList.Count);
                if qty < 1 then qty := 1;

                idx := merged.IndexOf(key);
                if idx < 0 then
                begin
                    line := TStringList.Create;
                    line.Values['line_key'] := key;
                    for k := 0 to fields.Count - 1 do
                    begin
                        fldName := fields[k];
                        fldVal := PM_Clean(row.Values[fldName]);
                        if fldVal <> '' then
                            line.Values[fldName] := fldVal;
                    end;

                    refs := '';
                    for j := 0 to refsList.Count - 1 do
                    begin
                        if refs = '' then refs := refsList[j]
                        else if not PM_RefsContain(refs, refsList[j]) then
                            refs := refs + ',' + refsList[j];
                    end;
                    line.Values['references'] := refs;
                    line.Values['quantity_per_board'] := IntToStr(qty);

                    merged.AddObject(key, line);
                end
                else
                begin
                    line := TStringList(merged.Objects[idx]);

                    { union references (preserve order, drop dupes) }
                    curRefs := line.Values['references'];
                    for j := 0 to refsList.Count - 1 do
                    begin
                        if curRefs = '' then curRefs := refsList[j]
                        else if not PM_RefsContain(curRefs, refsList[j]) then
                            curRefs := curRefs + ',' + refsList[j];
                    end;
                    line.Values['references'] := curRefs;

                    curQty := PM_ParseIntOr(line.Values['quantity_per_board'], 0);
                    line.Values['quantity_per_board'] := IntToStr(curQty + qty);

                    { fill any field the first occurrence lacked }
                    for k := 0 to fields.Count - 1 do
                    begin
                        fldName := fields[k];
                        if line.Values[fldName] = '' then
                        begin
                            fldVal := PM_Clean(row.Values[fldName]);
                            if fldVal <> '' then
                                line.Values[fldName] := fldVal;
                        end;
                    end;
                end;
            finally
                refsList.Free;
            end;
        end;

        { Stable output order: by first reference, then line_key. }
        outList := TStringList.Create;
        outList.Sorted := True;
        outList.Duplicates := dupAccept;
        for i := 0 to merged.Count - 1 do
        begin
            line := TStringList(merged.Objects[i]);
            sortKey := PM_FirstRef(line.Values['references']) + '|' + line.Values['line_key'];
            outList.AddObject(sortKey, line);
        end;

        Result := outList;
    finally
        fields.Free;
        merged.Free;    { frees the container, not the line objects (now in outList) }
    end;
end;


{ Free a lines/rows collection AND the TStringList objects it owns. }
procedure PM_FreeCollection(Coll : TStringList);
var
    i : Integer;
begin
    if Coll = nil then Exit;
    for i := 0 to Coll.Count - 1 do
        if Coll.Objects[i] <> nil then
            TStringList(Coll.Objects[i]).Free;
    Coll.Free;
end;
