using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using DXP;
using EDP;
using ProvenMetal.Core;
using ProvenMetal.Central;
using ProvenMetal.Altium;
using ProvenMetal.UI;

namespace ProvenMetal
{
    // The ProvenMetal server module. Registers the "SourceBom" command (wired to a
    // menu/toolbar entry by ProvenMetal.rcs) and runs the push-and-source flow.
    [ClassInterface(ClassInterfaceType.AutoDispatch)]
    public class ProvenMetalModule : ServerModule
    {
        private readonly bool _noGuiMode;

        public ProvenMetalModule(IClient client) : base(client, "ProvenMetal")
        {
            _noGuiMode = client.ProductInfo().SupportsUIFeature("NoGUI", false);
        }

        protected override IServerDocument NewDocumentInstance(string argKind, string argFileName)
            => null;

        protected override void InitializeCommands()
            => RegisterCommand("SourceBom", new CommandProc(Run));

        // Wrap the handler so any exception surfaces as a dialog instead of crashing Altium.
        private void RegisterCommand(string commandId, CommandProc proc)
            => ((DXP.CommandLauncher)CommandLauncher).RegisterCommand(commandId,
                (CommandProc)((IServerDocumentView view, ref string parameters) =>
                {
                    try
                    {
                        proc(view, ref parameters);
                    }
                    catch (Exception ex)
                    {
                        Log.Write("command failed: " + ex);
                        if (_noGuiMode) throw;
                        MessageBox.Show(
                            ex.Message + "\r\n\r\nLog: " + Path.Combine(Util.SettingsDir(), "last-run.log"),
                            "ProvenMetal", MessageBoxButtons.OK, MessageBoxIcon.Hand);
                    }
                }));

        private void Run(IServerDocumentView view, ref string parameters)
        {
            Settings settings;
            try { settings = Settings.Load(); } catch { settings = new Settings(); }

            IProject project = BomExtractor.GetFocusedProject();
            if (project == null)
            {
                MessageBox.Show("No focused project. Open a PCB project in Altium and try again.",
                    "ProvenMetal", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string projFull = project.DM_ProjectFullPath();
            string projDir = Path.GetDirectoryName(projFull) ?? "";
            string projName = Path.GetFileNameWithoutExtension(projFull);
            Log.Write("=== SourceBom invoked: " + projName + " ===");

            // Show the window first so the click gives instant feedback. The slow
            // work (compile + flattened-BOM read, then the network push) starts
            // only after the form has painted - see RunPipeline. Extraction has to
            // stay on the UI/COM thread, so it runs via BeginInvoke on the form's
            // thread; the network round-trip then moves to a background task.
            using (var form = new ResultsForm())
            {
                form.Shown += (s, e) =>
                    form.BeginInvoke((Action)(() =>
                        RunPipeline(form, project, projDir, projName, settings)));

                form.ShowDialog();
            }
        }

        // Runs on the UI/COM thread (posted from the form's Shown handler). Does the
        // Altium-side BOM read here, then hands the sourced push to a worker thread.
        private void RunPipeline(ResultsForm form, IProject project, string projDir, string projName, Settings settings)
        {
            List<BomLine> lines;
            try
            {
                form.SetStatus("Reading BOM ...");
                form.AppendLog("Project: " + projName);
                form.AppendLog("Compiling and reading the flattened BOM ...");
                form.Refresh(); // paint "Reading BOM ..." before the compile blocks the UI thread

                var rows = BomExtractor.ExtractRows(project, settings);
                lines = Grouping.GroupRows(rows, settings.ExcludeDnp);
            }
            catch (Exception ex)
            {
                Log.Write("BOM extraction failed: " + ex);
                form.ShowError("Could not read the BOM. Compile the project (Project > Compile) and try again.\r\n" + ex.Message);
                return;
            }

            if (lines.Count == 0)
            {
                form.ShowError("No orderable parts found (every component lacked an MPN, LCSC code and value, or all were DNP / No-BOM).");
                return;
            }

            int boardCount = Sidecar.LoadBoardCount(projDir, projName, settings.BoardCount);
            if (boardCount < 1) boardCount = 1;
            string projectId = Sidecar.LoadProjectId(projDir, projName);

            form.SetStatus("Sourcing " + lines.Count + " part(s) ...");
            form.AppendLog("Found " + lines.Count + " orderable part(s).");

            Task.Run(() =>
            {
                try
                {
                    var client = new CentralClient(settings);
                    RunResult result = client.Push(projName, boardCount, projectId, lines,
                        msg => SafeInvoke(form, () => form.AppendLog(msg)));

                    if (!string.IsNullOrEmpty(result.ProjectId))
                    {
                        try { Sidecar.Save(projDir, projName, result.ProjectId, result.Ref, boardCount); }
                        catch (Exception sx) { Log.Write("sidecar save failed: " + sx.Message); }
                    }

                    SafeInvoke(form, () =>
                    {
                        if (settings.Writeback)
                        {
                            try
                            {
                                int n = Writeback.Apply(project, lines, result, settings.WritebackFieldPrefix);
                                form.AppendLog("Wrote sourcing results into " + n + " component(s).");
                            }
                            catch (Exception wx) { form.AppendLog("Writeback skipped: " + wx.Message); }
                        }
                        if (!string.IsNullOrEmpty(result.ReportUrl)) Util.OpenUrl(result.ReportUrl);
                        form.ShowResults(result);
                    });
                }
                catch (Exception ex)
                {
                    Log.Write("push failed: " + ex);
                    SafeInvoke(form, () => form.ShowError(ex.Message));
                }
            });
        }

        private static void SafeInvoke(Control c, Action action)
        {
            try
            {
                if (c.IsHandleCreated && !c.IsDisposed)
                    c.BeginInvoke(action);
            }
            catch { /* form closing */ }
        }
    }
}
