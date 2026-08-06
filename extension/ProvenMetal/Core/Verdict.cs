namespace ProvenMetal.Core
{
    // Client-side mirror of the server verdict rule (src/lib/kicad/verdict.ts).
    // The server is authoritative; this exists for a local/defensive re-compute.
    // Stock/lead of null means "unknown".
    public static class Verdict
    {
        public const int SourceableWithinDays = 7;

        public static string For(string sourceStatus, int? stock, int? leadTimeDays, int requiredQty)
        {
            if (requiredQty < 1) requiredQty = 1;
            bool inStock = stock.HasValue && stock.Value >= requiredQty;
            bool sourceable = leadTimeDays.HasValue && leadTimeDays.Value <= SourceableWithinDays;

            if (inStock || sourceable) return "pass";
            if (sourceStatus == "unmatched") return "fail";

            bool noData = !stock.HasValue && !leadTimeDays.HasValue;
            if (sourceStatus == "manual" || string.IsNullOrEmpty(sourceStatus) || noData) return "review";
            return "fail";
        }
    }
}
