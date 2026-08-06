using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace ProvenMetal.Core
{
    // One orderable line pushed to ProvenMetal Central (mirrors the KiCad/Altium
    // plugin line shape).
    public class BomLine
    {
        public string LineKey;
        public List<string> References = new List<string>();
        public string Mpn;
        public string Manufacturer;
        public string Lcsc;
        public string Value;
        public string Footprint;
        public string Description;
        public string Digikey;
        public string Mouser;
        public int QuantityPerBoard = 1;
    }

    // One line of the server's verdict.
    public class ResultLine
    {
        public string LineKey;
        public string Verdict;      // pass | review | fail
        public string Reference;
        public string Part;         // mpn || lcsc || line_key
        public string Stock;        // kept as string ("" = unknown)
        public string Lead;
        public string RequiredQty;
        public string Supplier;
        public string SourceStatus;
        public string Reason;
    }

    // The result of a push.
    public class RunResult
    {
        public string ProjectId = "";
        public string Ref = "";
        public string ReportUrl = "";
        public string Status = "unknown";     // sourced | degraded | no-sourcing
        public string SourcingError = "";
        public int Total, Pass, Review, Fail;
        public List<ResultLine> Lines = new List<ResultLine>();
        public List<string> Warnings = new List<string>();
    }

    public static class Util
    {
        public static string SettingsDir()
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "provenmetal-altium");
            try { Directory.CreateDirectory(dir); } catch { }
            return dir;
        }

        public static void OpenUrl(string url)
        {
            if (string.IsNullOrEmpty(url)) return;
            try
            {
                var psi = new ProcessStartInfo(url) { UseShellExecute = true };
                Process.Start(psi);
            }
            catch { /* best effort */ }
        }
    }

    public static class Log
    {
        private static readonly object _lock = new object();

        public static void Write(string msg)
        {
            try
            {
                lock (_lock)
                {
                    File.AppendAllText(
                        Path.Combine(Util.SettingsDir(), "last-run.log"),
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + msg + Environment.NewLine);
                }
            }
            catch { /* never let logging fail the run */ }
        }
    }
}
