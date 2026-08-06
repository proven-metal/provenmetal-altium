{..............................................................................}
{ ProvenMetal_Writeback.pas                                                      }
{                                                                              }
{ Optional: write the sourcing verdict back into schematic component parameters, }
{ matched by designator, in one undoable transaction. Altium analogue of the     }
{ KiCad plugin's writeback.py (which used the KiCad 11 schematic IPC).           }
{                                                                              }
{ Fields written (default prefix "PM"):                                          }
{   PM_Status     pass | review | fail                                          }
{   PM_Stock      units at the best offer's supplier                            }
{   PM_Lead_Days  lead time in days                                             }
{   PM_Supplier   digikey | mouser | ...                                        }
{   PM_Checked    ISO date of the run                                           }
{                                                                              }
{ Best-effort and non-fatal: any failure is caught and reported, never raised -  }
{ the sourcing result is already saved server-side regardless.                   }
{..............................................................................}


{ Add a hidden parameter to a component, or update it if it already exists. }
procedure PM_SetSchParam(SchDoc : ISch_Document; Comp : ISch_Component;
                         const Name, Value : String);
var
    Iter     : ISch_Iterator;
    Param    : ISch_Parameter;
    found    : ISch_Parameter;
    newParam : ISch_Parameter;
begin
    found := nil;
    Iter := Comp.SchIterator_Create;
    try
        Iter.AddFilter_ObjectSet(MkSet(eParameter));
        Param := Iter.FirstSchObject;
        while Param <> nil do
        begin
            if Param.Name = Name then
            begin
                found := Param;
                Break;
            end;
            Param := Iter.NextSchObject;
        end;
    finally
        Comp.SchIterator_Destroy(Iter);
    end;

    if found <> nil then
    begin
        SchServer.RobotManager.SendMessage(found.I_ObjectAddress, c_BroadCast,
            SCHM_BeginModify, c_NoEventData);
        found.Text := Value;
        found.IsHidden := True;
        SchServer.RobotManager.SendMessage(found.I_ObjectAddress, c_BroadCast,
            SCHM_EndModify, c_NoEventData);
    end
    else
    begin
        newParam := SchServer.SchObjectFactory(eParameter, eCreate_Default);
        newParam.Name := Name;
        newParam.ShowName := False;
        newParam.Text := Value;
        newParam.IsHidden := True;
        Comp.AddSchObject(newParam);
        SchServer.RobotManager.SendMessage(Comp.I_ObjectAddress, c_BroadCast,
            SCHM_PrimitiveRegistration, newParam.I_ObjectAddress);
    end;
end;


{ Annotate every component of one schematic document that appears in DesMap.      }
{ DesMap maps designator -> "verdict<TAB>stock<TAB>lead<TAB>supplier".            }
{ Returns the number of components updated.                                       }
function PM_WritebackDoc(SchDoc : ISch_Document; DesMap : TStringList;
                         const Prefix, Today : String) : Integer;
var
    Iter : ISch_Iterator;
    Comp : ISch_Component;
    des  : String;
    data : String;
    n    : Integer;
begin
    n := 0;
    SchServer.ProcessControl.PreProcess(SchDoc, '');
    try
        Iter := SchDoc.SchIterator_Create;
        try
            Iter.AddFilter_ObjectSet(MkSet(eSchComponent));
            Comp := Iter.FirstSchObject;
            while Comp <> nil do
            begin
                try
                    des := Comp.Designator.Text;
                except
                    des := '';
                end;
                if des <> '' then
                begin
                    data := DesMap.Values[des];
                    if data <> '' then
                    begin
                        PM_SetSchParam(SchDoc, Comp, Prefix + '_Status',    PM_TabField(data, 1));
                        PM_SetSchParam(SchDoc, Comp, Prefix + '_Stock',     PM_TabField(data, 2));
                        PM_SetSchParam(SchDoc, Comp, Prefix + '_Lead_Days', PM_TabField(data, 3));
                        PM_SetSchParam(SchDoc, Comp, Prefix + '_Supplier',  PM_TabField(data, 4));
                        PM_SetSchParam(SchDoc, Comp, Prefix + '_Checked',   Today);
                        n := n + 1;
                    end;
                end;
                Comp := Iter.NextSchObject;
            end;
        finally
            SchDoc.SchIterator_Destroy(Iter);
        end;
    finally
        SchServer.ProcessControl.PostProcess(SchDoc, '');
    end;
    SchDoc.GraphicallyInvalidate;
    Result := n;
end;


{ Apply writeback across the project's schematic sheets. RequestLines is the      }
{ in-memory grouped lines (line_key + references); ResultLines is the helper's    }
{ flat result. Returns the number of components updated. Never raises.            }
function PM_ApplyWriteback(Project : IProject; RequestLines, ResultLines : TStringList;
                           const Prefix : String) : Integer;
var
    resultByKey : TStringList;   { line_key -> "verdict<TAB>stock<TAB>lead<TAB>supplier" }
    desMap      : TStringList;   { designator -> same payload }
    i, j        : Integer;
    raw, val    : String;
    lk, data    : String;
    line        : TStringList;
    refs        : TStringList;
    today       : String;
    doc         : IDocument;
    SchDoc      : ISch_Document;
    total       : Integer;
begin
    Result := 0;
    if (Project = nil) or (ResultLines = nil) or (RequestLines = nil) then Exit;
    if SchServer = nil then
    begin
        PM_Log('writeback: SchServer unavailable');
        Exit;
    end;

    resultByKey := TStringList.Create;
    desMap := TStringList.Create;
    try
        { index server verdicts by line_key }
        for i := 0 to ResultLines.Count - 1 do
        begin
            raw := ResultLines[i];
            if Copy(raw, 1, 5) = 'LINE=' then
            begin
                val := Copy(raw, 6, Length(raw));
                lk := PM_TabField(val, 1);
                if lk <> '' then
                    resultByKey.Values[lk] :=
                        PM_TabField(val, 2) + #9 +   { verdict }
                        PM_TabField(val, 5) + #9 +   { stock }
                        PM_TabField(val, 6) + #9 +   { lead }
                        PM_TabField(val, 8);         { supplier }
            end;
        end;

        { fan out each grouped line's verdict to all of its designators }
        for i := 0 to RequestLines.Count - 1 do
        begin
            line := TStringList(RequestLines.Objects[i]);
            lk := line.Values['line_key'];
            data := resultByKey.Values[lk];
            if data = '' then Continue;
            refs := PM_SplitRefs(line.Values['references']);
            try
                for j := 0 to refs.Count - 1 do
                    desMap.Values[refs[j]] := data;
            finally
                refs.Free;
            end;
        end;

        today := FormatDateTime('yyyy-mm-dd', Now);
        total := 0;

        for i := 0 to Project.DM_LogicalDocumentCount - 1 do
        begin
            doc := Project.DM_LogicalDocuments(i);
            if (doc.DM_DocumentKind = 'SCH') or
               (UpperCase(ExtractFileExt(doc.DM_FullPath)) = '.SCHDOC') then
            begin
                try
                    SchDoc := SchServer.GetSchDocumentByPath(doc.DM_FullPath);
                    if SchDoc <> nil then
                        total := total + PM_WritebackDoc(SchDoc, desMap, Prefix, today);
                except
                    PM_Log('writeback: failed on ' + doc.DM_FullPath);
                end;
            end;
        end;

        Result := total;
    finally
        resultByKey.Free;
        desMap.Free;
    end;
end;
