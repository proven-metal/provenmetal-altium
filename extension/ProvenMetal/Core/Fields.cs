using System;
using System.Collections.Generic;

namespace ProvenMetal.Core
{
    // Candidate Altium parameter names per canonical BOM column. Mirrors the
    // KiCad plugin's fields.py. Special tokens (#COMMENT / #FOOTPRINT /
    // #DESCRIPTION) are resolved from component/part attributes in BomExtractor.
    public static class Fields
    {
        public static readonly string[] Canonical =
        {
            "value", "footprint", "mpn", "manufacturer", "lcsc",
            "digikey", "mouser", "description"
        };

        private static string[] Candidates(string canonical)
        {
            switch (canonical)
            {
                case "value":        return new[] { "#COMMENT", "Value" };
                case "footprint":    return new[] { "#FOOTPRINT", "Footprint" };
                case "mpn":          return new[] { "MPN", "Manufacturer Part Number", "MFR#", "Mfr Part #", "Part Number", "MPN1", "Manufacturer Part Number 1" };
                case "manufacturer": return new[] { "Manufacturer", "Mfr", "MFN", "Mfg", "Manufacturer 1" };
                case "lcsc":         return new[] { "LCSC", "LCSC Part #", "LCSC Part Number", "JLCPCB Part #" };
                case "digikey":      return new[] { "Digikey", "Digi-Key", "DigiKey Part Number", "DK Part #" };
                case "mouser":       return new[] { "Mouser", "Mouser Part Number", "Mouser #" };
                case "description":  return new[] { "#DESCRIPTION", "Description", "Desc", "Comments" };
                default:             return new string[0];
            }
        }

        // Candidate names for a canonical column, pinned field-map name first.
        public static List<string> CandidateList(string canonical, string pinned)
        {
            var list = new List<string>();
            if (!string.IsNullOrEmpty(pinned) && pinned.Trim().Length > 0)
                list.Add(pinned.Trim());
            foreach (var c in Candidates(canonical))
                if (!list.Contains(c))
                    list.Add(c);
            return list;
        }
    }
}
