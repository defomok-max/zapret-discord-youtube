#Requires -Version 5.1
<#
.SYNOPSIS
  Tiny localhost HTTP server for the launcher's PAC file.
.DESCRIPTION
  Modern browsers (Chrome 81+, Firefox, Edge) treat file:// PAC URLs
  inconsistently. Serving the PAC over http://127.0.0.1:<port>/launcher.pac is
  universally supported. Re-reads the PAC on every request, so toggling
  Geo-services in the launcher takes effect without restarting this server.

  Behaviour:
    - Async accept loop via BeginGetContext — one callback thread per request,
      handled on the ThreadPool. Chrome can ask for the PAC 4-6 times on a
      fresh tab open; serialising those used to cause 150-300ms stalls on
      first request. Now each request is served in parallel.
    - Small in-memory cache of the PAC bytes keyed on the file's
      LastWriteTimeUtc — re-reads from disk only when the launcher rewrote
      the PAC, not on every hit.
    - Silent ignores broken pipes / client aborts (common when Chrome
      pipelines).

  Usage (spawned by the launcher; not meant to be run by hand):
    powershell -NoProfile -WindowStyle Hidden -STA -File launcher.pacserver.ps1 \
        -PacPath C:\...\launcher.pac -Port 27289
#>

param(
    [Parameter(Mandatory=$true)] [string]$PacPath,
    [Parameter(Mandatory=$true)] [int]   $Port
)

$ErrorActionPreference = 'Stop'

$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Error "Failed to bind $prefix : $_"
    exit 2
}

# Fallback body if the PAC file can't be read — "DIRECT" for everything.
$fallbackPac = "function FindProxyForURL(url, host) { return ""DIRECT""; }`n"

# Cached PAC — updated only when the source file's timestamp changes.
$Script:pacCacheWriteTime = [DateTime]::MinValue
$Script:pacCacheBytes     = [Text.Encoding]::UTF8.GetBytes($fallbackPac)

function Get-PacBytes {
    if (-not (Test-Path -LiteralPath $PacPath)) {
        $Script:pacCacheWriteTime = [DateTime]::MinValue
        return [Text.Encoding]::UTF8.GetBytes($fallbackPac)
    }
    try {
        $info = [IO.FileInfo]::new($PacPath)
        if ($info.LastWriteTimeUtc -ne $Script:pacCacheWriteTime) {
            $body = [IO.File]::ReadAllText($PacPath)
            if (-not $body) { $body = $fallbackPac }
            $Script:pacCacheBytes     = [Text.Encoding]::UTF8.GetBytes($body)
            $Script:pacCacheWriteTime = $info.LastWriteTimeUtc
        }
        return $Script:pacCacheBytes
    } catch {
        return [Text.Encoding]::UTF8.GetBytes($fallbackPac)
    }
}

# Prime the cache so the very first request is fast.
[void](Get-PacBytes)

# Async request pump. Each inbound request is handed off to the ThreadPool so
# we can serve concurrent Chrome tabs without head-of-line blocking.
$callback = {
    param($asyncResult)
    $ctx = $null
    try {
        $ctx = $listener.EndGetContext($asyncResult)
    } catch {
        return
    }
    # Queue the next accept immediately — keeps the listener saturated.
    if ($listener.IsListening) {
        try { [void]$listener.BeginGetContext($callback, $null) } catch { }
    }
    if (-not $ctx) { return }
    try {
        $bytes = Get-PacBytes
        $ctx.Response.ContentType     = 'application/x-ns-proxy-autoconfig'
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.AddHeader('Cache-Control', 'no-store')
        $ctx.Response.Headers.Add('Server', 'codeDPI-pac/1.0')
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.OutputStream.Flush()
    } catch {
        # Client aborted, pipe broken, etc. — safe to ignore.
    }
    try { $ctx.Response.Close() } catch { }
}

# Graceful shutdown via Ctrl-C / parent termination. Marshalled to a variable
# so the closure sees the same $listener instance.
$cancelHandler = [System.ConsoleCancelEventHandler] {
    param($sender, $e)
    $e.Cancel = $true
    try { $listener.Stop() } catch { }
}
[Console]::add_CancelKeyPress($cancelHandler)

# Kick off the first accept. After this the whole thing is callback-driven;
# the main thread just idles on a long wait so the process stays alive.
try { [void]$listener.BeginGetContext($callback, $null) } catch { }

try {
    while ($listener.IsListening) {
        Start-Sleep -Seconds 3600
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}
