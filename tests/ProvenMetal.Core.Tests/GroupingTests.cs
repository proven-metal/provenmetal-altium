using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using ProvenMetal.Core;
using Xunit;

namespace ProvenMetal.Core.Tests
{
    // Analogue of the KiCad plugin's tests/test_grouping.py. Grouping turns raw
    // canonical rows into orderable lines; it must produce identical line shapes to
    // the KiCad plugin so ProvenMetal Central sees the same BOM either way.
    //
    // In the Altium port, BomExtractor already coalesces per-component parameters
    // into canonical columns, so the grouping input here is canonical rows (unlike
    // the KiCad CSV, which still carries mpn/mpn__1 secondary variants).
    public class GroupingTests
    {
        private static Dictionary<string, string> Row(
            string reference, string value = "", string footprint = "", string mpn = "",
            string manufacturer = "", string lcsc = "", string digikey = "", string mouser = "",
            string description = "", string qty = "", string dnp = "")
        {
            return new Dictionary<string, string>
            {
                ["reference"] = reference,
                ["value"] = value,
                ["footprint"] = footprint,
                ["mpn"] = mpn,
                ["manufacturer"] = manufacturer,
                ["lcsc"] = lcsc,
                ["digikey"] = digikey,
                ["mouser"] = mouser,
                ["description"] = description,
                ["qty"] = qty,
                ["dnp"] = dnp,
            };
        }

        // The coalesced equivalent of the KiCad sample_export.csv fixture.
        private static List<Dictionary<string, string>> SampleRows() => new List<Dictionary<string, string>>
        {
            Row("R1,R2", value: "10k", footprint: "R_0402_1005Metric", mpn: "RC0402FR-0710KL", manufacturer: "Yageo", lcsc: "C60490", qty: "2"),
            Row("R3",    value: "10k", footprint: "R_0402_1005Metric", mpn: "RC0402FR-0710KL", manufacturer: "Yageo", lcsc: "C60490", qty: "1"),
            Row("C1,C2,C3", value: "100n", footprint: "C_0402_1005Metric", lcsc: "C1525", qty: "3"),
            Row("U1", value: "MCU", footprint: "LQFP-100", mpn: "STM32H743VIT6", manufacturer: "STMicroelectronics", digikey: "497-1234-ND", mouser: "511-STM32", qty: "1"),
            Row("TP1", value: "TP", footprint: "TestPoint_Pad_D1.0mm", qty: "1", dnp: "DNP"),
            Row("J1", qty: "1"),
        };

        private static Dictionary<string, BomLine> ByKey(IEnumerable<BomLine> lines)
            => lines.ToDictionary(l => l.LineKey);

        // --- sample scenario -----------------------------------------------------

        [Fact]
        public void DnpAndEmptyLinesDropped()
        {
            var lines = Grouping.GroupRows(SampleRows(), excludeDnp: true);
            // TP1 is DNP, J1 has nothing orderable -> 3 real lines remain.
            Assert.Equal(3, lines.Count);
        }

        [Fact]
        public void DuplicateMpnRowsMerge()
        {
            var line = ByKey(Grouping.GroupRows(SampleRows(), true))["rc0402fr-0710kl"];
            Assert.Equal(3, line.QuantityPerBoard); // R1,R2 + R3
            var refs = line.References.OrderBy(r => r).ToArray();
            Assert.Equal(new[] { "R1", "R2", "R3" }, refs);
        }

        [Fact]
        public void LcscOnlyLineKeyedByLcsc()
        {
            var byKey = ByKey(Grouping.GroupRows(SampleRows(), true));
            Assert.True(byKey.ContainsKey("c1525"));
            var line = byKey["c1525"];
            Assert.Null(line.Mpn);
            Assert.Equal("C1525", line.Lcsc);
            Assert.Equal(3, line.QuantityPerBoard);
        }

        [Fact]
        public void DistributorMetadataCarriedThrough()
        {
            var line = ByKey(Grouping.GroupRows(SampleRows(), true))["stm32h743vit6"];
            Assert.Equal("STM32H743VIT6", line.Mpn);
            Assert.Equal("497-1234-ND", line.Digikey);
            Assert.Equal("511-STM32", line.Mouser);
        }

        [Fact]
        public void DnpLinesKeptWhenExcludeDnpIsFalse()
        {
            var lines = Grouping.GroupRows(SampleRows(), excludeDnp: false);
            // TP1 (DNP) now survives; J1 is still dropped (nothing orderable).
            Assert.Equal(4, lines.Count);
        }

        // --- reference-token helpers --------------------------------------------

        [Fact]
        public void ReferenceRangesExpand()
        {
            Assert.Equal(
                new[] { "C2", "C8", "C11", "C12", "C13", "C14", "C15", "C16", "C17", "C18" },
                Grouping.SplitRefs("C2,C8,C11-C18").ToArray());
            Assert.Equal(
                new[] { "D2", "D3", "D4", "D5", "D6", "D7", "D8" },
                Grouping.SplitRefs("D2-D8").ToArray());
            // A non-range token passes through untouched.
            Assert.Equal(new[] { "U1" }, Grouping.SplitRefs("U1").ToArray());
        }

        [Fact]
        public void LineKeyPrecedenceIsMpnThenLcscThenValue()
        {
            Assert.Equal("abc", Grouping.LineKeyFor("ABC", "C1", "10k"));
            Assert.Equal("c1", Grouping.LineKeyFor("", "C1", "10k"));
            Assert.Equal("10k", Grouping.LineKeyFor("", "", "10k"));
            Assert.Null(Grouping.LineKeyFor("", "", ""));
        }

        [Fact]
        public void PlaceholderValuesAreNotOrderable()
        {
            // A row whose only "identity" is a placeholder value has no line key.
            Assert.Null(Grouping.LineKeyFor("", "", "N/A"));
            Assert.True(Grouping.IsPlaceholder("tbd"));
            Assert.False(Grouping.IsPlaceholder("10k"));
        }

        // --- real BOM fixture ----------------------------------------------------

        private static List<Dictionary<string, string>> RealBomRows()
        {
            string path = Path.Combine(AppContext.BaseDirectory, "fixtures", "FlightControllerV1_MPN.csv");
            var mapping = new Dictionary<string, string>
            {
                ["Reference"] = "reference",
                ["Qty"] = "qty",
                ["Value"] = "value",
                ["Footprint"] = "footprint",
                ["LCSC Part #"] = "lcsc",
                ["MPN"] = "mpn",
            };
            var rows = new List<Dictionary<string, string>>();
            foreach (var raw in Csv.ReadDicts(path))
            {
                var row = new Dictionary<string, string>();
                foreach (var kv in mapping)
                    row[kv.Value] = raw.TryGetValue(kv.Key, out var v) ? (v ?? "") : "";
                rows.Add(row);
            }
            return rows;
        }

        [Fact]
        public void RealBomProducesManyLines()
        {
            Assert.True(Grouping.GroupRows(RealBomRows(), true).Count > 10);
        }

        [Fact]
        public void RealBomGroupsThe100nCapacitor()
        {
            var line = Grouping.GroupRows(RealBomRows(), true)
                .Single(l => l.Mpn == "CL05B104KO5NNNC");
            Assert.Equal(21, line.QuantityPerBoard);
            Assert.Equal(21, line.References.Count);
            Assert.Equal("C1525", line.Lcsc);
        }
    }
}
