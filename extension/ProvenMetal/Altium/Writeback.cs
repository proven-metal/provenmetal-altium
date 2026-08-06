using System;
using System.Collections.Generic;
using ProvenMetal.Core;
#if PM_WRITEBACK
using DXP;
using EDP;
using SCH;
#endif

namespace ProvenMetal.Altium
{
    // Optional: write the verdict back into schematic component parameters
    // (PM_Status / PM_Stock / PM_Lead_Days / PM_Supplier / PM_Checked), matched
    // by designator. Altium analogue of the KiCad plugin's writeback.
    //
    // Gated behind the PM_WRITEBACK compile symbol: the schematic-editing C# API
    // (iterator filters etc.) is the least-verified surface, so it is excluded
    // from the default build to guarantee the core extension always compiles.
    // Enable it by building with /p:DefineConstants=PM_WRITEBACK once the SCH API
    // calls below are confirmed against your Altium version. Off by default.
    public static class Writeback
    {
        public static int Apply(object project, List<BomLine> requestLines, RunResult result, string prefix)
        {
#if PM_WRITEBACK
            return ApplyImpl((IProject)project, requestLines, result, prefix);
#else
            Log.Write("writeback: not enabled in this build (compile with PM_WRITEBACK to turn it on).");
            return 0;
#endif
        }

#if PM_WRITEBACK
        private static int ApplyImpl(IProject project, List<BomLine> requestLines, RunResult result, string prefix)
        {
            if (project == null || result == null || requestLines == null) return 0;
            var sch = AltiumApi.SchServer;
            if (sch == null) return 0;

            // designator -> [verdict, stock, lead, supplier]
            var byKey = new Dictionary<string, string[]>();
            foreach (var ln in result.Lines)
                if (!string.IsNullOrEmpty(ln.LineKey))
                    byKey[ln.LineKey] = new[] { ln.Verdict ?? "", ln.Stock ?? "", ln.Lead ?? "", ln.Supplier ?? "" };

            var desMap = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
            foreach (var line in requestLines)
            {
                string[] data;
                if (line.LineKey == null || !byKey.TryGetValue(line.LineKey, out data)) continue;
                foreach (var r in line.References) desMap[r] = data;
            }

            string today = DateTime.Now.ToString("yyyy-MM-dd");
            int total = 0;

            int docCount = 0;
            try { docCount = project.DM_LogicalDocumentCount(); } catch { }
            for (int i = 0; i < docCount; i++)
            {
                IDocument doc;
                try { doc = project.DM_LogicalDocuments(i); } catch { continue; }
                if (doc == null) continue;

                string kind = "";
                string path = "";
                try { kind = doc.DM_DocumentKind() ?? ""; } catch { }
                try { path = doc.DM_FullPath() ?? ""; } catch { }
                bool isSch = kind == "SCH" || path.ToUpperInvariant().EndsWith(".SCHDOC");
                if (!isSch) continue;

                ISch_Document schDoc;
                try { schDoc = sch.GetSchDocumentByPath(path); } catch { continue; }
                if (schDoc == null) continue;

                try { total += WritebackDoc(schDoc, desMap, prefix, today); }
                catch (Exception ex) { Log.Write("writeback doc failed: " + ex.Message); }
            }
            return total;
        }

        private static int WritebackDoc(ISch_Document doc, Dictionary<string, string[]> desMap, string prefix, string today)
        {
            int n = 0;
            var iter = doc.SchIterator_Create();
            try
            {
                var obj = iter.FirstSchObject();
                while (obj != null)
                {
                    var comp = obj as ISch_Component;
                    if (comp != null)
                    {
                        string des = "";
                        try { des = comp.GetState_SchDesignator().GetState_Text() ?? ""; } catch { }
                        string[] data;
                        if (des.Length > 0 && desMap.TryGetValue(des, out data))
                        {
                            SetParam(comp, prefix + "_Status", data[0]);
                            SetParam(comp, prefix + "_Stock", data[1]);
                            SetParam(comp, prefix + "_Lead_Days", data[2]);
                            SetParam(comp, prefix + "_Supplier", data[3]);
                            SetParam(comp, prefix + "_Checked", today);
                            n++;
                        }
                    }
                    obj = iter.NextSchObject();
                }
            }
            finally
            {
                try { doc.SchIterator_Destroy(iter); } catch { }
            }
            try { doc.GraphicallyInvalidate(); } catch { }
            return n;
        }

        // Update an existing parameter by name, or add it.
        private static void SetParam(ISch_Component comp, string name, string value)
        {
            ISch_Parameter found = null;
            var pit = comp.SchIterator_Create();
            try
            {
                var o = pit.FirstSchObject();
                while (o != null)
                {
                    var p = o as ISch_Parameter;
                    if (p != null)
                    {
                        string pn = "";
                        try { pn = p.GetState_Name() ?? ""; } catch { }
                        if (pn == name) { found = p; break; }
                    }
                    o = pit.NextSchObject();
                }
            }
            finally
            {
                try { comp.SchIterator_Destroy(pit); } catch { }
            }

            if (found != null)
            {
                try { found.SetState_Text(value); found.SetState_IsHidden(true); } catch { }
            }
            else
            {
                try
                {
                    ISch_Parameter np = comp.AddSchParameter();
                    np.SetState_Name(name);
                    np.SetState_Text(value);
                    np.SetState_ShowName(false);
                    np.SetState_IsHidden(true);
                }
                catch { }
            }
        }
#endif
    }
}
