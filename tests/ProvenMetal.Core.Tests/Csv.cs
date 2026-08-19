using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ProvenMetal.Core.Tests
{
    // Tiny RFC-4180-ish CSV reader, just enough to load the shared BOM fixture
    // (quoted fields with embedded commas, e.g. reference lists like "C1,C2,C3").
    internal static class Csv
    {
        public static List<Dictionary<string, string>> ReadDicts(string path)
        {
            var rows = new List<Dictionary<string, string>>();
            using (var reader = new StreamReader(path, Encoding.UTF8))
            {
                string headerLine = reader.ReadLine();
                if (headerLine == null) return rows;
                var headers = ParseLine(headerLine);

                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (line.Length == 0) continue;
                    var cells = ParseLine(line);
                    var d = new Dictionary<string, string>();
                    for (int i = 0; i < headers.Count; i++)
                        d[headers[i]] = i < cells.Count ? cells[i] : "";
                    rows.Add(d);
                }
            }
            return rows;
        }

        private static List<string> ParseLine(string line)
        {
            var cells = new List<string>();
            var sb = new StringBuilder();
            bool inQuotes = false;
            for (int i = 0; i < line.Length; i++)
            {
                char c = line[i];
                if (inQuotes)
                {
                    if (c == '"')
                    {
                        if (i + 1 < line.Length && line[i + 1] == '"') { sb.Append('"'); i++; }
                        else inQuotes = false;
                    }
                    else sb.Append(c);
                }
                else
                {
                    if (c == '"') inQuotes = true;
                    else if (c == ',') { cells.Add(sb.ToString()); sb.Clear(); }
                    else sb.Append(c);
                }
            }
            cells.Add(sb.ToString());
            return cells;
        }
    }
}
