using ProvenMetal.Core;
using Xunit;

namespace ProvenMetal.Core.Tests
{
    // Mirrors the KiCad plugin's tests/test_verdict.py so both plugins compute the
    // same pass / review / fail verdict for identical inputs. The server verdict is
    // authoritative; this is the client-side re-compute (Verdict.For).
    public class VerdictTests
    {
        [Fact]
        public void InStockForFullBuildPasses()
        {
            Assert.Equal("pass", Verdict.For("matched", 100, 60, 100));
        }

        [Fact]
        public void StockBelowRequiredIsNotInStock()
        {
            Assert.Equal("fail", Verdict.For("matched", 99, 60, 100));
        }

        [Fact]
        public void SourceableWithinAWeekPasses()
        {
            Assert.Equal("pass", Verdict.For("matched", 0, Verdict.SourceableWithinDays, 10));
            Assert.Equal("fail", Verdict.For("matched", 0, Verdict.SourceableWithinDays + 1, 10));
        }

        [Fact]
        public void UnmatchedFails()
        {
            Assert.Equal("fail", Verdict.For("unmatched", null, null, 1));
        }

        [Theory]
        [InlineData("manual")]
        [InlineData("matched")]
        [InlineData(null)]
        [InlineData("")]
        public void ManualOrUnknownIsReview(string sourceStatus)
        {
            Assert.Equal("review", Verdict.For(sourceStatus, null, null, 1));
        }

        [Fact]
        public void PartialStockUnknownLeadFails()
        {
            Assert.Equal("fail", Verdict.For("matched", 3, null, 10));
        }

        [Fact]
        public void RequiredQtyBelowOneIsCoercedToOne()
        {
            // A single unit in stock covers a "0" (or negative) required build qty.
            Assert.Equal("pass", Verdict.For("matched", 1, null, 0));
        }
    }
}
