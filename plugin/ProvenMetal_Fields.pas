{..............................................................................}
{ ProvenMetal_Fields.pas                                                       }
{                                                                              }
{ Mapping between Altium component parameters and our canonical BOM columns.    }
{                                                                              }
{ The KiCad plugin drove `kicad-cli sch export bom` with an explicit           }
{ --fields/--labels pair. In Altium we read parameters straight off the        }
{ compiled (flattened) component with DM_GetParameterByName, so instead of a    }
{ CLI spec we just keep, per canonical column, the list of candidate parameter  }
{ names to try (first non-empty wins). The user can pin an exact name per       }
{ column via settings.json -> field_map.                                        }
{                                                                              }
{ Two candidate tokens are special and are resolved from component attributes   }
{ rather than a named parameter (see ProvenMetal_Bom.pas):                      }
{   #COMMENT       -> the component Comment (Altium's "value")                  }
{   #FOOTPRINT     -> the current footprint name                               }
{   #DESCRIPTION   -> the component library Description                         }
{..............................................................................}


{ Candidate parameter names for a canonical column, '|' separated (parameter    }
{ names never contain '|'). Mirrors fields.py DEFAULT_CANDIDATES.               }
function PM_Fields_Candidates(const Canonical : String) : String;
begin
    if Canonical = 'value' then
        Result := 'Comment|Value'
    else if Canonical = 'footprint' then
        Result := '#FOOTPRINT|Footprint'
    else if Canonical = 'mpn' then
        Result := 'MPN|Manufacturer Part Number|MFR#|Mfr Part #|Part Number|MPN1|Manufacturer Part Number 1'
    else if Canonical = 'manufacturer' then
        Result := 'Manufacturer|Mfr|MFN|Mfg|Manufacturer 1'
    else if Canonical = 'lcsc' then
        Result := 'LCSC|LCSC Part #|LCSC Part Number|JLCPCB Part #'
    else if Canonical = 'digikey' then
        Result := 'Digikey|Digi-Key|DigiKey Part Number|DK Part #'
    else if Canonical = 'mouser' then
        Result := 'Mouser|Mouser Part Number|Mouser #'
    else if Canonical = 'description' then
        Result := '#DESCRIPTION|Description|Desc|Comments'
    else
        Result := '';
end;


{ Split a '|' separated candidate list into a TStringList (caller frees). If a  }
{ pinned name is supplied (from field_map) it is inserted first.                }
function PM_Fields_CandidateList(const Canonical, Pinned : String) : TStringList;
var
    raw   : String;
    part  : String;
    p     : Integer;
begin
    Result := TStringList.Create;
    if Trim(Pinned) <> '' then
        Result.Add(Trim(Pinned));

    raw := PM_Fields_Candidates(Canonical);
    while raw <> '' do
    begin
        p := Pos('|', raw);
        if p = 0 then
        begin
            part := raw;
            raw := '';
        end
        else
        begin
            part := Copy(raw, 1, p - 1);
            raw := Copy(raw, p + 1, Length(raw));
        end;
        part := Trim(part);
        if (part <> '') and (Result.IndexOf(part) < 0) then
            Result.Add(part);
    end;
end;
