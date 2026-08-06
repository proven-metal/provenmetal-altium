using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using Newtonsoft.Json.Linq;
using ProvenMetal.Core;

namespace ProvenMetal.Central
{
    public class ApiException : Exception
    {
        public int Status;
        public ApiException(string message, int status = 0) : base(message) { Status = status; }
    }

    // HTTP client for the ProvenMetal Central /api/kicad/* surface. Same contract
    // as the KiCad plugin, so no server changes are required.
    public class CentralClient
    {
        private readonly Settings _settings;
        private readonly string _base;
        private const string ClientVersion = "1.0.0";

        public CentralClient(Settings settings)
        {
            _settings = settings;
            _base = settings.BaseUrl.TrimEnd('/');
        }

        public ServerConfig GetConfig()
        {
            using (var http = Http.NewClient(30))
            {
                HttpResponseMessage resp;
                string body;
                try
                {
                    resp = http.GetAsync(_base + "/api/kicad/config").GetAwaiter().GetResult();
                    body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                }
                catch (Exception ex)
                {
                    throw new ApiException("Couldn't reach ProvenMetal Central at " + _base + ": " + ex.Message);
                }

                if (!resp.IsSuccessStatusCode)
                    throw new ApiException("Config request failed (" + (int)resp.StatusCode + ").", (int)resp.StatusCode);

                var j = JObject.Parse(body);
                string supa = (string)j["supabaseUrl"];
                string anon = (string)j["supabaseAnonKey"];
                if (string.IsNullOrEmpty(supa) || string.IsNullOrEmpty(anon))
                    throw new ApiException("Server did not return Supabase configuration.");

                return new ServerConfig
                {
                    SupabaseUrl = supa.TrimEnd('/'),
                    Anon = anon,
                    AppUrl = ((string)j["appUrl"] ?? _base).TrimEnd('/')
                };
            }
        }

        public RunResult Push(string name, int boardCount, string projectId, List<BomLine> lines, Action<string> progress)
        {
            Report(progress, "Connecting to ProvenMetal Central (" + _base + ") ...");
            var config = GetConfig();

            var auth = new Authenticator(_settings.BaseUrl, _settings.OAuthProvider);
            Report(progress, "Signing in to ProvenMetal ...");
            string token = auth.GetAccessToken(config, true, progress);

            Report(progress, "Pushing " + lines.Count + " part(s) for " + boardCount +
                             " board(s) and sourcing (this can take up to a minute) ...");

            var warnings = new List<string>();
            JObject body = BuildRequest(name, boardCount, projectId, lines);

            var res = DoPost(token, body);

            // Cached session no longer valid: sign in again once and retry.
            if (res.Status == 401)
            {
                Report(progress, "Session expired - signing in again ...");
                auth.Logout();
                token = auth.GetAccessToken(config, true, progress);
                res = DoPost(token, body);
            }

            if ((res.Status == 404 || res.Status == 403) && !string.IsNullOrEmpty(projectId))
            {
                warnings.Add("The previously linked ProvenMetal project no longer exists; a new one was created.");
                body.Remove("projectId");
                res = DoPost(token, body);
            }

            JObject data;
            try { data = JObject.Parse(res.Body); }
            catch { throw new ApiException("Server returned an unreadable response (" + res.Status + ")."); }

            if (res.Status >= 400 || (data["ok"] != null && (bool)data["ok"] == false))
            {
                string msg = (string)data["error"];
                if (string.IsNullOrEmpty(msg)) msg = "Request failed (" + res.Status + ").";
                throw new ApiException(msg, res.Status);
            }

            var result = new RunResult
            {
                ProjectId = (string)data["projectId"] ?? "",
                Ref = (string)data["ref"] ?? "",
                Status = (string)data["status"] ?? "unknown",
                SourcingError = (string)data["sourcingError"] ?? "",
                ReportUrl = (string)data["reportUrl"] ?? "",
                Warnings = warnings
            };
            if (string.IsNullOrEmpty(result.ReportUrl) && !string.IsNullOrEmpty(result.ProjectId))
                result.ReportUrl = config.AppUrl + "/account/orders/" + result.ProjectId;

            var summary = data["summary"] as JObject;
            if (summary != null)
            {
                result.Total = IntOf(summary["total"]);
                result.Pass = IntOf(summary["pass"]);
                result.Review = IntOf(summary["review"]);
                result.Fail = IntOf(summary["fail"]);
            }

            var arr = data["lines"] as JArray;
            if (arr != null)
            {
                foreach (var t in arr)
                {
                    var o = t as JObject;
                    if (o == null) continue;
                    string lk = (string)(o["line_key"] ?? o["lineKey"]) ?? "";
                    string mpn = (string)o["mpn"] ?? "";
                    string lcsc = (string)o["lcsc"] ?? "";
                    string part = !string.IsNullOrEmpty(mpn) ? mpn : (!string.IsNullOrEmpty(lcsc) ? lcsc : lk);
                    result.Lines.Add(new ResultLine
                    {
                        LineKey = lk,
                        Verdict = (string)o["verdict"] ?? "",
                        Reference = (string)o["reference"] ?? "",
                        Part = part,
                        Stock = StrOf(o["stock"]),
                        Lead = StrOf(o["leadTimeDays"] ?? o["lead_time_days"]),
                        RequiredQty = StrOf(o["requiredQty"] ?? o["required_qty"]),
                        Supplier = (string)o["supplier"] ?? "",
                        SourceStatus = (string)(o["sourceStatus"] ?? o["source_status"]) ?? "",
                        Reason = (string)o["reason"] ?? ""
                    });
                }
            }

            return result;
        }

        private struct PostResult { public int Status; public string Body; }

        private PostResult DoPost(string token, JObject body)
        {
            using (var http = Http.NewClient(140))
            {
                var req = new HttpRequestMessage(HttpMethod.Post, _base + "/api/kicad/bom");
                req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
                req.Content = new StringContent(body.ToString(), Encoding.UTF8, "application/json");
                try
                {
                    var resp = http.SendAsync(req).GetAwaiter().GetResult();
                    return new PostResult
                    {
                        Status = (int)resp.StatusCode,
                        Body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    };
                }
                catch (Exception ex)
                {
                    throw new ApiException("Request to ProvenMetal Central failed: " + ex.Message);
                }
            }
        }

        private static JObject BuildRequest(string name, int boardCount, string projectId, List<BomLine> lines)
        {
            var arr = new JArray();
            foreach (var line in lines)
            {
                var refs = new JArray();
                foreach (var r in line.References) refs.Add(r);
                arr.Add(new JObject
                {
                    ["line_key"] = line.LineKey,
                    ["references"] = refs,
                    ["mpn"] = JV(line.Mpn),
                    ["manufacturer"] = JV(line.Manufacturer),
                    ["lcsc"] = JV(line.Lcsc),
                    ["value"] = JV(line.Value),
                    ["footprint"] = JV(line.Footprint),
                    ["description"] = JV(line.Description),
                    ["quantity_per_board"] = line.QuantityPerBoard,
                    ["digikey"] = JV(line.Digikey),
                    ["mouser"] = JV(line.Mouser)
                });
            }

            var body = new JObject
            {
                ["name"] = name,
                ["boardCount"] = boardCount,
                ["clientVersion"] = ClientVersion,
                ["lines"] = arr
            };
            if (!string.IsNullOrEmpty(projectId)) body["projectId"] = projectId;
            return body;
        }

        private static JToken JV(string s) => s == null ? (JToken)JValue.CreateNull() : new JValue(s);

        private static int IntOf(JToken t)
        {
            if (t == null || t.Type == JTokenType.Null) return 0;
            try { return (int)t; } catch { int n; return int.TryParse(t.ToString(), out n) ? n : 0; }
        }

        private static string StrOf(JToken t)
        {
            if (t == null || t.Type == JTokenType.Null) return "";
            return t.ToString();
        }

        private static void Report(Action<string> progress, string msg)
        {
            Log.Write(msg);
            if (progress != null) { try { progress(msg); } catch { } }
        }
    }
}
