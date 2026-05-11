#Requires -Version 5.1
<#
.SYNOPSIS
  Tiny localhost HTTP server for the launcher's PAC file.
.DESCRIPTION
  Modern browsers (Chrome 81+, Firefox, Edge) treat file:// PAC URLs
  inconsistently. Serving the PAC over http://127.0.0.1:<port>/launcher.pac is
  universally supported. Re-reads the PAC on every request, so toggling
  Geo-services in the launcher takes effect without restarting this server.

  Design note: we use blocking GetContext() in a simple loop rather than
  async BeginGetContext + callbacks. PowerShell async callbacks run in
  ThreadPool threads that DO NOT inherit the script's module/script scope,
  so they can't see $listener or $callback — the server accepts the first
  connection but then silently stops serving. Blocking loop is fine here:
  PAC requests from a browser are infrequent (once per AutoConfigURL
  change) and responses are served in milliseconds.

  Usage (spawned by the launcher; not meant to be run by hand):
    powershell -NoProfile -WindowStyle Hidden -File launcher.pacserver.ps1 \
        -PacPath C:\...\launcher.pac -Port 27289
#>

param(
    [Parameter(Mandatory=$true)] [string]$PacPath,
    [Parameter(Mandatory=$true)] [int]   $Port
)

$ErrorActionPreference = 'Continue'

$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Error "Failed to bind ${prefix}: $_"
    exit 2
}

# Fallback body if the PAC file can't be read — "DIRECT" for everything.
$fallbackPac = "function FindProxyForURL(url, host) { return ""DIRECT""; }`n"

# Cached PAC bytes. Re-read only when the source file's LastWriteTimeUtc
# changes — saves disk hits on every Chrome tab open.
$pacCacheWriteTime = [DateTime]::MinValue
$pacCacheBytes     = [Text.Encoding]::UTF8.GetBytes($fallbackPac)

# Prime the cache so the first request is fast.
if (Test-Path -LiteralPath $PacPath) {
    try {
        $body = [IO.File]::ReadAllText($PacPath)
        if ($body) {
            $pacCacheBytes     = [Text.Encoding]::UTF8.GetBytes($body)
            $pacCacheWriteTime = ([IO.FileInfo]::new($PacPath)).LastWriteTimeUtc
        }
    } catch { }
}

# Main accept loop. Blocks on GetContext() — any client request wakes us up,
# we serve, then go back to waiting. Single-threaded is fine for localhost
# PAC since requests are rare and responses are <2 KB.
try {
    while ($listener.IsListening) {
        $ctx = $null
        try {
            $ctx = $listener.GetContext()
        } catch [System.Net.HttpListenerException] {
            # Listener was stopped externally (parent exit, admin kill).
            break
        } catch {
            continue
        }
        if (-not $ctx) { continue }

        # Refresh cache if PAC file changed on disk.
        try {
            if (Test-Path -LiteralPath $PacPath) {
                $info = [IO.FileInfo]::new($PacPath)
                if ($info.LastWriteTimeUtc -ne $pacCacheWriteTime) {
                    $body = [IO.File]::ReadAllText($PacPath)
                    if ($body) {
                        $pacCacheBytes     = [Text.Encoding]::UTF8.GetBytes($body)
                        $pacCacheWriteTime = $info.LastWriteTimeUtc
                    }
                }
            }
        } catch { }

        try {
            $ctx.Response.StatusCode      = 200
            $ctx.Response.ContentType     = 'application/x-ns-proxy-autoconfig'
            $ctx.Response.ContentLength64 = $pacCacheBytes.Length
            $ctx.Response.AddHeader('Cache-Control', 'no-store')
            $ctx.Response.Headers.Add('Server', 'codeDPI-pac/1.0')
            $ctx.Response.OutputStream.Write($pacCacheBytes, 0, $pacCacheBytes.Length)
            $ctx.Response.OutputStream.Flush()
        } catch {
            # Client aborted, pipe broken, etc. — safe to ignore.
        }
        try { $ctx.Response.Close() } catch { }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}
