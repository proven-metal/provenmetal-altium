{..............................................................................}
{ ProvenMetal_UI.pas                                                             }
{                                                                              }
{ User-facing output: a results dialog, a lightweight progress window, error     }
{ reporting, opening the web report, and a debug log. Mirrors the KiCad          }
{ plugin's ui.py. Forms are built at runtime (no .dfm) and use ModalResult so    }
{ no event-handler wiring is needed.                                             }
{..............................................................................}

{ Module-level references to the branded window's controls, so the push loop can }
{ update it live while sourcing runs. }
var
    PM_gForm      : TForm;
    PM_gMemo      : TMemo;
    PM_gStatus    : TLabel;
    PM_gBarTrack  : TPanel;    { indeterminate progress bar: track ... }
    PM_gBarFill   : TPanel;    { ... and moving fill segment }
    PM_gOpen      : TButton;
    PM_gClose     : TButton;
    PM_gChipX     : Integer;   { running x for count chips }
    PM_gReportUrl : String;


{ Append a timestamped line to %APPDATA%\provenmetal-altium\last-run.log. }
procedure PM_Log(const Msg : String);
var
    f    : TStringList;
    path : String;
begin
    try
        path := PM_SettingsDir + 'last-run.log';
        f := TStringList.Create;
        try
            if FileExists(path) then f.LoadFromFile(path);
            f.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss ', Now) + Msg);
            f.SaveToFile(path);
        finally
            f.Free;
        end;
    except
    end;
end;


{ Open a URL in the user's default browser. }
procedure PM_OpenUrl(const Url : String);
begin
    if Trim(Url) = '' then Exit;
    try
        PM_Shell.Run('cmd /c start "" "' + Url + '"', 0, False);
    except
    end;
end;


procedure PM_ShowError(const Msg : String);
begin
    PM_Log('ERROR: ' + Msg);
    try
        ShowError(Msg);
    except
        ShowMessage('ProvenMetal error: ' + Msg);
    end;
end;


{ n-th tab-separated field (1-based) of S, or '' if absent. }
function PM_TabField(const S : String; N : Integer) : String;
var
    i      : Integer;
    field  : Integer;
    cur    : String;
    c      : Char;
begin
    Result := '';
    field := 1;
    cur := '';
    for i := 1 to Length(S) + 1 do
    begin
        if i <= Length(S) then c := S[i] else c := #9;   { flush trailing field }
        if c = #9 then
        begin
            if field = N then begin Result := cur; Exit; end;
            field := field + 1;
            cur := '';
        end
        else
            cur := cur + c;
    end;
end;


{ Build the plain-text summary shown in the dialog (and logged). }
function PM_BuildSummaryText(R : TStringList) : String;
var
    sb       : TStringList;
    i        : Integer;
    raw      : String;
    val      : String;
    ref      : String;
    part     : String;
    verdict  : String;
    reason   : String;
    header   : String;
    status   : String;
    shown    : Integer;
    flagged  : Integer;
begin
    sb := TStringList.Create;

    header := 'ProvenMetal sourcing';
    if R.Values['REF'] <> '' then
        header := header + ' (' + R.Values['REF'] + ')';
    sb.Add(header);
    sb.Add('Parts: ' + R.Values['SUMMARY_TOTAL'] +
           '    Pass: ' + R.Values['SUMMARY_PASS'] +
           '    Needs review: ' + R.Values['SUMMARY_REVIEW'] +
           '    Fail: ' + R.Values['SUMMARY_FAIL']);

    status := R.Values['STATUS'];
    if status = 'no-sourcing' then
        sb.Add('Note: sourcing service not configured on the server - BOM stored, not sourced.')
    else if status = 'degraded' then
        sb.Add('Note: sourcing was degraded (timed out) - some lines may need a re-check.');

    if R.Values['SOURCING_ERROR'] <> '' then
        sb.Add('Sourcing note: ' + R.Values['SOURCING_ERROR']);

    { warnings (repeatable WARN= lines) }
    for i := 0 to R.Count - 1 do
    begin
        raw := R[i];
        if Copy(raw, 1, 5) = 'WARN=' then
            sb.Add('Warning: ' + Copy(raw, 6, Length(raw)));
    end;

    { flagged lines (fail / review), up to 15 }
    flagged := 0;
    shown := 0;
    for i := 0 to R.Count - 1 do
    begin
        raw := R[i];
        if Copy(raw, 1, 5) = 'LINE=' then
        begin
            { LINE fields: 1 line_key, 2 verdict, 3 reference, 4 part, 5 stock, }
            { 6 lead, 7 reqQty, 8 supplier, 9 sourceStatus, 10 reason.          }
            val := Copy(raw, 6, Length(raw));
            verdict := PM_TabField(val, 2);
            if (verdict = 'fail') or (verdict = 'review') then
            begin
                flagged := flagged + 1;
                if shown < 15 then
                begin
                    if shown = 0 then
                    begin
                        sb.Add('');
                        sb.Add('Needs attention:');
                    end;
                    ref     := PM_TabField(val, 3);
                    part    := PM_TabField(val, 4);
                    reason  := PM_TabField(val, 10);
                    sb.Add('  [' + UpperCase(verdict) + '] ' + ref + '  ' + part + '  ' + reason);
                    shown := shown + 1;
                end;
            end;
        end;
    end;
    if (flagged > 15) then
        sb.Add('  ... and ' + IntToStr(flagged - 15) + ' more');
    if flagged = 0 then
        sb.Add('All parts are in stock or sourceable within a week.');

    sb.Add('');
    sb.Add('Full report: ' + R.Values['REPORT_URL']);

    Result := sb.Text;
    sb.Free;
end;


{ --------------------------------------------------------------------------- }
{ Branded live-progress + results window (mirrors the KiCad plugin v0.1.7 UX):  }
{ one window that opens immediately, streams progress while sourcing, then      }
{ fills in the verdict. Defense-grade palette: black canvas, bone mono type,    }
{ one signal-red for the fail count. Built with runtime controls and driven via }
{ module-level references so the push loop can update it live; interactivity is  }
{ done by polling button ModalResult (no event-handler wiring needed).          }
{ --------------------------------------------------------------------------- }


{ A TColor from RGB (TColor is $00BBGGRR). }
function PM_Color(r, g, b : Integer) : Integer;
begin
    Result := r + (g * 256) + (b * 65536);
end;


{ A small modeless progress window. Returns the form (call PM_CloseProgress). }
function PM_ShowProgress(const Msg : String) : TForm;
var
    frm : TForm;
    lbl : TLabel;
begin
    frm := TForm.Create(nil);
    frm.BorderStyle := bsDialog;
    frm.Caption := 'ProvenMetal';
    frm.Position := poScreenCenter;
    frm.ClientWidth := 420;
    frm.ClientHeight := 90;

    lbl := TLabel.Create(frm);
    lbl.Parent := frm;
    lbl.SetBounds(20, 30, 380, 40);
    lbl.AutoSize := False;
    lbl.WordWrap := True;
    lbl.Caption := Msg;

    frm.Show;
    try
        Application.ProcessMessages;
    except
    end;
    Result := frm;
end;


procedure PM_CloseProgress(Frm : TForm);
begin
    if Frm = nil then Exit;
    try
        Frm.Close;
        Frm.Free;
    except
    end;
end;


{ True while the branded window exists and is on screen (user hasn't closed it). }
function PM_WinAlive : Boolean;
begin
    Result := False;
    if PM_gForm = nil then Exit;
    try
        Result := PM_gForm.Visible;
    except
        Result := False;
    end;
end;


{ Append a line to the window's log (no-op if the window isn't open). }
procedure PM_WinLog(const Msg : String);
begin
    if (PM_gForm = nil) or (PM_gMemo = nil) then Exit;
    try
        PM_gMemo.Lines.Add(Msg);
    except
    end;
end;


{ Set the big status line. }
procedure PM_WinStatus(const Msg : String);
begin
    if PM_gStatus = nil then Exit;
    try
        PM_gStatus.Caption := Msg;
    except
    end;
end;


{ Advance the indeterminate progress bar one step (moving fill segment). }
procedure PM_WinPulse;
begin
    if (PM_gBarTrack = nil) or (PM_gBarFill = nil) then Exit;
    try
        PM_gBarFill.Left := PM_gBarFill.Left + 20;
        if PM_gBarFill.Left > PM_gBarTrack.Width then
            PM_gBarFill.Left := 0 - PM_gBarFill.Width;
    except
    end;
end;


{ Open the branded window and show an initial status. Safe to call once.          }
{ LogoPath is accepted for API parity but not used (text wordmark carries brand). }
procedure PM_WinOpen(const Headline, LogoPath : String);
var
    frm  : TForm;
    word : TLabel;
    sub  : TLabel;
    hair : TPanel;
    cw   : Integer;
    CANVAS, PANEL, BONE, STEEL, LINE : Integer;
begin
    CANVAS := PM_Color(10, 10, 10);
    PANEL  := PM_Color(20, 20, 20);
    BONE   := PM_Color(244, 246, 248);
    STEEL  := PM_Color(154, 167, 176);
    LINE   := PM_Color(45, 45, 45);

    frm := TForm.Create(nil);
    frm.BorderStyle := bsSizeable;
    frm.Caption := 'ProvenMetal Sourcing';
    frm.Position := poScreenCenter;
    frm.ClientWidth := 640;
    frm.ClientHeight := 520;
    frm.Color := CANVAS;
    cw := frm.ClientWidth;

    word := TLabel.Create(frm);
    word.Parent := frm;
    word.SetBounds(20, 18, 400, 26);
    word.Caption := 'PROVENMETAL';
    word.Font.Name := 'Consolas';
    word.Font.Size := 16;
    word.Font.Style := MkSet(fsBold);
    word.Font.Color := BONE;
    word.Transparent := True;

    sub := TLabel.Create(frm);
    sub.Parent := frm;
    sub.SetBounds(22, 48, 400, 16);
    sub.Caption := 'BOM SOURCING';
    sub.Font.Name := 'Consolas';
    sub.Font.Size := 8;
    sub.Font.Color := STEEL;
    sub.Transparent := True;

    hair := TPanel.Create(frm);
    hair.Parent := frm;
    hair.SetBounds(18, 78, cw - 36, 1);
    hair.BevelOuter := bvNone;
    hair.Color := LINE;

    PM_gStatus := TLabel.Create(frm);
    PM_gStatus.Parent := frm;
    PM_gStatus.SetBounds(18, 92, cw - 36, 22);
    PM_gStatus.Caption := Headline;
    PM_gStatus.Font.Name := 'Consolas';
    PM_gStatus.Font.Size := 12;
    PM_gStatus.Font.Style := MkSet(fsBold);
    PM_gStatus.Font.Color := STEEL;
    PM_gStatus.Transparent := True;

    { indeterminate progress bar built from two panels (no TProgressBar dep) }
    PM_gBarTrack := TPanel.Create(frm);
    PM_gBarTrack.Parent := frm;
    PM_gBarTrack.SetBounds(18, 150, cw - 36, 8);
    PM_gBarTrack.BevelOuter := bvNone;
    PM_gBarTrack.Color := LINE;

    PM_gBarFill := TPanel.Create(frm);
    PM_gBarFill.Parent := PM_gBarTrack;
    PM_gBarFill.BevelOuter := bvNone;
    PM_gBarFill.Color := STEEL;
    PM_gBarFill.SetBounds(0, 0, 140, 8);

    PM_gMemo := TMemo.Create(frm);
    PM_gMemo.Parent := frm;
    PM_gMemo.SetBounds(18, 172, cw - 36, 308);
    PM_gMemo.ReadOnly := True;
    PM_gMemo.WordWrap := False;
    PM_gMemo.ScrollBars := ssBoth;
    PM_gMemo.Color := PANEL;
    PM_gMemo.Font.Name := 'Consolas';
    PM_gMemo.Font.Size := 10;
    PM_gMemo.Font.Color := BONE;

    PM_gOpen := TButton.Create(frm);
    PM_gOpen.Parent := frm;
    PM_gOpen.Caption := 'Open report';
    PM_gOpen.SetBounds(cw - 214, 490, 100, 26);
    PM_gOpen.ModalResult := mrYes;
    PM_gOpen.Enabled := False;

    PM_gClose := TButton.Create(frm);
    PM_gClose.Parent := frm;
    PM_gClose.Caption := 'Close';
    PM_gClose.SetBounds(cw - 106, 490, 92, 26);
    PM_gClose.ModalResult := mrOk;
    PM_gClose.Enabled := False;   { enabled once the run finishes }

    PM_gChipX := 18;
    PM_gForm := frm;

    frm.Show;
    try
        frm.ModalResult := 0;
        Application.ProcessMessages;
    except
    end;
end;


{ Add a coloured count chip on the row under the status line. }
procedure PM_WinChip(const Caption : String; ColorVal : Integer);
var
    lbl : TLabel;
begin
    if PM_gForm = nil then Exit;
    lbl := TLabel.Create(PM_gForm);
    lbl.Parent := PM_gForm;
    lbl.AutoSize := True;
    lbl.Caption := Caption;
    lbl.Font.Name := 'Consolas';
    lbl.Font.Size := 13;
    lbl.Font.Style := MkSet(fsBold);
    lbl.Font.Color := ColorVal;
    lbl.Transparent := True;
    lbl.SetBounds(PM_gChipX, 120, lbl.Width, 20);
    PM_gChipX := PM_gChipX + lbl.Width + 22;
end;


{ Fill the window with the sourcing verdict. }
procedure PM_WinFinishOk(R : TStringList);
var
    BONE, STEEL, RED : Integer;
    failN : Integer;
    ref   : String;
begin
    if PM_gForm = nil then Exit;
    BONE  := PM_Color(244, 246, 248);
    STEEL := PM_Color(154, 167, 176);
    RED   := PM_Color(255, 0, 33);

    try
        if PM_gBarFill <> nil then
        begin
            PM_gBarFill.Left := 0;
            PM_gBarFill.Width := PM_gBarTrack.Width;
            PM_gBarFill.Color := BONE;
        end;
        ref := R.Values['REF'];
        if ref <> '' then PM_WinStatus('DONE   ' + ref) else PM_WinStatus('DONE');
        PM_gStatus.Font.Color := BONE;

        PM_WinChip('PARTS ' + R.Values['SUMMARY_TOTAL'], STEEL);
        PM_WinChip('PASS ' + R.Values['SUMMARY_PASS'], BONE);
        PM_WinChip('REVIEW ' + R.Values['SUMMARY_REVIEW'], STEEL);
        failN := StrToIntDef(R.Values['SUMMARY_FAIL'], 0);
        if failN > 0 then
            PM_WinChip('FAIL ' + R.Values['SUMMARY_FAIL'], RED)
        else
            PM_WinChip('FAIL 0', STEEL);

        PM_gMemo.Lines.Add('');
        PM_gMemo.Lines.Text := PM_gMemo.Lines.Text + PM_BuildSummaryText(R);
        PM_gReportUrl := R.Values['REPORT_URL'];
        if PM_gReportUrl <> '' then PM_gOpen.Enabled := True;
        PM_gClose.Enabled := True;
        Application.ProcessMessages;
    except
    end;
end;


{ Put the window into an error state. }
procedure PM_WinFinishError(const Msg : String);
var
    RED : Integer;
begin
    if PM_gForm = nil then Exit;
    RED := PM_Color(255, 0, 33);
    try
        if PM_gBarFill <> nil then
        begin
            PM_gBarFill.Left := 0;
            PM_gBarFill.Width := 0;
        end;
        PM_WinStatus('SOMETHING WENT WRONG');
        PM_gStatus.Font.Color := RED;
        PM_gMemo.Lines.Add('');
        PM_gMemo.Lines.Add('ERROR: ' + Msg);
        if PM_gClose <> nil then PM_gClose.Enabled := True;
        Application.ProcessMessages;
    except
    end;
end;


{ Keep the window interactive until the user closes it. "Open report" (mrYes)     }
{ reopens the URL; "Close" (mrOk) or the window [X] ends the loop.                 }
procedure PM_WinInteract;
begin
    if PM_gForm = nil then Exit;
    try
        PM_gForm.ModalResult := 0;
        while PM_WinAlive do
        begin
            Application.ProcessMessages;
            if PM_gForm.ModalResult = mrYes then
            begin
                if PM_gReportUrl <> '' then PM_OpenUrl(PM_gReportUrl);
                PM_gForm.ModalResult := 0;
            end
            else if PM_gForm.ModalResult = mrOk then
                Break;
            Sleep(30);
        end;
    except
    end;
end;


procedure PM_WinClose;
begin
    if PM_gForm = nil then Exit;
    try
        PM_gForm.Close;
        PM_gForm.Free;
    except
    end;
    PM_gForm := nil;
    PM_gMemo := nil;
    PM_gStatus := nil;
    PM_gBarTrack := nil;
    PM_gBarFill := nil;
    PM_gOpen := nil;
    PM_gClose := nil;
end;
