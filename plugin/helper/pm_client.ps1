<#
  pm_client.ps1 - ProvenMetal Central client for the Altium plugin.

  The Altium DelphiScript plugin shells out to this helper for everything
  network-shaped, exactly mirroring the KiCad plugin's config.py / api.py /
  auth.py / _http.py / project_link.py:

    config        Fetch + print public server config (debug).
    login         Supabase loopback-PKCE sign in (opens the browser); cache token.
    logout        Delete the cached credentials.
    push          Read a request JSON, sign in if needed, POST the BOM, source it,
                  write the project-link sidecar, and emit a flat result file.
    latest        Fetch the latest verdict for the linked project.
    set-base-url  Persist a new ProvenMetal Central base URL.

  DelphiScript builds JSON but never parses it; this helper writes a flat
  key=value "result" file that DelphiScript reads trivially. See ProvenMetal_Client.pas
  for the result-file contract.

  Same server contract as the KiCad plugin: GET/POST /api/kicad/* and the Supabase
  loopback redirect URLs (http://127.0.0.1:{53682,53683,53684,8976}/callback).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('config', 'login', 'logout', 'push', 'latest', 'set-base-url')]
    [string]$Command,

    [string]$SettingsDir = '',
    [string]$Request     = '',
    [string]$Result      = '',
    [string]$ProjectDir  = '',
    [string]$ProjectName = '',
    [string]$Value       = '',
    [string]$Progress    = '',
    [int]   $BoardCount  = 0
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$LOOPBACK_PORTS = @(53682, 53683, 53684, 8976)
$CLIENT_VERSION = '0.1.0'
$Utf8NoBom      = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# Paths / settings
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($SettingsDir)) {
    $SettingsDir = Join-Path $env:APPDATA 'provenmetal-altium'
}
if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null }

$ResultPath = $Result
if ([string]::IsNullOrWhiteSpace($ResultPath)) { $ResultPath = Join-Path $SettingsDir 'result.txt' }

function Get-Prop($obj, $name, $default) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    return $default
}

function Load-Settings {
    $path = Join-Path $SettingsDir 'settings.json'
    $s = [ordered]@{
        base_url       = 'https://central.provenmetal.com'
        oauth_provider = 'google'
    }
    if (Test-Path $path) {
        try {
            $j = Get-Content $path -Raw | ConvertFrom-Json
            $s.base_url       = (Get-Prop $j 'base_url' $s.base_url).TrimEnd('/')
            $s.oauth_provider = Get-Prop $j 'oauth_provider' $s.oauth_provider
        } catch {}
    }
    return $s
}

function Save-Setting($key, $val) {
    $path = Join-Path $SettingsDir 'settings.json'
    $obj = $null
    if (Test-Path $path) {
        try { $obj = Get-Content $path -Raw | ConvertFrom-Json } catch { $obj = $null }
    }
    if ($null -eq $obj) { $obj = New-Object psobject }
    $obj | Add-Member -NotePropertyName $key -NotePropertyValue $val -Force
    ($obj | ConvertTo-Json -Depth 12) | Out-File -FilePath $path -Encoding utf8
}

function Unix-Now { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Base-Hash([string]$base) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($base))
    $hex = -join ($h | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0, 12)
}

function Token-Path($base) { return (Join-Path $SettingsDir ("auth-" + (Base-Hash $base) + ".json")) }

# ---------------------------------------------------------------------------
# Flat result output (atomic: written last, via a .tmp rename)
# ---------------------------------------------------------------------------

function OneLine([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace "`r", ' ') -replace "`n", ' ' -replace "`t", ' '
}

function Write-Result($fields, $warns, $lineRows) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $fields.Keys) { [void]$sb.AppendLine("$k=" + (OneLine ([string]$fields[$k]))) }
    if ($warns)    { foreach ($w in $warns)    { [void]$sb.AppendLine("WARN=" + (OneLine $w)) } }
    if ($lineRows) { foreach ($l in $lineRows) { [void]$sb.AppendLine("LINE=" + $l) } }

    $tmp = "$ResultPath.tmp"
    [IO.File]::WriteAllText($tmp, $sb.ToString(), $Utf8NoBom)
    Move-Item -Force -Path $tmp -Destination $ResultPath
}

function Write-Prog($msg) {
    if ([string]::IsNullOrWhiteSpace($Progress)) { return }
    try { [IO.File]::AppendAllText($Progress, (OneLine $msg) + "`r`n", $Utf8NoBom) } catch {}
}

function Write-Ok($extra) {
    $f = [ordered]@{ OK = '1' }
    if ($extra) { foreach ($k in $extra.Keys) { $f[$k] = $extra[$k] } }
    Write-Result $f $null $null
}

function Write-Fail($message) {
    Write-Result ([ordered]@{ OK = '0'; ERROR = $message }) $null $null
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

function Invoke-Json {
    param($Method, $Url, $Headers, $BodyObj, [int]$TimeoutSec = 140)

    $p = @{ Method = $Method; Uri = $Url; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
    if ($Headers) { $p.Headers = $Headers }
    if ($null -ne $BodyObj) {
        if ($BodyObj -is [string]) { $p.Body = $BodyObj } else { $p.Body = ($BodyObj | ConvertTo-Json -Depth 20 -Compress) }
        $p.ContentType = 'application/json'
    }

    try {
        $resp = Invoke-WebRequest @p
        $data = $null
        if ($resp.Content) { try { $data = $resp.Content | ConvertFrom-Json } catch { $data = $null } }
        return @{ status = [int]$resp.StatusCode; data = $data; raw = $resp.Content }
    } catch {
        $status = 0; $raw = ''
        $ex = $_.Exception
        if ($ex.Response -ne $null) {
            try { $status = [int]$ex.Response.StatusCode } catch {}
            try {
                $stream = $ex.Response.GetResponseStream()
                $sr = New-Object IO.StreamReader($stream)
                $raw = $sr.ReadToEnd(); $sr.Close()
            } catch {}
        }
        if ((-not $raw) -and $_.ErrorDetails -and $_.ErrorDetails.Message) { $raw = $_.ErrorDetails.Message }
        $data = $null; if ($raw) { try { $data = $raw | ConvertFrom-Json } catch {} }
        return @{ status = $status; data = $data; raw = $raw; error = $ex.Message }
    }
}

function Get-Config($base) {
    $r = Invoke-Json 'GET' "$base/api/kicad/config" $null $null 30
    if ($r.status -ne 200 -or -not $r.data) {
        throw "Couldn't reach ProvenMetal Central at $base (config request returned $($r.status))."
    }
    if (-not (Get-Prop $r.data 'supabaseUrl' '') -or -not (Get-Prop $r.data 'supabaseAnonKey' '')) {
        throw "Server did not return Supabase configuration."
    }
    $appUrl = Get-Prop $r.data 'appUrl' $base
    return @{
        supabaseUrl = ([string](Get-Prop $r.data 'supabaseUrl' '')).TrimEnd('/')
        anon        = [string](Get-Prop $r.data 'supabaseAnonKey' '')
        appUrl      = ([string]$appUrl).TrimEnd('/')
    }
}

# ---------------------------------------------------------------------------
# Auth (Supabase loopback PKCE)
# ---------------------------------------------------------------------------

function Base64Url([byte[]]$b) {
    return ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-Verifier {
    $bytes = New-Object byte[] 64
    ([Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($bytes)
    return (Base64Url $bytes)
}

function Get-Challenge([string]$verifier) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
    return (Base64Url $hash)
}

function Load-Tokens($base) {
    $path = Token-Path $base
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-Tokens($base, $data) {
    if (-not (Get-Prop $data 'access_token' '')) { throw "Auth server returned no access token." }
    $expires = Get-Prop $data 'expires_at' $null
    if (-not $expires) {
        $ttl = [int](Get-Prop $data 'expires_in' 3600)
        $expires = (Unix-Now) + $ttl
    }
    $obj = [ordered]@{
        access_token  = [string](Get-Prop $data 'access_token' '')
        refresh_token = [string](Get-Prop $data 'refresh_token' '')
        expires_at    = [double]$expires
    }
    $path = Token-Path $base
    ($obj | ConvertTo-Json) | Out-File -FilePath $path -Encoding utf8
    return $obj
}

function Refresh-Token($base, $config, $refreshToken) {
    $url = "$($config.supabaseUrl)/auth/v1/token?grant_type=refresh_token"
    $r = Invoke-Json 'POST' $url @{ apikey = $config.anon } @{ refresh_token = $refreshToken } 30
    if ($r.status -ne 200 -or -not $r.data) { return $null }
    try { return (Save-Tokens $base $r.data) } catch { return $null }
}

$DONE_HTML = "<html><body style='font-family:sans-serif;padding:2rem'><h2>ProvenMetal</h2><p>You're signed in. You can close this tab and return to Altium.</p></body></html>"
$RELAY_HTML = "<html><body style='font-family:sans-serif;padding:2rem'><p>Completing sign-in...</p><script>var h=window.location.hash?window.location.hash.substring(1):'';if(h){window.location.replace('/store?'+h);}else{document.body.innerHTML='<p>No sign-in data found. You can close this tab.</p>';}</script></body></html>"

function Respond($ctx, $html) {
    $buf = [Text.Encoding]::UTF8.GetBytes($html)
    $ctx.Response.ContentType = 'text/html; charset=utf-8'
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.OutputStream.Close()
}

function Start-Loopback {
    foreach ($port in $LOOPBACK_PORTS) {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$port/")
        try {
            $listener.Start()
            return @{ listener = $listener; port = $port }
        } catch {
            try { $listener.Close() } catch {}
        }
    }
    throw "Couldn't bind any loopback port for login ($($LOOPBACK_PORTS -join ', ') all in use)."
}

function Do-Login($base, $config, [int]$TimeoutSec = 300) {
    $settings = Load-Settings
    $provider = $settings.oauth_provider
    if (-not $provider) { $provider = 'google' }

    $verifier = New-Verifier
    $challenge = Get-Challenge $verifier

    $lb = Start-Loopback
    $listener = $lb.listener
    $redirect = "http://127.0.0.1:$($lb.port)/callback"

    $q = @(
        "provider=$([uri]::EscapeDataString($provider))",
        "redirect_to=$([uri]::EscapeDataString($redirect))",
        "code_challenge=$([uri]::EscapeDataString($challenge))",
        "code_challenge_method=s256"
    ) -join '&'
    $authorize = "$($config.supabaseUrl)/auth/v1/authorize?$q"

    $authResult = $null
    try {
        Start-Process $authorize | Out-Null
    } catch {
        Write-Host "Open this URL to sign in:`n$authorize"
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    try {
        while (((Get-Date) -lt $deadline) -and ($null -eq $authResult)) {
            $task = $listener.GetContextAsync()
            while (-not $task.Wait(500)) {
                if ((Get-Date) -ge $deadline) { break }
            }
            if (-not $task.IsCompleted) { continue }

            $ctx = $task.Result
            $req = $ctx.Request
            $path = $req.Url.AbsolutePath
            $qs = $req.QueryString

            if ($path -eq '/store') {
                $authResult = @{
                    access_token      = $qs['access_token']
                    refresh_token     = $qs['refresh_token']
                    expires_at        = $qs['expires_at']
                    expires_in        = $qs['expires_in']
                    error             = $qs['error']
                    error_description = $qs['error_description']
                }
                Respond $ctx $DONE_HTML
            }
            elseif ($qs['code'] -or $qs['error']) {
                $authResult = @{
                    code              = $qs['code']
                    error             = $qs['error']
                    error_description = $qs['error_description']
                }
                Respond $ctx $DONE_HTML
            }
            else {
                Respond $ctx $RELAY_HTML
            }
        }
    } finally {
        try { $listener.Stop(); $listener.Close() } catch {}
    }

    if ($null -eq $authResult) { throw "Login timed out. Please try again." }
    if ($authResult.error) {
        $msg = $authResult.error_description; if (-not $msg) { $msg = $authResult.error }
        throw "Login failed: $msg"
    }

    # Implicit flow: tokens relayed from the URL fragment.
    if ($authResult.access_token) {
        $data = New-Object psobject
        $data | Add-Member NoteProperty access_token  $authResult.access_token
        $data | Add-Member NoteProperty refresh_token ($authResult.refresh_token)
        if ($authResult.expires_at) { $data | Add-Member NoteProperty expires_at $authResult.expires_at }
        if ($authResult.expires_in) { $data | Add-Member NoteProperty expires_in $authResult.expires_in }
        return (Save-Tokens $base $data)
    }

    # PKCE flow: exchange the code for a session.
    if (-not $authResult.code) { throw "Login did not return credentials. Please try again." }
    $url = "$($config.supabaseUrl)/auth/v1/token?grant_type=pkce"
    $r = Invoke-Json 'POST' $url @{ apikey = $config.anon } @{ auth_code = $authResult.code; code_verifier = $verifier } 30
    if ($r.status -ne 200 -or -not $r.data) {
        $detail = ''
        if ($r.data) { $detail = Get-Prop $r.data 'error_description' (Get-Prop $r.data 'msg' '') }
        throw ("Token exchange failed ($($r.status)). $detail").Trim()
    }
    return (Save-Tokens $base $r.data)
}

function Ensure-Token($base, $config, [bool]$interactive) {
    $tok = Load-Tokens $base
    $now = Unix-Now
    if ($tok -and (Get-Prop $tok 'access_token' '') -and ([double](Get-Prop $tok 'expires_at' 0) -gt ($now + 60))) {
        return $tok.access_token
    }
    if ($tok -and (Get-Prop $tok 'refresh_token' '')) {
        $r = Refresh-Token $base $config $tok.refresh_token
        if ($r) { return $r.access_token }
    }
    if (-not $interactive) { throw "Not signed in. Run login first." }
    $r = Do-Login $base $config
    return $r.access_token
}

# ---------------------------------------------------------------------------
# Sidecar (<project>.provenmetal.json)
# ---------------------------------------------------------------------------

function Sidecar-Path {
    if ([string]::IsNullOrWhiteSpace($ProjectDir) -or [string]::IsNullOrWhiteSpace($ProjectName)) { return $null }
    return (Join-Path $ProjectDir ($ProjectName + '.provenmetal.json'))
}

function Load-Sidecar {
    $p = Sidecar-Path
    if ((-not $p) -or (-not (Test-Path $p))) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-Sidecar($projectId, $ref, $boardCount) {
    $p = Sidecar-Path
    if (-not $p) { return }
    $obj = [ordered]@{ projectId = $projectId }
    if ($ref) { $obj.ref = $ref }
    if ($boardCount) { $obj.boardCount = [int]$boardCount }
    [IO.File]::WriteAllText($p, ($obj | ConvertTo-Json) + "`n", $Utf8NoBom)
}

# ---------------------------------------------------------------------------
# Result rows for the push response
# ---------------------------------------------------------------------------

function Format-Lines($data) {
    $rows = @()
    $lines = Get-Prop $data 'lines' @()
    foreach ($ln in $lines) {
        $lineKey = Get-Prop $ln 'line_key' (Get-Prop $ln 'lineKey' '')
        $verdict = Get-Prop $ln 'verdict' ''
        $ref     = Get-Prop $ln 'reference' ''
        $mpn     = Get-Prop $ln 'mpn' ''
        $part    = $mpn; if (-not $part) { $part = Get-Prop $ln 'lcsc' '' }; if (-not $part) { $part = $lineKey }
        $stock   = Get-Prop $ln 'stock' ''
        $lead    = Get-Prop $ln 'leadTimeDays' (Get-Prop $ln 'lead_time_days' '')
        $reqQty  = Get-Prop $ln 'requiredQty' (Get-Prop $ln 'required_qty' '')
        $supp    = Get-Prop $ln 'supplier' ''
        $srcStat = Get-Prop $ln 'sourceStatus' (Get-Prop $ln 'source_status' '')
        $reason  = Get-Prop $ln 'reason' ''

        $fields = @($lineKey, $verdict, $ref, $part, $stock, $lead, $reqQty, $supp, $srcStat, $reason)
        $clean = $fields | ForEach-Object { OneLine ([string]$_) }
        $rows += ($clean -join "`t")
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

function Cmd-Config {
    $s = Load-Settings
    $c = Get-Config $s.base_url
    Write-Ok ([ordered]@{ SUPABASE_URL = $c.supabaseUrl; APP_URL = $c.appUrl; BASE_URL = $s.base_url })
}

function Cmd-Login {
    $s = Load-Settings
    $c = Get-Config $s.base_url
    Do-Login $s.base_url $c | Out-Null
    Write-Ok ([ordered]@{ MESSAGE = 'Signed in.' })
}

function Cmd-Logout {
    $s = Load-Settings
    $p = Token-Path $s.base_url
    if (Test-Path $p) { Remove-Item -Force $p }
    Write-Ok ([ordered]@{ MESSAGE = 'Signed out.' })
}

function Cmd-SetBaseUrl {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "No URL provided." }
    Save-Setting 'base_url' ($Value.TrimEnd('/'))
    Write-Ok ([ordered]@{ MESSAGE = "Base URL set to $($Value.TrimEnd('/'))"; BASE_URL = $Value.TrimEnd('/') })
}

function Do-Push($base, $config, $req, $projectId, [ref]$warnRef) {
    if ($projectId) {
        $req | Add-Member -NotePropertyName projectId -NotePropertyValue $projectId -Force
    }
    Write-Prog 'Signing in (a browser will open if needed) ...'
    $token = Ensure-Token $base $config $true
    Write-Prog 'Signed in. Pushing the BOM and sourcing (this can take up to a minute) ...'
    $headers = @{ Authorization = "Bearer $token" }
    $r = Invoke-Json 'POST' "$base/api/kicad/bom" $headers $req 140

    # If the linked project is gone, forget it and create a fresh one.
    if (($r.status -eq 404 -or $r.status -eq 403) -and $projectId) {
        $warnRef.Value += 'The previously linked ProvenMetal project no longer exists; a new one was created.'
        $req.PSObject.Properties.Remove('projectId')
        $r = Invoke-Json 'POST' "$base/api/kicad/bom" $headers $req 140
    }
    return $r
}

function Cmd-Push {
    if ([string]::IsNullOrWhiteSpace($Request) -or -not (Test-Path $Request)) {
        throw "Request file not found: $Request"
    }
    $s = Load-Settings
    $base = $s.base_url
    Write-Prog "Connecting to ProvenMetal Central ($base) ..."
    $config = Get-Config $base

    $req = Get-Content $Request -Raw | ConvertFrom-Json

    $projectId = Get-Prop $req 'projectId' ''
    if (-not $projectId) {
        $sc = Load-Sidecar
        if ($sc) { $projectId = Get-Prop $sc 'projectId' '' }
    }

    $warns = @()
    $wref = [ref]$warns
    $r = Do-Push $base $config $req $projectId $wref
    $warns = $wref.Value

    if ($r.status -ge 400 -or ($r.data -and (Get-Prop $r.data 'ok' $true) -eq $false)) {
        $msg = ''
        if ($r.data) { $msg = Get-Prop $r.data 'error' '' }
        if (-not $msg) { $msg = "Request failed ($($r.status))." }
        throw $msg
    }
    if (-not $r.data) { throw "Server returned an unreadable response ($($r.status))." }

    $data = $r.data
    $projId = Get-Prop $data 'projectId' ''
    $ref = Get-Prop $data 'ref' ''
    $boardCount = Get-Prop $req 'boardCount' $BoardCount
    if ($projId) { Save-Sidecar $projId $ref $boardCount }

    $summary = Get-Prop $data 'summary' $null
    $reportUrl = Get-Prop $data 'reportUrl' ''
    if (-not $reportUrl -and $projId) { $reportUrl = "$($config.appUrl)/account/orders/$projId" }

    $fields = [ordered]@{
        OK             = '1'
        STATUS         = (Get-Prop $data 'status' 'unknown')
        PROJECT_ID     = $projId
        REF            = $ref
        REPORT_URL     = $reportUrl
        SUMMARY_TOTAL  = [int](Get-Prop $summary 'total' 0)
        SUMMARY_PASS   = [int](Get-Prop $summary 'pass' 0)
        SUMMARY_REVIEW = [int](Get-Prop $summary 'review' 0)
        SUMMARY_FAIL   = [int](Get-Prop $summary 'fail' 0)
    }
    $se = Get-Prop $data 'sourcingError' ''
    if ($se) { $fields.SOURCING_ERROR = $se }

    Write-Result $fields $warns (Format-Lines $data)
}

function Cmd-Latest {
    $s = Load-Settings
    $base = $s.base_url
    $config = Get-Config $base
    $sc = Load-Sidecar
    $projectId = ''
    if ($sc) { $projectId = Get-Prop $sc 'projectId' '' }
    if (-not $projectId) { throw "No linked project (no sidecar). Push first." }

    $token = Ensure-Token $base $config $false
    $r = Invoke-Json 'GET' "$base/api/kicad/bom/$projectId" @{ Authorization = "Bearer $token" } $null 60
    if ($r.status -ge 400 -or -not $r.data) { throw "Fetch failed ($($r.status))." }

    $data = $r.data
    $summary = Get-Prop $data 'summary' $null
    $reportUrl = Get-Prop $data 'reportUrl' ''
    $fields = [ordered]@{
        OK             = '1'
        STATUS         = (Get-Prop $data 'status' 'unknown')
        PROJECT_ID     = $projectId
        REF            = (Get-Prop $data 'ref' '')
        REPORT_URL     = $reportUrl
        SUMMARY_TOTAL  = [int](Get-Prop $summary 'total' 0)
        SUMMARY_PASS   = [int](Get-Prop $summary 'pass' 0)
        SUMMARY_REVIEW = [int](Get-Prop $summary 'review' 0)
        SUMMARY_FAIL   = [int](Get-Prop $summary 'fail' 0)
    }
    Write-Result $fields $null (Format-Lines $data)
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

try {
    switch ($Command) {
        'config'       { Cmd-Config }
        'login'        { Cmd-Login }
        'logout'       { Cmd-Logout }
        'push'         { Cmd-Push }
        'latest'       { Cmd-Latest }
        'set-base-url' { Cmd-SetBaseUrl }
    }
    exit 0
} catch {
    try { Write-Fail ($_.Exception.Message) } catch {}
    exit 1
}
