{..............................................................................}
{ ProvenMetal_Verdict.pas                                                       }
{                                                                              }
{ Client-side mirror of the server verdict rule (src/lib/kicad/verdict.ts and   }
{ the KiCad plugin's verdict.py). The server is authoritative and returns a     }
{ per-line verdict in the push response, so the plugin normally just displays   }
{ what it gets. This mirror exists for a defensive fallback / local re-compute.  }
{ Keep it in lock-step with the TypeScript version.                             }
{                                                                              }
{ Stock/lead of -1 is used as the "unknown/null" sentinel (DelphiScript has no   }
{ nullable integers).                                                            }
{..............................................................................}

const
    PM_SOURCEABLE_WITHIN_DAYS = 7;


function PM_VerdictFor(const SourceStatus : String;
                       Stock          : Integer;   { -1 = unknown }
                       LeadTimeDays   : Integer;   { -1 = unknown }
                       RequiredQty    : Integer) : String;
var
    inStock    : Boolean;
    sourceable : Boolean;
    noData     : Boolean;
begin
    if RequiredQty < 1 then RequiredQty := 1;

    inStock    := (Stock >= 0) and (Stock >= RequiredQty);
    sourceable := (LeadTimeDays >= 0) and (LeadTimeDays <= PM_SOURCEABLE_WITHIN_DAYS);

    if inStock or sourceable then
    begin
        Result := 'pass';
        Exit;
    end;

    if SourceStatus = 'unmatched' then
    begin
        Result := 'fail';
        Exit;
    end;

    noData := (Stock < 0) and (LeadTimeDays < 0);
    if (SourceStatus = 'manual') or (SourceStatus = '') or noData then
        Result := 'review'
    else
        Result := 'fail';
end;
