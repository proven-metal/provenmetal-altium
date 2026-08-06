using System;
using System.Collections.Generic;
using DXP;
using EDP;
using ProvenMetal.Core;
using ProvenMetal.Central;

namespace ProvenMetal.Altium
{
    // Read the BOM from the focused project via the Design Manager (Workspace
    // Manager) API - the C# analogue of the DelphiScript DM extraction and of
    // KiCad's `kicad-cli sch export bom`. We compile the project and read its
    // flattened pseudo-schematic; each flattened component becomes one row.
    //
    // In the C# SDK the DM_* members are exposed as METHODS (extension methods on
    // the interfaces), so they are all invoked with ().
    public static class BomExtractor
    {
        public static IProject GetFocusedProject()
        {
            var ws = AltiumApi.Workspace;
            return ws == null ? null : ws.DM_FocusedProject();
        }

        // Read all of a component's parameters once into a name->value map.
        private static Dictionary<string, string> ReadParams(IComponent comp)
        {
            var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            int pc;
            try { pc = comp.DM_ParameterCount(); } catch { return d; }
            for (int i = 0; i < pc; i++)
            {
                try
                {
                    IParameter p = comp.DM_Parameters(i);
                    if (p == null) continue;
                    string nm = p.DM_Name();
                    if (!string.IsNullOrEmpty(nm) && !d.ContainsKey(nm))
                        d[nm] = p.DM_Value() ?? "";
                }
                catch { }
            }
            return d;
        }

        private static string MapGet(Dictionary<string, string> map, string key)
        {
            string v;
            return map.TryGetValue(key, out v) ? (v ?? "") : "";
        }

        private static string SafeFootprint(IPart part)
        {
            try { return part.DM_Footprint() ?? ""; } catch { return ""; }
        }

        private static string SafeDescription(IPart part)
        {
            try { return part.DM_Description() ?? ""; } catch { return ""; }
        }

        private static string ReadCanonical(Dictionary<string, string> pmap, IPart part, string canonical, Settings settings)
        {
            string pinned;
            settings.FieldMap.TryGetValue(canonical, out pinned);
            foreach (var cand in Fields.CandidateList(canonical, pinned))
            {
                string v;
                if (cand == "#FOOTPRINT") v = SafeFootprint(part);
                else if (cand == "#DESCRIPTION")
                {
                    v = MapGet(pmap, "Description");
                    if (v.Trim().Length == 0) v = SafeDescription(part);
                }
                else if (cand == "#COMMENT") v = MapGet(pmap, "Comment");
                else v = MapGet(pmap, cand);

                v = (v ?? "").Trim();
                if (v.Length > 0) return v;
            }
            return "";
        }

        private static bool ExcludedFromBom(Dictionary<string, string> pmap)
        {
            string kind = MapGet(pmap, "Component Kind");
            return kind.IndexOf("No BOM", StringComparison.OrdinalIgnoreCase) >= 0
                   || kind == "Graphical" || kind == "Net Tie";
        }

        // Fitted in the current assembly variant? Conservative: a component is
        // fitted UNLESS the active variant explicitly marks it Not Fitted. (The
        // stricter identity check from the reference BOM script wrongly dropped
        // everything when a default "current variant" was present.)
        private static bool ComponentFitted(IComponent comp, IPart part, IProjectVariant variant)
        {
            if (variant == null) return true;
            try
            {
                var variation = variant.DM_FindComponentVariationByDesignator(part.DM_PhysicalDesignator());
                if (variation != null)
                {
                    string kind = "";
                    try { kind = variation.DM_VariationKind().ToString(); } catch { }
                    if (kind.IndexOf("NotFitted", StringComparison.OrdinalIgnoreCase) >= 0) return false;
                }
            }
            catch { }
            return true;
        }

        private static IDocument CompileAndFlatten(IProject project)
        {
            // DM_Compile flattens the project (hierarchy + multi-channel), same as
            // the DelphiScript plugin. If it still yields no flattened doc, the
            // caller surfaces a friendly "compile the project first" message.
            try { project.DM_Compile(); } catch { }

            IDocument flat = null;
            try { flat = project.DM_DocumentFlattened(); } catch { }
            return flat;
        }

        // Returns per-component canonical rows (Dictionary of canonical column -> value).
        public static List<Dictionary<string, string>> ExtractRows(IProject project, Settings settings)
        {
            var rows = new List<Dictionary<string, string>>();
            IDocument flat = CompileAndFlatten(project);
            if (flat == null)
                throw new InvalidOperationException("Could not get the flattened document (compile the project first).");

            IProjectVariant variant = null;
            try { variant = project.DM_CurrentProjectVariant(); } catch { }
            try { Log.Write("variant: " + (variant == null ? "none" : variant.DM_Description())); } catch { Log.Write("variant: (unreadable)"); }

            int count = flat.DM_ComponentCount();
            Log.Write("flattened component count: " + count);
            for (int i = 0; i < count; i++)
            {
                IComponent comp;
                try { comp = flat.DM_Components(i); } catch { continue; }
                if (comp == null) continue;

                IPart part;
                try { part = comp.DM_SubParts(0); } catch { continue; }
                if (part == null) continue;

                var pmap = ReadParams(comp);

                string des;
                try { des = part.DM_PhysicalDesignator() ?? ""; } catch { des = ""; }
                int at = des.IndexOf('@');
                if (at >= 0) des = des.Substring(0, at);

                var row = new Dictionary<string, string>();
                row["reference"] = des;
                row["value"] = ReadCanonical(pmap, part, "value", settings);
                row["footprint"] = ReadCanonical(pmap, part, "footprint", settings);
                row["mpn"] = ReadCanonical(pmap, part, "mpn", settings);
                row["manufacturer"] = ReadCanonical(pmap, part, "manufacturer", settings);
                row["lcsc"] = ReadCanonical(pmap, part, "lcsc", settings);
                row["digikey"] = ReadCanonical(pmap, part, "digikey", settings);
                row["mouser"] = ReadCanonical(pmap, part, "mouser", settings);
                row["description"] = ReadCanonical(pmap, part, "description", settings);
                row["qty"] = "1";
                bool excluded = ExcludedFromBom(pmap);
                bool fitted = ComponentFitted(comp, part, variant);
                row["dnp"] = fitted ? "0" : "1";

                // Verbose per-component dump: opt-in via settings.json {"debug": true}.
                if (settings.Debug && i < 60)
                    Log.Write("comp[" + i + "] des='" + des + "' params=" + pmap.Count +
                              " names=[" + string.Join(",", new List<string>(pmap.Keys).ToArray()) + "]" +
                              " mpn='" + row["mpn"] + "' lcsc='" + row["lcsc"] + "' value='" + row["value"] +
                              "' excluded=" + excluded + " fitted=" + fitted);

                if (excluded) continue;
                if (des.Trim().Length == 0) continue;

                rows.Add(row);
            }

            Log.Write("rows extracted: " + rows.Count);
            return rows;
        }
    }
}
