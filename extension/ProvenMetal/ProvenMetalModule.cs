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
                        if (_noGuiMode) throw;
                        MessageBox.Show(ex.Message, "ProvenMetal", MessageBoxButtons.OK, MessageBoxIcon.Hand);
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

            // BOM extraction must run on the UI (COM) thread.
            List<BomLine> lines;
            try
            {
                var rows = BomExtractor.ExtractRows(project, settings);
                lines = Grouping.GroupRows(rows, settings.ExcludeDnp);
            }
            catch (Exception ex)
            {
                Log.Write("BOM extraction failed: " + ex);
                MessageBox.Show(
                    "Could not read the BOM. Compile the project (Project > Compile) and try again.\r\n\r\n" + ex.Message,
                    "ProvenMetal", MessageBoxButtons.OK, MessageBoxIcon.Hand);
                return;
            }

            if (lines.Count == 0)
            {
                MessageBox.Show(
                    "No orderable parts found (every component lacked an MPN, LCSC code and value, or all were DNP / No-BOM).",
                    "ProvenMetal", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            int boardCount = Sidecar.LoadBoardCount(projDir, projName, settings.BoardCount);
            if (boardCount < 1) boardCount = 1;
            string projectId = Sidecar.LoadProjectId(projDir, projName);

            using (var form = new ResultsForm())
            {
                form.Shown += (s, e) =>
                {
                    Task.Run(() =>
                    {
                        try
                        {
                            var client = new CentralClient(settings);
                            SafeInvoke(form, () => { form.SetStatus("Sourcing " + lines.Count + " part(s) ..."); form.AppendLog("Project: " + projName); form.AppendLog("Found " + lines.Count + " orderable part(s)."); });

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
                };

                form.ShowDialog();
            }
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
