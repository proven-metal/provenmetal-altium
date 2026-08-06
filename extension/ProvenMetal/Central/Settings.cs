using System;
using System.Collections.Generic;
using System.IO;
using Newtonsoft.Json.Linq;
using ProvenMetal.Core;

namespace ProvenMetal.Central
{
    // User settings, persisted at %APPDATA%\provenmetal-altium\settings.json.
    // The only setting most people touch is base_url; login details come from the
    // server. Mirrors the KiCad plugin's settings.
    public class Settings
    {
        public string BaseUrl = "https://central.provenmetal.com";
        public string OAuthProvider = "google";
        public int BoardCount = 1;
        public bool ExcludeDnp = true;
        public bool Writeback = false;
        public string WritebackFieldPrefix = "PM";
        public bool Debug = false;
        public Dictionary<string, string> FieldMap = new Dictionary<string, string>();

        public static Settings Load()
        {
            var s = new Settings();
            string path = Path.Combine(Util.SettingsDir(), "settings.json");
            if (!File.Exists(path)) return s;

            try
            {
                var j = JObject.Parse(File.ReadAllText(path));
                if (j["base_url"] != null) s.BaseUrl = ((string)j["base_url"] ?? s.BaseUrl).TrimEnd('/');
                if (j["oauth_provider"] != null) s.OAuthProvider = (string)j["oauth_provider"] ?? s.OAuthProvider;
                if (j["board_count"] != null) s.BoardCount = (int)j["board_count"];
                if (j["exclude_dnp"] != null) s.ExcludeDnp = (bool)j["exclude_dnp"];
                if (j["writeback"] != null) s.Writeback = (bool)j["writeback"];
                if (j["writeback_field_prefix"] != null) s.WritebackFieldPrefix = (string)j["writeback_field_prefix"] ?? s.WritebackFieldPrefix;
                if (j["debug"] != null) s.Debug = (bool)j["debug"];

                var fm = j["field_map"] as JObject;
                if (fm != null)
                    foreach (var p in fm.Properties())
                        s.FieldMap[p.Name] = (string)p.Value;
            }
            catch (Exception ex) { Log.Write("settings load failed: " + ex.Message); }

            return s;
        }
    }

    // The <project>.provenmetal.json sidecar links an Altium project to its
    // ProvenMetal Central project id. Safe to commit alongside the design.
    public static class Sidecar
    {
        private static string PathFor(string projectDir, string projectName)
            => Path.Combine(projectDir, projectName + ".provenmetal.json");

        public static string LoadProjectId(string projectDir, string projectName)
        {
            try
            {
                string p = PathFor(projectDir, projectName);
                if (!File.Exists(p)) return "";
                var j = JObject.Parse(File.ReadAllText(p));
                return (string)j["projectId"] ?? "";
            }
            catch { return ""; }
        }

        public static int LoadBoardCount(string projectDir, string projectName, int dflt)
        {
            try
            {
                string p = PathFor(projectDir, projectName);
                if (!File.Exists(p)) return dflt;
                var j = JObject.Parse(File.ReadAllText(p));
                return j["boardCount"] != null ? (int)j["boardCount"] : dflt;
            }
            catch { return dflt; }
        }

        public static void Save(string projectDir, string projectName, string projectId, string reference, int boardCount)
        {
            var j = new JObject { ["projectId"] = projectId };
            if (!string.IsNullOrEmpty(reference)) j["ref"] = reference;
            if (boardCount > 0) j["boardCount"] = boardCount;
            File.WriteAllText(PathFor(projectDir, projectName), j.ToString(Newtonsoft.Json.Formatting.Indented) + "\n");
        }
    }
}
