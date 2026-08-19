using System.Collections.Generic;
using ProvenMetal.Core;
using Xunit;

namespace ProvenMetal.Core.Tests
{
    // Analogue of the KiCad plugin's tests/test_fields.py. The KiCad plugin emits a
    // kicad-cli field spec; the Altium port instead walks a candidate list of
    // parameter names per canonical column (Fields.CandidateList), so these tests
    // assert that candidate ordering, the pinned field_map override, and the
    // component-attribute special tokens behave.
    public class FieldsTests
    {
        [Fact]
        public void CanonicalColumnsCoverEveryOrderableField()
        {
            var set = new HashSet<string>(Fields.Canonical);
            Assert.Contains("value", set);
            Assert.Contains("footprint", set);
            Assert.Contains("mpn", set);
            Assert.Contains("manufacturer", set);
            Assert.Contains("lcsc", set);
            Assert.Contains("digikey", set);
            Assert.Contains("mouser", set);
            Assert.Contains("description", set);
        }

        [Fact]
        public void MpnCandidatesIncludeCommonAltiumNames()
        {
            var c = Fields.CandidateList("mpn", null);
            Assert.Equal("MPN", c[0]);
            Assert.Contains("Manufacturer Part Number", c);
            Assert.Contains("Part Number", c);
        }

        [Fact]
        public void PinnedFieldMapNameIsTriedFirst()
        {
            var c = Fields.CandidateList("mpn", "My Part Number");
            Assert.Equal("My Part Number", c[0]);
            // The built-in candidates still follow the pinned name.
            Assert.Contains("MPN", c);
        }

        [Fact]
        public void PinnedNameEqualToABuiltinIsNotDuplicated()
        {
            var c = Fields.CandidateList("mpn", "MPN");
            Assert.Equal("MPN", c[0]);
            Assert.Single(c, x => x == "MPN");
        }

        [Fact]
        public void WhitespaceOnlyPinnedNameIsIgnored()
        {
            var c = Fields.CandidateList("lcsc", "   ");
            Assert.Equal("LCSC", c[0]);
        }

        [Theory]
        [InlineData("value", "#COMMENT")]
        [InlineData("footprint", "#FOOTPRINT")]
        [InlineData("description", "#DESCRIPTION")]
        public void AttributeBackedColumnsLeadWithTheirSpecialToken(string canonical, string token)
        {
            var c = Fields.CandidateList(canonical, null);
            Assert.Equal(token, c[0]);
        }

        [Fact]
        public void UnknownCanonicalYieldsNoCandidates()
        {
            Assert.Empty(Fields.CandidateList("not-a-column", null));
        }
    }
}
