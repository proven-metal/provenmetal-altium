using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using ProvenMetal.Core;

namespace ProvenMetal.Central
{
    public class ServerConfig
    {
        public string SupabaseUrl;
        public string Anon;
        public string AppUrl;
    }

    public class AuthException : Exception
    {
        public AuthException(string message) : base(message) { }
    }

    // Supabase sign-in for a desktop process, via loopback PKCE - same flow and
    // redirect URLs as the KiCad plugin. Tokens are cached per base URL and
    // refreshed transparently.
    public class Authenticator
    {
        private static readonly int[] LoopbackPorts = { 53682, 53683, 53684, 8976 };

        private readonly string _baseUrl;
        private readonly string _provider;
        private readonly string _settingsDir;

        public Authenticator(string baseUrl, string provider)
        {
            _baseUrl = (baseUrl ?? "").TrimEnd('/');
            _provider = string.IsNullOrEmpty(provider) ? "google" : provider;
            _settingsDir = Util.SettingsDir();
        }

        private string TokenPath()
        {
            using (var sha = SHA256.Create())
            {
                byte[] h = sha.ComputeHash(Encoding.UTF8.GetBytes(_baseUrl));
                string hex = BitConverter.ToString(h).Replace("-", "").ToLowerInvariant().Substring(0, 12);
                return Path.Combine(_settingsDir, "auth-" + hex + ".json");
            }
        }

        private static long UnixNow() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        private JObject LoadTokens()
        {
            try
            {
                string p = TokenPath();
                return File.Exists(p) ? JObject.Parse(File.ReadAllText(p)) : null;
            }
            catch { return null; }
        }

        private JObject SaveTokens(JObject data)
        {
            string access = (string)data["access_token"];
            if (string.IsNullOrEmpty(access)) throw new AuthException("Auth server returned no access token.");

            double expiresAt;
            if (data["expires_at"] != null) expiresAt = (double)data["expires_at"];
            else expiresAt = UnixNow() + (data["expires_in"] != null ? (double)data["expires_in"] : 3600);

            var tok = new JObject
            {
                ["access_token"] = access,
                ["refresh_token"] = (string)data["refresh_token"] ?? "",
                ["expires_at"] = expiresAt
            };
            File.WriteAllText(TokenPath(), tok.ToString());
            return tok;
        }

        public void Logout()
        {
            try { string p = TokenPath(); if (File.Exists(p)) File.Delete(p); } catch { }
        }

        public string GetAccessToken(ServerConfig config, bool interactive, Action<string> progress)
        {
            var tok = LoadTokens();
            long now = UnixNow();

            if (tok != null && (string)tok["access_token"] != null &&
                tok["expires_at"] != null && (double)tok["expires_at"] > now + 60)
                return (string)tok["access_token"];

            if (tok != null && !string.IsNullOrEmpty((string)tok["refresh_token"]))
            {
                var refreshed = TryRefresh(config, (string)tok["refresh_token"]);
                if (refreshed != null) return (string)refreshed["access_token"];
            }

            if (!interactive) throw new AuthException("Not signed in. Run login first.");

            if (progress != null) progress("Opening your browser to sign in ...");
            var loggedIn = DoLogin(config, progress);
            return (string)loggedIn["access_token"];
        }

        private JObject TryRefresh(ServerConfig config, string refreshToken)
        {
            try
            {
                using (var http = Http.NewClient(30))
                {
                    var req = new HttpRequestMessage(HttpMethod.Post,
                        config.SupabaseUrl + "/auth/v1/token?grant_type=refresh_token");
                    req.Headers.TryAddWithoutValidation("apikey", config.Anon);
                    req.Content = new StringContent(new JObject { ["refresh_token"] = refreshToken }.ToString(),
                        Encoding.UTF8, "application/json");
                    var resp = http.SendAsync(req).GetAwaiter().GetResult();
                    string body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                    if (!resp.IsSuccessStatusCode) return null;
                    return SaveTokens(JObject.Parse(body));
                }
            }
            catch { return null; }
        }

        private const string DoneHtml =
            "<html><body style='font-family:sans-serif;padding:2rem'><h2>ProvenMetal</h2>" +
            "<p>You're signed in. You can close this tab and return to Altium.</p></body></html>";

        private const string RelayHtml =
            "<html><body style='font-family:sans-serif;padding:2rem'><p>Completing sign-in...</p><script>" +
            "var h=window.location.hash?window.location.hash.substring(1):'';" +
            "if(h){window.location.replace('/store?'+h);}" +
            "else{document.body.innerHTML='<p>No sign-in data found. You can close this tab.</p>';}" +
            "</script></body></html>";

        private static HttpListener BindLoopback(out int port)
        {
            foreach (int p in LoopbackPorts)
            {
                var listener = new HttpListener();
                listener.Prefixes.Add("http://127.0.0.1:" + p + "/");
                try { listener.Start(); port = p; return listener; }
                catch { try { listener.Close(); } catch { } }
            }
            throw new AuthException("Couldn't bind any loopback port for login.");
        }

        private static void Respond(HttpListenerContext ctx, string html)
        {
            try
            {
                byte[] buf = Encoding.UTF8.GetBytes(html);
                ctx.Response.ContentType = "text/html; charset=utf-8";
                ctx.Response.ContentLength64 = buf.Length;
                ctx.Response.OutputStream.Write(buf, 0, buf.Length);
                ctx.Response.OutputStream.Close();
            }
            catch { }
        }

        private static string B64Url(byte[] b)
            => Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');

        private JObject DoLogin(ServerConfig config, Action<string> progress = null, int timeoutSecs = 300)
        {
            // PKCE pair
            byte[] rnd = new byte[64];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(rnd);
            string verifier = B64Url(rnd);
            string challenge;
            using (var sha = SHA256.Create())
                challenge = B64Url(sha.ComputeHash(Encoding.ASCII.GetBytes(verifier)));

            int port;
            var listener = BindLoopback(out port);
            string redirect = "http://127.0.0.1:" + port + "/callback";

            string authorize = config.SupabaseUrl + "/auth/v1/authorize?" +
                "provider=" + Uri.EscapeDataString(_provider) +
                "&redirect_to=" + Uri.EscapeDataString(redirect) +
                "&code_challenge=" + Uri.EscapeDataString(challenge) +
                "&code_challenge_method=s256";

            Dictionary<string, string> authResult = null;
            try
            {
                bool opened = false;
                try { Process.Start(new ProcessStartInfo(authorize) { UseShellExecute = true }); opened = true; }
                catch { }
                if (progress != null)
                {
                    if (opened) progress("Waiting for the browser sign-in to finish ...");
                    else progress("Couldn't open a browser. Sign in at this URL, then return here: " + authorize);
                }

                DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSecs);
                while (DateTime.UtcNow < deadline && authResult == null)
                {
                    var task = listener.GetContextAsync();
                    while (!task.Wait(500))
                        if (DateTime.UtcNow >= deadline) break;
                    if (!task.IsCompleted) continue;

                    var ctx = task.Result;
                    var q = ctx.Request.QueryString;
                    string path = ctx.Request.Url.AbsolutePath;

                    if (path == "/store")
                    {
                        authResult = new Dictionary<string, string>
                        {
                            ["access_token"] = q["access_token"],
                            ["refresh_token"] = q["refresh_token"],
                            ["expires_at"] = q["expires_at"],
                            ["expires_in"] = q["expires_in"],
                            ["error"] = q["error"],
                            ["error_description"] = q["error_description"],
                        };
                        Respond(ctx, DoneHtml);
                    }
                    else if (q["code"] != null || q["error"] != null)
                    {
                        authResult = new Dictionary<string, string>
                        {
                            ["code"] = q["code"],
                            ["error"] = q["error"],
                            ["error_description"] = q["error_description"],
                        };
                        Respond(ctx, DoneHtml);
                    }
                    else
                    {
                        Respond(ctx, RelayHtml);
                    }
                }
            }
            finally
            {
                try { listener.Stop(); listener.Close(); } catch { }
            }

            if (authResult == null) throw new AuthException("Login timed out. Please try again.");
            if (!string.IsNullOrEmpty(Val(authResult, "error")))
                throw new AuthException("Login failed: " + (Val(authResult, "error_description") ?? Val(authResult, "error")));

            // Implicit flow: tokens relayed from the fragment.
            if (!string.IsNullOrEmpty(Val(authResult, "access_token")))
            {
                var data = new JObject
                {
                    ["access_token"] = Val(authResult, "access_token"),
                    ["refresh_token"] = Val(authResult, "refresh_token") ?? "",
                };
                if (!string.IsNullOrEmpty(Val(authResult, "expires_at"))) data["expires_at"] = double.Parse(Val(authResult, "expires_at"));
                if (!string.IsNullOrEmpty(Val(authResult, "expires_in"))) data["expires_in"] = double.Parse(Val(authResult, "expires_in"));
                return SaveTokens(data);
            }

            // PKCE flow: exchange the code.
            string code = Val(authResult, "code");
            if (string.IsNullOrEmpty(code)) throw new AuthException("Login did not return credentials.");

            using (var http = Http.NewClient(30))
            {
                var req = new HttpRequestMessage(HttpMethod.Post, config.SupabaseUrl + "/auth/v1/token?grant_type=pkce");
                req.Headers.TryAddWithoutValidation("apikey", config.Anon);
                req.Content = new StringContent(
                    new JObject { ["auth_code"] = code, ["code_verifier"] = verifier }.ToString(),
                    Encoding.UTF8, "application/json");
                var resp = http.SendAsync(req).GetAwaiter().GetResult();
                string body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                if (!resp.IsSuccessStatusCode)
                {
                    string detail = "";
                    try { var e = JObject.Parse(body); detail = (string)(e["error_description"] ?? e["msg"]) ?? ""; } catch { }
                    throw new AuthException(("Token exchange failed (" + (int)resp.StatusCode + "). " + detail).Trim());
                }
                return SaveTokens(JObject.Parse(body));
            }
        }

        private static string Val(Dictionary<string, string> d, string k)
        {
            string v; return d.TryGetValue(k, out v) ? v : null;
        }
    }

    internal static class Http
    {
        public static HttpClient NewClient(int timeoutSecs)
        {
            try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
            var c = new HttpClient { Timeout = TimeSpan.FromSeconds(timeoutSecs) };
            c.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "provenmetal-altium/1.0");
            c.DefaultRequestHeaders.TryAddWithoutValidation("Accept", "application/json");
            return c;
        }
    }
}
