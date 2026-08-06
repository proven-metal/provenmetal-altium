{..............................................................................}
{ MakeSampleBom.pas                                                             }
{                                                                              }
{ Places a handful of sample components (with Designator, Value, MPN,           }
{ Manufacturer, LCSC parameters) onto the CURRENTLY OPEN schematic, so you have }
{ a real BOM to test the ProvenMetal extension against.                         }
{                                                                              }
{ Usage:                                                                        }
{   1. File > New > Project > PCB Project  (name it e.g. ProvenMetalTest).       }
{   2. Right-click the project > Add New to Project > Schematic.                 }
{   3. With that blank schematic active: DXP/File > Run Script... and pick       }
{      MakeSampleBom.pas > MakeProvenMetalSampleBOM.                             }
{   4. Ctrl+S to save all, then Project > Compile PCB Project.                   }
{   5. Tools > Source with ProvenMetal.                                          }
{..............................................................................}


procedure AddParam(Comp : ISch_Component; const AName, AValue : String);
var
    Param : ISch_Parameter;
begin
    if (AValue = '') then Exit;
    Param := Comp.AddSchParameter;
    Param.SetState_Name(AName);
    Param.SetState_Text(AValue);
    Param.SetState_ShowName(False);
    Param.SetState_IsHidden(False);
end;


procedure PlaceComp(Doc : ISch_Document; const Designator, LibRef, Value, Mpn, Mfr, Lcsc : String; XMils : Integer);
var
    Comp : ISch_Component;
begin
    Comp := SchServer.SchObjectFactory(eSchComponent, eCreate_GlobalCopy);
    if Comp = nil then Exit;

    Comp.SetState_CurrentPartID(1);
    Comp.SetState_DisplayMode(0);
    Comp.SetState_LibReference(LibRef);
    Comp.GetState_SchDesignator.SetState_Text(Designator);
    Comp.SetState_ComponentDescription(Value);

    AddParam(Comp, 'Value', Value);
    AddParam(Comp, 'MPN', Mpn);
    AddParam(Comp, 'Manufacturer', Mfr);
    AddParam(Comp, 'LCSC', Lcsc);

    Doc.AddSchObject(Comp);
    Comp.MoveToXY(MilsToCoord(XMils), MilsToCoord(1000));
end;


procedure MakeProvenMetalSampleBOM;
var
    Doc : ISch_Document;
begin
    if SchServer = nil then
    begin
        ShowError('Schematic server not available.');
        Exit;
    end;

    Doc := SchServer.GetCurrentSchDocument;
    if Doc = nil then
    begin
        ShowError('Open a schematic first (New > Project > PCB Project, then Add New to Project > Schematic), then run this script.');
        Exit;
    end;

    SchServer.ProcessControl.PreProcess(Doc, '');
    try
        { Two identical resistors -> group to qty 2. MPN + LCSC. }
        PlaceComp(Doc, 'R1', 'Res', '10k',   'RC0402FR-0710KL',   'Yageo',            'C25744',  1000);
        PlaceComp(Doc, 'R2', 'Res', '10k',   'RC0402FR-0710KL',   'Yageo',            'C25744',  2000);
        { Capacitors with MPN (+ one with LCSC). }
        PlaceComp(Doc, 'C1', 'Cap', '100nF', 'CL05B104KO5NNNC',   'Samsung',          'C1525',   3000);
        PlaceComp(Doc, 'C2', 'Cap', '10uF',  'GRM188R61C106KAALD','Murata',           '',        4000);
        { An MCU. }
        PlaceComp(Doc, 'U1', 'IC',  'MCU',   'STM32H743VIT6',     'STMicroelectronics','',       5000);
        { A connector with no MPN -> should come back as review/value-sourced. }
        PlaceComp(Doc, 'J1', 'Header', '1x4 Header', '', '', '', 6000);
    finally
        SchServer.ProcessControl.PostProcess(Doc, '');
    end;

    Doc.GraphicallyInvalidate;
    ShowMessage('Placed 6 sample components (R1, R2, C1, C2, U1, J1).' + #13#10 +
                'Now: Ctrl+S to save, Project > Compile PCB Project, then Tools > Source with ProvenMetal.');
end;
