using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace ProvenMetal.Core
{
    // Turn raw canonical BOM rows into orderable lines. Direct port of the KiCad
    // plugin's grouping.py so ProvenMetal Central sees identical line shapes.
    //
    // A "row" is a Dictionary<string,string> over the canonical columns
    // (reference, value, footprint, mpn, manufacturer, lcsc, digikey, mouser,
    // description, qty, dnp).
    public static class Grouping
    {
        private static readonly HashSet<string> DnpTrue = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { "1", "true", "yes", "dnp", "x", "y" };

        private static readonly HashSet<string> Placeholders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { "", "-", "--", "n/a", "na", "tbd", "?", "none" };

        private static readonly Regex RangeRe =
            new Regex(@"^([A-Za-z]+)(\d+)\s*-\s*([A-Za-z]*)(\d+)$", RegexOptions.Compiled);

        public static bool IsPlaceholder(string v)
        {
            string low = (v ?? "").Trim();
            if (Placeholders.Contains(low)) return true;
            // a lone unicode dash used as "none"
            if (low.Length == 1 && low[0] >= 0x2010 && low[0] <= 0x2015) return true;
            return false;
        }

        public static string Clean(string v)
        {
            return IsPlaceholder(v) ? "" : (v ?? "").Trim();
        }

        public static bool IsTruthyDnp(string v)
        {
            return DnpTrue.Contains((v ?? "").Trim());
        }

        public static int ParseIntOr(string v, int dflt)
        {
            string s = (v ?? "").Trim();
            int dot = s.IndexOf('.');
            if (dot >= 0) s = s.Substring(0, dot);
            int n;
            if (int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) return n;
            return dflt;
        }

        // Expand "C11-C18" -> C11..C18; pass anything else through unchanged.
        public static List<string> ExpandRefToken(string token)
        {
            var outp = new List<string>();
            var m = RangeRe.Match((token ?? "").Trim());
            if (!m.Success) { outp.Add(token); return outp; }

            string prefix = m.Groups[1].Value;
            string endPrefix = m.Groups[3].Value;
            if (endPrefix.Length > 0 && endPrefix != prefix) { outp.Add(token); return outp; }

            int start, end;
            if (!int.TryParse(m.Groups[2].Value, out start) || !int.TryParse(m.Groups[4].Value, out end))
            { outp.Add(token); return outp; }
            if (end < start || end - start > 100000) { outp.Add(token); return outp; }

            for (int n = start; n <= end; n++)
                outp.Add(prefix + n.ToString(CultureInfo.InvariantCulture));
            return outp;
        }

        public static List<string> SplitRefs(string value)
        {
            var outp = new List<string>();
            if (string.IsNullOrWhiteSpace(value)) return outp;
            foreach (var raw in Regex.Split(value.Trim(), @"[,\s]+"))
            {
                var tok = raw.Trim();
                if (tok.Length == 0) continue;
                outp.AddRange(ExpandRefToken(tok));
            }
            return outp;
        }

        public static string LineKeyFor(string mpn, string lcsc, string value)
        {
            string v = Clean(mpn);
            if (v.Length > 0) return v.ToLowerInvariant();
            v = Clean(lcsc);
            if (v.Length > 0) return v.ToLowerInvariant();
            v = Clean(value);
            if (v.Length > 0) return v.ToLowerInvariant();
            return null;
        }

        private static string Get(Dictionary<string, string> row, string key)
        {
            string v;
            return row.TryGetValue(key, out v) ? (v ?? "") : "";
        }

        public static List<BomLine> GroupRows(List<Dictionary<string, string>> rows, bool excludeDnp)
        {
            var merged = new Dictionary<string, BomLine>();

            foreach (var row in rows)
            {
                if (excludeDnp && IsTruthyDnp(Get(row, "dnp"))) continue;

                string key = LineKeyFor(Get(row, "mpn"), Get(row, "lcsc"), Get(row, "value"));
                if (key == null) continue;

                var refs = SplitRefs(Get(row, "reference"));
                int qty = ParseIntOr(Get(row, "qty"), refs.Count);
                if (qty < 1) qty = 1;

                BomLine line;
                if (!merged.TryGetValue(key, out line))
                {
                    line = new BomLine
                    {
                        LineKey = key,
                        Mpn = NullIfEmpty(Clean(Get(row, "mpn"))),
                        Manufacturer = NullIfEmpty(Clean(Get(row, "manufacturer"))),
                        Lcsc = NullIfEmpty(Clean(Get(row, "lcsc"))),
                        Value = NullIfEmpty(Clean(Get(row, "value"))),
                        Footprint = NullIfEmpty(Clean(Get(row, "footprint"))),
                        Description = NullIfEmpty(Clean(Get(row, "description"))),
                        Digikey = NullIfEmpty(Clean(Get(row, "digikey"))),
                        Mouser = NullIfEmpty(Clean(Get(row, "mouser"))),
                        QuantityPerBoard = qty
                    };
                    foreach (var r in refs)
                        if (!line.References.Contains(r)) line.References.Add(r);
                    merged[key] = line;
                }
                else
                {
                    foreach (var r in refs)
                        if (!line.References.Contains(r)) line.References.Add(r);
                    line.QuantityPerBoard += qty;

                    line.Mpn = line.Mpn ?? NullIfEmpty(Clean(Get(row, "mpn")));
                    line.Manufacturer = line.Manufacturer ?? NullIfEmpty(Clean(Get(row, "manufacturer")));
                    line.Lcsc = line.Lcsc ?? NullIfEmpty(Clean(Get(row, "lcsc")));
                    line.Value = line.Value ?? NullIfEmpty(Clean(Get(row, "value")));
                    line.Footprint = line.Footprint ?? NullIfEmpty(Clean(Get(row, "footprint")));
                    line.Description = line.Description ?? NullIfEmpty(Clean(Get(row, "description")));
                    line.Digikey = line.Digikey ?? NullIfEmpty(Clean(Get(row, "digikey")));
                    line.Mouser = line.Mouser ?? NullIfEmpty(Clean(Get(row, "mouser")));
                }
            }

            var list = new List<BomLine>(merged.Values);
            list.Sort((a, b) =>
            {
                string fa = a.References.Count > 0 ? a.References[0] : "";
                string fb = b.References.Count > 0 ? b.References[0] : "";
                int c = string.CompareOrdinal(fa, fb);
                return c != 0 ? c : string.CompareOrdinal(a.LineKey, b.LineKey);
            });
            return list;
        }

        private static string NullIfEmpty(string s)
        {
            return string.IsNullOrEmpty(s) ? null : s;
        }
    }
}
