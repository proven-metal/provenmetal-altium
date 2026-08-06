{..............................................................................}
{ ProvenMetal_Bom.pas                                                            }
{                                                                              }
{ Extract a BOM from the focused Altium project via the Design Manager (a.k.a.   }
{ Workspace Manager) API.                                                        }
{                                                                              }
{ This is the Altium analogue of the KiCad plugin's `kicad-cli sch export bom`:  }
{ we compile the project and read its FLATTENED pseudo-schematic, which already   }
{ does hierarchy expansion and multi-channel repetition for us. Each flattened   }
{ component becomes one row (qty 1); ProvenMetal_Grouping then consolidates rows  }
{ into orderable lines by (mpn || lcsc || value).                                }
{                                                                              }
{ Confirmed API (see Altium scripts-libraries, e.g. InteractiveHTMLBOM4Altium):  }
{   Project.DM_Compile / RunProcess('WorkspaceManager:Compile')                  }
{   Flat := Project.DM_DocumentFlattened                                         }
{   Flat.DM_ComponentCount / Flat.DM_Components[i]        -> IComponent          }
{   Comp.DM_SubParts[0]                                   -> IPart              }
{   Part.DM_PhysicalDesignator / Part.DM_Footprint                              }
{   Comp.DM_ParameterCount / Comp.DM_Parameters(i)        -> IParameter         }
{   Comp.DM_GetParameterByName(name)                      -> IParameter or nil   }
{   Param.DM_Name / Param.DM_Value                                              }
{   Project.DM_CurrentProjectVariant                      -> IProjectVariant     }
{   Variant.DM_FindComponentVariationByDesignator(des) / .DM_VariationKind       }
{..............................................................................}


{ Value of a named DM parameter on a component, or '' if absent/error. }
function PM_GetParamValue(Comp : IComponent; const Name : String) : String;
var
    p : IParameter;
begin
    Result := '';
    try
        p := Comp.DM_GetParameterByName(Name);
        if p <> nil then
            Result := p.DM_Value;
    except
        Result := '';
    end;
end;


function PM_SafeFootprint(Part : IPart) : String;
begin
    try
        Result := Part.DM_Footprint;
    except
        Result := '';
    end;
end;


function PM_SafeDescription(Part : IPart) : String;
begin
    try
        Result := Part.DM_Description;
    except
        Result := '';
    end;
end;


{ Resolve one canonical column from a component, trying candidate parameter      }
{ names (pinned name first) plus the special #FOOTPRINT/#DESCRIPTION attribute    }
{ tokens (resolved from IPart). First non-empty wins.                            }
function PM_ReadCanonical(Comp : IComponent; Part : IPart;
                          const Canonical : String; Settings : TStringList) : String;
var
    pinned : String;
    cands  : TStringList;
    i      : Integer;
    cand   : String;
    v      : String;
begin
    Result := '';
    pinned := Settings.Values['fieldmap_' + Canonical];
    cands := PM_Fields_CandidateList(Canonical, pinned);
    try
        for i := 0 to cands.Count - 1 do
        begin
            cand := cands[i];
            if cand = '#FOOTPRINT' then
                v := PM_SafeFootprint(Part)
            else if cand = '#DESCRIPTION' then
            begin
                v := PM_GetParamValue(Comp, 'Description');
                if Trim(v) = '' then v := PM_SafeDescription(Part);
            end
            else
                v := PM_GetParamValue(Comp, cand);

            v := Trim(v);
            if v <> '' then
            begin
                Result := v;
                Break;
            end;
        end;
    finally
        cands.Free;
    end;
end;


{ True when a component should never appear in a BOM (graphical, net-tie, or      }
{ explicitly "Standard (No BOM)").                                               }
function PM_ComponentExcludedFromBom(Comp : IComponent) : Boolean;
var
    kind : String;
begin
    kind := PM_GetParamValue(Comp, 'Component Kind');
    Result := (Pos('No BOM', kind) > 0) or (kind = 'Graphical') or (kind = 'Net Tie');
end;


{ Port of InteractiveHTMLBOM's UseIt(): is this component fitted in the current   }
{ assembly variant? With no active variant, a component is fitted unless it is a  }
{ variant-specific duplicate (UniqueId contains '@').                            }
function PM_ComponentFitted(Comp : IComponent; Part : IPart;
                            ProjectVariant : IProjectVariant) : Boolean;
var
    variation : IComponentVariation;
begin
    if ProjectVariant = nil then
    begin
        Result := (Pos('@', Comp.DM_UniqueId) = 0);
        Exit;
    end;

    try
        variation := ProjectVariant.DM_FindComponentVariationByDesignator(Part.DM_PhysicalDesignator);
    except
        variation := nil;
    end;

    if variation <> nil then
    begin
        if Comp.DM_UniqueId <> (variation.DM_UniqueId + '@' + ProjectVariant.DM_Description) then
            Result := False
        else
            Result := True;
        if variation.DM_VariationKind = eVariation_NotFitted then
            Result := False;
    end
    else
        Result := (Pos('@', Comp.DM_UniqueId) = 0);
end;


{ Get the focused project, or nil. }
function PM_GetFocusedProject : IProject;
var
    Workspace : IWorkspace;
begin
    Result := nil;
    Workspace := GetWorkspace;
    if Workspace = nil then Exit;
    Result := Workspace.DM_FocusedProject;
end;


{ Compile the project and return its flattened document, or nil. }
function PM_CompileAndFlatten(Project : IProject) : IDocument;
begin
    Result := nil;
    if Project = nil then Exit;

    try
        Project.DM_Compile;
    except
        { some versions compile via the process launcher instead }
    end;

    Result := Project.DM_DocumentFlattened;
    if Result = nil then
    begin
        try
            ResetParameters;
            AddStringParameter('Action', 'Compile');
            AddStringParameter('ObjectKind', 'Project');
            RunProcess('WorkspaceManager:Compile');
        except
        end;
        Result := Project.DM_DocumentFlattened;
    end;
end;


{ Extract the flattened BOM as a rows collection: a TStringList whose Objects[i]  }
{ are per-component row TStringLists (Name=Value over the canonical columns).     }
{ Returns nil on failure (caller shows an error). Caller frees with              }
{ PM_FreeCollection.                                                             }
function PM_ExtractBom(Project : IProject; Settings : TStringList) : TStringList;
var
    Flat        : IDocument;
    ProjVariant : IProjectVariant;
    i           : Integer;
    Comp        : IComponent;
    Part        : IPart;
    row         : TStringList;
    rows        : TStringList;
    des         : String;
    p           : Integer;
begin
    Result := nil;
    Flat := PM_CompileAndFlatten(Project);
    if Flat = nil then Exit;

    try
        ProjVariant := Project.DM_CurrentProjectVariant;
    except
        ProjVariant := nil;
    end;

    rows := TStringList.Create;

    for i := 0 to Flat.DM_ComponentCount - 1 do
    begin
        Comp := Flat.DM_Components[i];
        if Comp = nil then Continue;
        try
            Part := Comp.DM_SubParts[0];
        except
            Part := nil;
        end;
        if Part = nil then Continue;

        { never-orderable components (graphical, net ties, No-BOM) are dropped }
        if PM_ComponentExcludedFromBom(Comp) then Continue;

        des := Part.DM_PhysicalDesignator;
        p := Pos('@', des);
        if p > 0 then des := Copy(des, 1, p - 1);
        if Trim(des) = '' then Continue;

        row := TStringList.Create;
        row.Values['reference']    := des;
        row.Values['value']        := PM_ReadCanonical(Comp, Part, 'value', Settings);
        row.Values['footprint']    := PM_ReadCanonical(Comp, Part, 'footprint', Settings);
        row.Values['mpn']          := PM_ReadCanonical(Comp, Part, 'mpn', Settings);
        row.Values['manufacturer'] := PM_ReadCanonical(Comp, Part, 'manufacturer', Settings);
        row.Values['lcsc']         := PM_ReadCanonical(Comp, Part, 'lcsc', Settings);
        row.Values['digikey']      := PM_ReadCanonical(Comp, Part, 'digikey', Settings);
        row.Values['mouser']       := PM_ReadCanonical(Comp, Part, 'mouser', Settings);
        row.Values['description']  := PM_ReadCanonical(Comp, Part, 'description', Settings);
        row.Values['qty']          := '1';

        if PM_ComponentFitted(Comp, Part, ProjVariant) then
            row.Values['dnp'] := '0'
        else
            row.Values['dnp'] := '1';

        rows.AddObject(des, row);
    end;

    Result := rows;
end;
