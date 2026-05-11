#Requires -Version 5.1
<#
.SYNOPSIS
  Shared logic for the codeDPI launcher (CLI + GUI).
.DESCRIPTION
  Pure-ish library: no console writes, no [Console]::ReadLine prompts. The
  caller (CLI or GUI) supplies a $Script:LogSink scriptblock — see
  Write-LauncherLog.
#>

$ErrorActionPreference = 'Stop'

# ============================================================================
# Paths
# ============================================================================
$Script:UtilsDir         = $PSScriptRoot
$Script:RepoRoot         = Split-Path -Parent $PSScriptRoot
$Script:ListsDir         = Join-Path $RepoRoot 'lists'
$Script:BinDir           = Join-Path $RepoRoot 'bin'
$Script:CustomDir        = Join-Path $RepoRoot 'custom-vpn'
$Script:ConfigPath       = Join-Path $RepoRoot 'launcher.conf'
$Script:PacPath          = Join-Path $UtilsDir  'launcher.pac'
$Script:PacServerScript  = Join-Path $UtilsDir  'launcher.pacserver.ps1'
$Script:PacServerPidFile = Join-Path $RepoRoot  'launcher.pac-server.pid'
$Script:DefaultPacPort   = 27289
$Script:Version          = '1.4.4'

# ============================================================================
# Service catalogues
# ============================================================================
# DPI services: their domains go through zapret (winws.exe DPI desync). Toggle
# is reflected in lists/list-general-user.txt which every general*.bat already
# includes via --hostlist. AlwaysOn lists are referenced by upstream strategies
# directly (list-google.txt / list-general.txt) and cannot be disabled here.
$Script:Services = [ordered]@{
    youtube  = @{ Name='YouTube';                            File='list-google.txt';   AlwaysOn=$true;  DefaultOn=$true  }
    discord  = @{ Name='Discord / Cloudflare / Twitch chat'; File='list-general.txt';  AlwaysOn=$true;  DefaultOn=$true  }
    meta     = @{ Name='Meta (Instagram/Facebook/Threads)';  File='list-meta.txt';     AlwaysOn=$false; DefaultOn=$true  }
    telegram = @{ Name='Telegram (web/CDN)';                 File='list-telegram.txt'; AlwaysOn=$false; DefaultOn=$true  }
    x        = @{ Name='X / Twitter';                        File='list-x.txt';        AlwaysOn=$false; DefaultOn=$true  }
    linkedin = @{ Name='LinkedIn';                           File='list-linkedin.txt'; AlwaysOn=$false; DefaultOn=$true  }
    signal   = @{ Name='Signal';                             File='list-signal.txt';   AlwaysOn=$false; DefaultOn=$true  }
    tiktok   = @{ Name='TikTok';                             File='list-tiktok.txt';   AlwaysOn=$false; DefaultOn=$true  }
    reddit   = @{ Name='Reddit';                             File='list-reddit.txt';   AlwaysOn=$false; DefaultOn=$false }
    patreon  = @{ Name='Patreon';                            File='list-patreon.txt';  AlwaysOn=$false; DefaultOn=$false }
    notion   = @{ Name='Notion (DPI)';                       File='list-notion.txt';   AlwaysOn=$false; DefaultOn=$false }
    imgur    = @{ Name='Imgur';                              File='list-imgur.txt';    AlwaysOn=$false; DefaultOn=$false }
    spotify  = @{ Name='Spotify (web)';                      File='list-spotify.txt';  AlwaysOn=$false; DefaultOn=$false }
    news     = @{ Name='News (BBC/DW/Meduza/...)';           File='list-news.txt';     AlwaysOn=$false; DefaultOn=$false }
}

# Geo services: server-side IP geo-blocked. zapret cannot help — DPI bypass on
# RU side does nothing if the destination refuses RU IPs. Their domains are
# routed via Cloudflare WARP (proxy mode SOCKS5 127.0.0.1:40000) using a PAC
# file. Toggleable from the GUI / CLI.
$Script:GeoServices = [ordered]@{
    openai  = @{ Name='ChatGPT / OpenAI';   File='geo-openai.txt';  DefaultOn=$true  }
    claude  = @{ Name='Claude / Anthropic'; File='geo-claude.txt';  DefaultOn=$true  }
    gemini  = @{ Name='Google Gemini / AI Studio'; File='geo-gemini.txt'; DefaultOn=$false }
    cursor  = @{ Name='Cursor';             File='geo-cursor.txt';  DefaultOn=$false }
    copilot = @{ Name='GitHub Copilot';     File='geo-copilot.txt'; DefaultOn=$false }
    spotify = @{ Name='Spotify (geo)';      File='geo-spotify.txt'; DefaultOn=$false }
    notion  = @{ Name='Notion (geo)';       File='geo-notion.txt';  DefaultOn=$false }
}

# ============================================================================
# Logging — overridable
# ============================================================================
$Script:LogSink = $null
$Script:LauncherLogPath = Join-Path $RepoRoot 'launcher.log'

# Rotate launcher.log if it grows past ~1 MB — we append to it on every
# command; without rotation it would grow forever on long-running installs.
function Rotate-LauncherLog {
    try {
        if (-not (Test-Path -LiteralPath $Script:LauncherLogPath)) { return }
        $info = Get-Item -LiteralPath $Script:LauncherLogPath -ErrorAction SilentlyContinue
        if (-not $info) { return }
        if ($info.Length -gt 1MB) {
            $old = "$($Script:LauncherLogPath).old"
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $Script:LauncherLogPath -Destination $old -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Write-LauncherLog {
    param([string]$Message, [string]$Color = 'White')
    if ($Script:LogSink) {
        try { & $Script:LogSink $Message $Color } catch { }
    } else {
        Write-Host "  $Message" -ForegroundColor $Color
    }
}

# ============================================================================
# Config persistence
# ============================================================================
function Get-DefaultConfig {
    $cfg = [ordered]@{}
    $cfg.strategy        = 'general (FAKE TLS AUTO).bat'
    $cfg.warp_mode          = 'proxy'
    $cfg.warp_autostart     = '1'
    $cfg.auto_install_warp  = '1'
    $cfg.geo_routing        = '1'
    $cfg.pac_port           = "$DefaultPacPort"
    foreach ($key in $Services.Keys) {
        $cfg["service_$key"] = if ($Services[$key].DefaultOn) { '1' } else { '0' }
    }
    foreach ($key in $GeoServices.Keys) {
        $cfg["geo_$key"] = if ($GeoServices[$key].DefaultOn) { '1' } else { '0' }
    }
    $cfg
}

function Read-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path $ConfigPath) {
        foreach ($line in Get-Content -LiteralPath $ConfigPath -Encoding UTF8) {
            $trim = $line.Trim()
            if (-not $trim -or $trim.StartsWith('#')) { continue }
            $eq = $trim.IndexOf('=')
            if ($eq -lt 1) { continue }
            $k = $trim.Substring(0, $eq).Trim()
            $v = $trim.Substring($eq + 1).Trim()
            $cfg[$k] = $v
        }
    }
    $cfg
}

function Write-Utf8NoBom([string]$path, [string[]]$lines) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($path, [string[]]$lines, $enc)
}

function Save-Config([hashtable]$cfg) {
    $lines = @('# codeDPI launcher config — managed automatically.')
    foreach ($k in $cfg.Keys) {
        $lines += "$k=$($cfg[$k])"
    }
    Write-Utf8NoBom $ConfigPath $lines
}

# ============================================================================
# Registry — Internet Settings (per-user, NOT per-token)
# ============================================================================
# When the launcher is elevated via UAC with a DIFFERENT user account
# ("over-the-shoulder"), HKCU in the elevated session points to the admin's
# hive — but the browser that actually reads AutoConfigURL lives in the
# interactive user's hive. Write to the interactive user's hive explicitly.
#
# In the common case (same user, just elevated via linked token), interactive
# SID == current SID and this resolves to plain HKCU anyway.
$Script:InteractiveUserSid  = $null
$Script:InteractiveHivePath = $null

function Get-InteractiveUserSid {
    if ($Script:InteractiveUserSid) { return $Script:InteractiveUserSid }
    $sid = $null
    # 1) owner of the user-mode explorer.exe (desktop shell) — most reliable.
    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" `
                        -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($explorer) {
            $own = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner `
                        -ErrorAction SilentlyContinue
            if ($own -and $own.ReturnValue -eq 0 -and $own.Domain -and $own.User) {
                try {
                    $acct = New-Object System.Security.Principal.NTAccount ("$($own.Domain)\$($own.User)")
                    $sid  = $acct.Translate([System.Security.Principal.SecurityIdentifier]).Value
                } catch { }
            }
        }
    } catch { }
    # 2) fallback: owner of the active logon session via WMI.
    if (-not $sid) {
        try {
            $sess = Get-CimInstance Win32_LogonSession -Filter 'LogonType = 2 OR LogonType = 10' `
                        -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($sess) {
                $user = Get-CimAssociatedInstance -InputObject $sess -ResultClassName Win32_Account `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($user) { $sid = $user.SID }
            }
        } catch { }
    }
    # 3) last-ditch: own SID.
    if (-not $sid) {
        $sid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    }
    $Script:InteractiveUserSid = $sid
    return $sid
}

function Get-InternetSettingsHivePath {
    if ($Script:InteractiveHivePath) { return $Script:InteractiveHivePath }
    $mySid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $intSid = Get-InteractiveUserSid
    if ($intSid -and $intSid -ne $mySid) {
        # Different user — write via HKEY_USERS\<SID>. Ensure the hive is mapped
        # (a logged-in user's hive is always mapped; if not, we fall back).
        $huPath = "Registry::HKEY_USERS\$intSid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        if (Test-Path -LiteralPath $huPath) {
            $Script:InteractiveHivePath = $huPath
            return $huPath
        }
    }
    $Script:InteractiveHivePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    return $Script:InteractiveHivePath
}

# ============================================================================
# Reusable helpers
# ============================================================================
function Read-DomainList([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) { $null = $out.Add($t) }
    }
    @($out)
}

function Test-WinwsRunning {
    @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue).Count -gt 0
}

function Test-ServiceInstalled([string]$name) {
    $null -ne (Get-Service -Name $name -ErrorAction SilentlyContinue)
}

function Test-ServiceRunning([string]$name) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    $svc -and $svc.Status -eq 'Running'
}

# ============================================================================
# DPI services -> rewrite list-general-user.txt
# ============================================================================
# Apply-Services rewrites lists/list-general-user.txt based on user toggles.
# It is idempotent: if the result would match what's already on disk, we skip
# the write. This matters because every checkbox click used to trigger a disk
# write (and an AV scan on Defender-enabled machines), which was visibly slow.
function Apply-Services([hashtable]$cfg) {
    $target = Join-Path $ListsDir 'list-general-user.txt'
    $domains = New-Object System.Collections.Generic.List[string]

    foreach ($key in $Services.Keys) {
        $svc = $Services[$key]
        if ($svc.AlwaysOn) { continue }
        if ($cfg["service_$key"] -ne '1') { continue }
        foreach ($d in (Read-DomainList (Join-Path $ListsDir $svc.File))) {
            $null = $domains.Add($d)
        }
    }

    $custom = Join-Path $ListsDir 'list-custom.txt'
    foreach ($d in (Read-DomainList $custom)) { $null = $domains.Add($d) }

    $desired = if ($domains.Count -eq 0) {
        @('domain.example.abc')
    } else {
        @($domains | Sort-Object -Unique)
    }

    # Skip the write if the content is already identical — saves ~30-80ms per
    # call and avoids spurious FS-watch / AV-scan wakeups.
    if (Test-Path -LiteralPath $target) {
        try {
            $current = Get-Content -LiteralPath $target -Encoding UTF8 -ErrorAction Stop
            if (-not $current) { $current = @() }
            if (($current.Count -eq $desired.Count) -and
                (-not (Compare-Object -ReferenceObject $current -DifferenceObject $desired -SyncWindow 0))) {
                return
            }
        } catch { }
    }
    Write-Utf8NoBom $target $desired
}

# ============================================================================
# Strategy enumeration
# ============================================================================
function Get-StrategyFiles {
    Get-ChildItem -LiteralPath $RepoRoot -Filter '*.bat' |
        Where-Object {
            $_.Name -notlike 'service*' -and
            $_.Name -notlike 'launcher*' -and
            $_.Name -notlike 'start*'
        } |
        Sort-Object {
            [Regex]::Replace($_.Name, '(\d+)', { param($m) $m.Value.PadLeft(8, '0') })
        } |
        Select-Object -ExpandProperty Name
}

# ============================================================================
# Geo routing — PAC file for selective WARP
# ============================================================================
function Get-GeoDomainsForConfig([hashtable]$cfg) {
    $domains = New-Object System.Collections.Generic.List[string]
    foreach ($key in $GeoServices.Keys) {
        if ($cfg["geo_$key"] -ne '1') { continue }
        foreach ($d in (Read-DomainList (Join-Path $ListsDir $GeoServices[$key].File))) {
            $null = $domains.Add($d.ToLowerInvariant())
        }
    }
    # User-provided extras (one per line in lists/geo-custom.txt).
    $extra = Join-Path $ListsDir 'geo-custom.txt'
    foreach ($d in (Read-DomainList $extra)) { $null = $domains.Add($d.ToLowerInvariant()) }
    @($domains | Sort-Object -Unique)
}

function Build-PacScript([string[]]$domains, [string]$proxyTarget = 'SOCKS5 127.0.0.1:40000; SOCKS 127.0.0.1:40000; DIRECT') {
    # JS array literal of domains.
    $jsArr = ($domains | ForEach-Object {
        '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"'
    }) -join ", "
    $pac = @"
// codeDPI launcher PAC — auto-generated.
// Routes geo-blocked domains via Cloudflare WARP SOCKS5; everything else direct
// (so zapret/winws can do its DPI desync on the rest).
function FindProxyForURL(url, host) {
    host = (host || '').toLowerCase();
    var domains = [$jsArr];
    for (var i = 0; i < domains.length; i++) {
        var d = domains[i];
        if (host === d) { return '$proxyTarget'; }
        if (host.length > d.length &&
            host.charAt(host.length - d.length - 1) === '.' &&
            host.substring(host.length - d.length) === d) {
            return '$proxyTarget';
        }
    }
    return 'DIRECT';
}
"@
    $pac
}

function Write-PacFile([hashtable]$cfg) {
    $domains = Get-GeoDomainsForConfig $cfg
    $pac = Build-PacScript -domains $domains
    Write-Utf8NoBom $PacPath @($pac)
    return @{ Path = $PacPath; DomainCount = $domains.Count }
}

function Get-PacPort([hashtable]$cfg) {
    $p = 0
    if ($cfg -and [int]::TryParse([string]$cfg.pac_port, [ref]$p) -and $p -gt 0) { return $p }
    return $DefaultPacPort
}

function Get-PacFileUrl([hashtable]$cfg) {
    # Modern Chrome/Edge handle file:// PAC URLs unreliably (depends on version
    # and security policy). Serve the PAC over a tiny localhost HTTP server
    # instead — universally supported.
    $port = Get-PacPort $cfg
    "http://127.0.0.1:$port/launcher.pac"
}

function Test-PacServerRunning {
    if (-not (Test-Path -LiteralPath $PacServerPidFile)) { return $false }
    $procId = 0
    try { $procId = [int](Get-Content -LiteralPath $PacServerPidFile -Raw -ErrorAction Stop).Trim() } catch { return $false }
    if ($procId -le 0) { return $false }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    return [bool]$proc
}

function Stop-PacServer {
    $procId = 0
    if (Test-Path -LiteralPath $PacServerPidFile) {
        try { $procId = [int](Get-Content -LiteralPath $PacServerPidFile -Raw).Trim() } catch { $procId = 0 }
    }
    if ($procId -gt 0) {
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                # Wait for actual exit so subsequent rebind doesn't race.
                $deadline = (Get-Date).AddSeconds(2)
                while ((Get-Date) -lt $deadline) {
                    if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 80
                }
            }
        } catch { }
    }
    Remove-Item -LiteralPath $PacServerPidFile -ErrorAction SilentlyContinue
}

function Test-PortInUse([int]$port) {
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync('127.0.0.1', $port)
        return ($task.Wait(300) -and $tcp.Connected)
    } catch {
        return $false
    } finally {
        if ($tcp) { try { $tcp.Close() } catch { } }
    }
}

function Wait-PacServerReady([int]$port, [int]$timeoutMs = 3000) {
    # Probe the listener with raw HTTP — works on PS5.1 (Windows) and pwsh on
    # Linux without the Invoke-WebRequest stream-buffering quirk.
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $tcp = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $task = $tcp.ConnectAsync('127.0.0.1', $port)
            if ($task.Wait(500) -and $tcp.Connected) {
                $stream = $tcp.GetStream()
                $stream.ReadTimeout  = 1500
                $stream.WriteTimeout = 1500
                $req = "GET /launcher.pac HTTP/1.0`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"
                $bytes = [Text.Encoding]::ASCII.GetBytes($req)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                if ($body -match 'FindProxyForURL') { return $true }
            }
        } catch { }
        finally {
            if ($tcp) { try { $tcp.Close() } catch { } }
        }
        Start-Sleep -Milliseconds 120
    }
    return $false
}

function Start-PacServer([hashtable]$cfg) {
    Stop-PacServer
    if (-not (Test-Path -LiteralPath $PacServerScript)) {
        throw "PAC server script not found: $PacServerScript"
    }
    if (-not (Test-Path -LiteralPath $PacPath)) {
        # Generate placeholder PAC so listener has something to serve immediately.
        Write-PacFile $cfg | Out-Null
    }
    $port = Get-PacPort $cfg

    # If the configured port is occupied by something OTHER than us, auto-bump
    # up to 5 candidate ports before giving up. This avoids the common pain of
    # "port 27289 already in use" from an earlier orphaned instance AV killed.
    if (Test-PortInUse $port) {
        $bumped = $false
        foreach ($cand in @(27290, 27291, 27292, 27293, 27294)) {
            if (-not (Test-PortInUse $cand)) {
                Write-LauncherLog "PAC port $port busy — falling back to $cand." 'Yellow'
                $port = $cand
                $cfg.pac_port = "$port"
                Save-Config $cfg
                $bumped = $true
                break
            }
        }
        if (-not $bumped) {
            throw "PAC port $port is in use and ports 27290-27294 are all busy too. Change pac_port in launcher.conf manually."
        }
    }

    # Avoid clobbering the automatic $args variable.
    $psArgs = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                '-File', $PacServerScript, '-PacPath', $PacPath, '-Port', $port)
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden -PassThru
    if (-not $proc) { throw 'Failed to spawn PAC server process.' }

    Set-Content -LiteralPath $PacServerPidFile -Value $proc.Id -Encoding ASCII

    # Probe the listener instead of a blind sleep — detect bind failures fast.
    if (-not (Wait-PacServerReady -port $port -timeoutMs 3000)) {
        # Listener never came up — clean up the orphan process + PID file.
        try {
            $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
            if ($alive) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        } catch { }
        Remove-Item -LiteralPath $PacServerPidFile -ErrorAction SilentlyContinue
        throw "PAC server failed to start on port $port within 3s."
    }

    return @{ Port = $port; Pid = $proc.Id; Url = "http://127.0.0.1:$port/launcher.pac" }
}

function Enable-PacAutoConfig([hashtable]$cfg) {
    $url = Get-PacFileUrl $cfg
    $regKey = Get-InternetSettingsHivePath
    Set-ItemProperty -Path $regKey -Name AutoConfigURL -Value $url
    # Disable static proxy if it was set; AutoConfigURL takes precedence in some
    # browsers but better to be explicit.
    try { Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue } catch { }
    # Bump WinInet's cache counter so Chrome/Edge pick up the new PAC URL
    # without needing a restart.
    try { Invoke-WinInetSettingsChanged } catch { }
    return $url
}

function Disable-PacAutoConfig {
    $regKey = Get-InternetSettingsHivePath
    try { Remove-ItemProperty -Path $regKey -Name AutoConfigURL -ErrorAction SilentlyContinue } catch { }
    try { Invoke-WinInetSettingsChanged } catch { }
}

function Test-PacEnabled([hashtable]$cfg) {
    $regKey = Get-InternetSettingsHivePath
    $u = (Get-ItemProperty -Path $regKey -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    if (-not $u) { return $false }
    if ($cfg) {
        return ($u -ieq (Get-PacFileUrl $cfg))
    }
    return ($u -match '^http://127\.0\.0\.1:\d+/launcher\.pac$')
}

# WinInet setting-changed broadcast — tells Chrome/Edge/IE to re-read
# Internet Settings without relaunching. Wrapped in try/catch because on
# some locked-down hosts InternetSetOption can return ERROR_NOT_SUPPORTED.
$Script:WinInetSignalType = $null
function Invoke-WinInetSettingsChanged {
    if (-not $Script:WinInetSignalType) {
        $src = @'
using System;
using System.Runtime.InteropServices;
public static class WinInet {
    [DllImport("wininet.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
'@
        try { Add-Type -TypeDefinition $src -ErrorAction Stop; $Script:WinInetSignalType = $true } catch { $Script:WinInetSignalType = $false }
    }
    if ($Script:WinInetSignalType) {
        # INTERNET_OPTION_SETTINGS_CHANGED = 39, INTERNET_OPTION_REFRESH = 37
        [void][WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    }
}

# ============================================================================
# Cloudflare WARP
# ============================================================================
function Get-WarpCli {
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $p = Join-Path $base 'Cloudflare\Cloudflare WARP\warp-cli.exe'
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command 'warp-cli.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-WarpCli {
    param([Parameter(ValueFromRemainingArguments=$true)] [string[]]$ArgList)
    $exe = Get-WarpCli
    if (-not $exe) { throw 'warp-cli не найден. Установите Cloudflare WARP с https://1.1.1.1/ или через winget.' }
    # IMPORTANT: isolate warp-cli's native stderr from $ErrorActionPreference.
    # With 2>&1 + 'Stop', PowerShell wraps ANY stderr line in a terminating
    # NativeCommandError, so callers can't see $LASTEXITCODE to fall back on
    # a different subcommand. We force Continue here so the caller gets the
    # real output + exit code.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @ArgList 2>&1
    } finally {
        $ErrorActionPreference = $prev
    }
}

# warp-cli status spawns a process and can take 50-300ms per call. The status
# updater fires every 3s, so we cache the result with a short TTL.
$Script:WarpStatusCache       = $null
$Script:WarpStatusCacheExpiry = [datetime]::MinValue

function Get-WarpStatus {
    param([switch]$Force)
    if (-not $Force -and $Script:WarpStatusCache -and (Get-Date) -lt $Script:WarpStatusCacheExpiry) {
        return $Script:WarpStatusCache
    }
    $exe = Get-WarpCli
    if (-not $exe) {
        $st = @{ Installed=$false; Connected=$false; Mode='unknown'; Raw='' }
    } else {
        # Isolate from $ErrorActionPreference='Stop' — same reason as Invoke-WarpCli.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = ''
        try { $out = (& $exe 'status' 2>&1) -join "`n" } catch { $out = "$_" }
        finally { $ErrorActionPreference = $prev }
        # Accept several localisations of the status line.
        # Real warp-cli output samples:
        #   "Status update: Connected"            (EN)
        #   "Status update: Disconnected"         (EN)
        #   "Status: Connecting"                  (older)
        #   "Статус: Подключено"                  (RU locale — rare but happens)
        $connected = ($out -match '(?im)^\s*(Status(?:\s+update)?|Статус)\s*:\s*(Connected|Connecting|Подключено|Подключение)\b')
        $st = @{ Installed=$true; Connected=$connected; Raw=$out }
    }
    $Script:WarpStatusCache       = $st
    $Script:WarpStatusCacheExpiry = (Get-Date).AddSeconds(5)
    return $st
}

function Reset-WarpStatusCache {
    $Script:WarpStatusCache       = $null
    $Script:WarpStatusCacheExpiry = [datetime]::MinValue
}

function Set-WarpMode([string]$mode) {
    $exe = Get-WarpCli
    if (-not $exe) { throw 'warp-cli не найден.' }

    # warp-cli CLI syntax has changed across versions. Current (2024.x) is
    # the simple form; the other two exist for older/newer forks.
    #   primary (2024 stable):  `warp-cli mode <mode>`
    #   pre-2023 / some MSI:    `warp-cli set-mode <mode>`
    #   some niche 2024.10:     `warp-cli mode set <mode>`
    # Try in that order. Stop at the first attempt that either returns rc=0
    # OR produces an error that ISN'T "unrecognized subcommand" (= syntax OK,
    # but mode change itself failed — don't mask that with a later attempt).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $attempts = @(
        @{ ArgList = @('mode', $mode);        Label = 'mode' }
        @{ ArgList = @('set-mode', $mode);    Label = 'set-mode' }
        @{ ArgList = @('mode', 'set', $mode); Label = 'mode set' }
    )
    $lastErr = ''
    $succeeded = $false
    try {
        foreach ($a in $attempts) {
            $out = & $exe @($a.ArgList) 2>&1
            $rc  = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
            $outStr = (@($out) | Where-Object { $_ }) -join ' | '
            if ($rc -eq 0 -and ($outStr -notmatch 'unrecognized|unknown|error:')) {
                $succeeded = $true
                break
            }
            $lastErr = "rc=$rc ($($a.Label)): $outStr"
            # If the syntax wasn't recognized at all, try the next one; but if
            # it was recognized and just failed (ToS not accepted, service
            # down, etc.), surface that error instead of masking it.
            if ($outStr -notmatch 'unrecognized|unknown') {
                break
            }
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not $succeeded) {
        throw "warp-cli не принял режим '$mode'. $lastErr"
    }
    Reset-WarpStatusCache
}

function Connect-Warp {
    $out = Invoke-WarpCli 'connect'
    Reset-WarpStatusCache
    $out
}

function Disconnect-Warp {
    $out = Invoke-WarpCli 'disconnect'
    Reset-WarpStatusCache
    $out
}

# Accept Cloudflare ToS non-interactively. Newer warp-cli versions require an
# explicit registration before connect/mode commands work. If this fails we
# just ignore it — the underlying command will surface the real error.
function Register-WarpClient {
    $exe = Get-WarpCli
    if (-not $exe) { return $false }
    # Try the 2024.x style first.
    try { & $exe 'registration' 'new' 2>&1 | Out-Null } catch { }
    # Pre-2024 style.
    try { & $exe 'register' 2>&1 | Out-Null } catch { }
    # Some builds (2024.10+) gate everything behind `warp-cli --accept-tos`.
    try { & $exe '--accept-tos' 2>&1 | Out-Null } catch { }
    return $true
}

function Install-Warp {
    Write-LauncherLog 'Установка Cloudflare WARP через winget... это может занять 1-2 минуты.' 'Yellow'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-LauncherLog 'winget недоступен. Скачайте установщик с https://1.1.1.1/' 'Red'
        return $false
    }
    $wingetArgs = @(
        'install', '--id', 'Cloudflare.Warp', '-e',
        '--accept-package-agreements', '--accept-source-agreements',
        '--silent'
    )
    & winget @wingetArgs 2>&1 | ForEach-Object { Write-LauncherLog $_ 'DarkGray' }
    Write-LauncherLog '' 'White'
    Reset-WarpStatusCache

    # Wait for the service + exe to actually appear on disk. winget returns
    # before the MSI post-install hooks finish, especially on first install.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Get-WarpCli) { break }
        Start-Sleep -Seconds 1
    }

    if (Get-WarpCli) {
        Write-LauncherLog 'WARP установлен. Регистрация клиента (принимает ToS)...' 'Green'
        Register-WarpClient | Out-Null

        # The CloudflareWARP Windows service needs to be running before
        # warp-cli connect/mode can talk to it. On fresh installs it is
        # sometimes in "Stopped" state until the first user login.
        try {
            $svc = Get-Service -Name 'CloudflareWARP' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') {
                Write-LauncherLog 'Запуск службы CloudflareWARP...' 'Cyan'
                Start-Service -Name 'CloudflareWARP' -ErrorAction SilentlyContinue
            }
        } catch { }
        return $true
    }
    Write-LauncherLog 'Установка завершилась, но warp-cli.exe не найден. Проверьте установку вручную.' 'Yellow'
    return $false
}

# Ensures Cloudflare WARP is installed; if missing, kicks off Install-Warp.
# Caller passes the cfg so we can respect the user's auto_install_warp toggle
# (default '1' — auto-install). Returns $true once warp-cli is available.
function Ensure-WarpInstalled([hashtable]$cfg) {
    $st = Get-WarpStatus -Force
    if ($st.Installed) {
        # Already installed — make sure the service is actually running,
        # otherwise warp-cli connect will hang forever with a vague error.
        try {
            $svc = Get-Service -Name 'CloudflareWARP' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') {
                Write-LauncherLog 'Служба CloudflareWARP остановлена — запускаю...' 'Cyan'
                Start-Service -Name 'CloudflareWARP' -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }
        } catch { }
        return $true
    }

    if ($cfg -and $cfg.auto_install_warp -ne '1') {
        Write-LauncherLog 'WARP не установлен, auto_install_warp=0 — пропускаю.' 'DarkGray'
        return $false
    }

    Write-LauncherLog 'WARP не установлен — устанавливаю автоматически (winget)...' 'Yellow'
    $ok = Install-Warp
    if (-not $ok) {
        Write-LauncherLog 'Автоустановка WARP не удалась.' 'Red'
        return $false
    }
    Reset-WarpStatusCache
    Start-Sleep -Seconds 2
    return ((Get-WarpStatus -Force).Installed)
}

function Install-WireGuard {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-LauncherLog 'winget not available — get installer from https://www.wireguard.com/install/' 'Yellow'
        return $false
    }
    & winget install -e --id WireGuard.WireGuard --accept-package-agreements --accept-source-agreements 2>&1 |
        ForEach-Object { Write-LauncherLog $_ 'DarkGray' }
    return $true
}

# ============================================================================
# WireGuard / system proxy
# ============================================================================
function Get-WireGuardExe {
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $p = Join-Path $base 'WireGuard\wireguard.exe'
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-WireGuardTunnels {
    @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'WireGuardTunnel$*' })
}

function Install-WireGuardTunnel([string]$confPath) {
    if (-not (Test-Path -LiteralPath $confPath)) {
        throw "File not found: $confPath"
    }
    $wg = Get-WireGuardExe
    if (-not $wg) { throw 'WireGuard for Windows is not installed.' }
    & $wg /installtunnelservice $confPath
}

function Stop-WireGuardTunnels {
    $tunnels = Get-WireGuardTunnels
    if (-not $tunnels) { return 0 }
    foreach ($t in $tunnels) {
        & sc.exe stop $t.Name | Out-Null
        & sc.exe delete $t.Name | Out-Null
    }
    return $tunnels.Count
}

function Set-SystemProxy([string]$proxy) {
    if (-not $proxy) { throw 'Proxy string required.' }
    $regKey = Get-InternetSettingsHivePath
    Set-ItemProperty -Path $regKey -Name ProxyServer -Value $proxy
    Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -Path $regKey -Name ProxyOverride -Value '<local>'
    # Use stop-parsing (--%) so cmd-style quoting in $proxy cannot inject flags.
    $safeProxy = $proxy -replace '"', ''
    & netsh.exe winhttp set proxy $safeProxy '<local>' | Out-Null
    try { Invoke-WinInetSettingsChanged } catch { }
}

function Disable-SystemProxy {
    $regKey = Get-InternetSettingsHivePath
    Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 0 -Type DWord
    & netsh.exe winhttp reset proxy | Out-Null
    try { Invoke-WinInetSettingsChanged } catch { }
}

function Get-SystemProxyStatus {
    $regKey = Get-InternetSettingsHivePath
    $enabled = (Get-ItemProperty -Path $regKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $server  = (Get-ItemProperty -Path $regKey -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
    $auto    = (Get-ItemProperty -Path $regKey -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    @{ Enabled = ($enabled -eq 1); Server = $server; AutoConfigURL = $auto }
}

# ============================================================================
# Bypass control
# ============================================================================
function Stop-Bypass {
    if (-not (Test-WinwsRunning)) { return }
    # First try graceful Stop-Process (sends WM_CLOSE where possible, then
    # kills). If the process is pinned by a hung WinDivert IOCTL it may refuse
    # to die — fall back to taskkill /F /T after a short wait.
    Get-Process -Name 'winws' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(2)
    while ((Test-WinwsRunning) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-WinwsRunning) {
        # Last-ditch — tree-kill. winws normally has no children but the bat
        # launcher can spawn intermediate cmd.exe which held a handle.
        try {
            & taskkill.exe /F /IM winws.exe /T 2>$null | Out-Null
        } catch { }
        $deadline = (Get-Date).AddSeconds(2)
        while ((Test-WinwsRunning) -and ((Get-Date) -lt $deadline)) {
            Start-Sleep -Milliseconds 120
        }
    }
}

function Start-Bypass([hashtable]$cfg) {
    if (Test-ServiceRunning 'zapret') {
        return @{ Success=$false; Message='zapret service is RUNNING. Remove the service first or use service.bat.' }
    }
    Stop-Bypass
    Apply-Services $cfg

    $batPath = Join-Path $RepoRoot $cfg.strategy
    if (-not (Test-Path -LiteralPath $batPath)) {
        return @{ Success=$false; Message="Strategy file not found: $($cfg.strategy)" }
    }

    Write-LauncherLog "Starting strategy: $($cfg.strategy)" 'Green'
    # Invoke via cmd.exe so the strategy's own `start "..." /min winws.exe ...`
    # detaches cleanly. We fire-and-forget (no Wait-Process) — the bat finishes
    # almost instantly; winws.exe is the thing we actually watch for.
    # Note: strategy filenames contain spaces and parentheses (e.g.
    # "general (ALT3).bat") — must be properly quoted for cmd.exe.
    $cmdArgs = "/d /c `"call `"$batPath`"`""
    Start-Process -FilePath $env:ComSpec -ArgumentList $cmdArgs -WindowStyle Hidden -Wait:$false | Out-Null

    # Poll for winws.exe instead of a blind Start-Sleep 2 — usually ready in
    # ~300ms, but slow disks / AV scan can delay up to a couple of seconds.
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
        if (Test-WinwsRunning) { break }
        Start-Sleep -Milliseconds 120
    }

    if (-not (Test-WinwsRunning)) {
        return @{ Success=$false; Message='winws.exe did not start within 6s. Check the strategy file or run diagnostics.' }
    }
    return @{ Success=$true; Message="Bypass started: $($cfg.strategy)" }
}

# ============================================================================
# Combined: zapret + WARP + PAC routing
# ============================================================================
#
# Start-Mode is the unified entry point. Mode selects what to start:
#   'dpi'  — only zapret (winws.exe). Use when you only need to bypass
#            ISP-side DPI for YouTube/Discord/Telegram/etc.
#   'warp' — only Cloudflare WARP + PAC routing. Use when you only need
#            to bypass server-side geo-blocks for ChatGPT/Claude/Gemini/etc.
#   'all'  — both layers (the original Start-Combined behavior).
#
# When the WARP layer is requested but Cloudflare WARP is not installed yet,
# Start-Mode auto-installs it via winget — controlled by cfg.auto_install_warp
# (default '1'). This is what removes the "warp: not installed" footgun.
function Start-Mode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $cfg,
        [Parameter(Mandatory)] [ValidateSet('dpi','warp','all')] [string] $Mode
    )

    $result = @{
        Success      = $false
        Mode         = $Mode
        Message      = ''
        Bypass       = $false
        Warp         = $false
        Pac          = $false
        Errors       = New-Object System.Collections.Generic.List[string]
        DomainCount  = 0
    }

    $wantBypass = ($Mode -eq 'dpi'  -or $Mode -eq 'all')
    $wantWarp   = ($Mode -eq 'warp' -or $Mode -eq 'all')

    # 1. zapret (DPI bypass).
    if ($wantBypass) {
        $r = Start-Bypass $cfg
        $result.Bypass = [bool]$r.Success
        if (-not $r.Success) {
            $result.Errors.Add("zapret: $($r.Message)") | Out-Null
        }
    } else {
        # If user picks WARP-only, make sure any leftover winws is stopped so
        # the status line is honest.
        Stop-Bypass
    }

    # 2. WARP + PAC.
    if ($wantWarp) {
        $installed = Ensure-WarpInstalled $cfg
        if (-not $installed) {
            $result.Errors.Add('WARP не установлен (авто-установка не удалась или выключена).') | Out-Null
        } else {
            # Always try to register before any mode/connect — on fresh installs
            # warp-cli refuses everything until --accept-tos + registration.
            # Safe to run repeatedly; no-op if already registered.
            try { Register-WarpClient | Out-Null } catch { }

            $modeOk = $false
            try {
                Set-WarpMode 'proxy'
                $modeOk = $true
            } catch {
                $result.Errors.Add("WARP: не удалось выставить режим proxy — $_") | Out-Null
                Write-LauncherLog "WARP mode error: $_" 'Red'
                Write-LauncherLog 'Подсказка: откройте Cloudflare WARP из трея, примите ToS, затем попробуйте снова.' 'Yellow'
            }

            if ($modeOk) {
                try {
                    $warp = Get-WarpStatus -Force
                    if (-not $warp.Connected) {
                        Write-LauncherLog 'WARP: подключение (proxy mode 127.0.0.1:40000)...' 'Cyan'
                        $connectOut = Connect-Warp
                        if ($connectOut) {
                            foreach ($l in ($connectOut -split "`r?`n")) {
                                if ($l.Trim()) { Write-LauncherLog "  warp-cli: $($l.Trim())" 'DarkGray' }
                            }
                        }
                    }
                    # Poll up to 20s for both Connected AND SOCKS5 proxy port.
                    # Status=Connected alone isn't enough — "Performing happy
                    # eyeballs" is reported as Connected but the SOCKS5
                    # listener on :40000 opens ~1-2 sec later. We wait for
                    # both, so callers can trust result.Warp=true.
                    $deadline = (Get-Date).AddSeconds(20)
                    $now = $warp
                    $socksReady = $false
                    while ((Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 500
                        $now = Get-WarpStatus -Force
                        if ($now.Connected) {
                            $socksReady = Test-PortInUse 40000
                            if ($socksReady) { break }
                        }
                    }
                    if ($now.Connected -and $socksReady) {
                        $result.Warp = $true
                        Write-LauncherLog 'WARP подключён, SOCKS5 на 127.0.0.1:40000 открыт.' 'Green'
                    } elseif ($now.Connected) {
                        $result.Errors.Add('WARP: статус Connected, но SOCKS5 порт 40000 не открылся за 20 сек.') | Out-Null
                        Write-LauncherLog 'WARP: порт 40000 не открыт — возможно включён не proxy режим.' 'Yellow'
                    } else {
                        $rawTail = ($now.Raw -split "`n" | Select-Object -Last 3) -join ' | '
                        $result.Errors.Add("WARP: статус не Connected за 20 сек. Последний статус: $rawTail") | Out-Null
                        Write-LauncherLog "WARP: Connected не получен за 20 сек. Статус: $rawTail" 'Yellow'
                    }
                } catch {
                    $result.Errors.Add("WARP connect: $_") | Out-Null
                    Write-LauncherLog "WARP autostart failed: $_" 'Yellow'
                }
            }

            # PAC routing — only sensible if WARP proxy is up. WARP-only mode
            # implies geo routing; in 'all' mode it's gated by cfg.geo_routing.
            $wantPac = ($Mode -eq 'warp') -or ($cfg.geo_routing -eq '1')
            if ($wantPac -and $result.Warp) {
                try {
                    $info = Write-PacFile $cfg
                    $result.DomainCount = $info.DomainCount
                    $srv = Start-PacServer $cfg
                    Enable-PacAutoConfig $cfg | Out-Null
                    $result.Pac = $true
                    Write-LauncherLog ("PAC routing on: {0} domain(s) -> WARP, rest direct ({1})." -f $info.DomainCount, $srv.Url) 'Cyan'
                } catch {
                    $result.Errors.Add("pac: $_") | Out-Null
                    Write-LauncherLog "PAC setup failed: $_" 'Yellow'
                }
            } elseif ($wantPac -and -not $result.Warp) {
                Write-LauncherLog 'PAC routing skipped: WARP is not connected.' 'DarkGray'
            }
        }
    } else {
        # Mode == 'dpi'. If a previous run had PAC/WARP up, pull them down so
        # the user sees a consistent state.
        if (Test-PacEnabled $cfg) { Disable-PacAutoConfig }
        if (Test-PacServerRunning) { Stop-PacServer }
    }

    # Mode-aware Success: don't fail the WARP-only mode just because zapret
    # wasn't asked, and vice versa.
    switch ($Mode) {
        'dpi'  { $result.Success = $result.Bypass }
        'warp' { $result.Success = $result.Warp }
        'all'  { $result.Success = $result.Bypass }
    }

    # Summary line — only mention layers we actually tried to bring up.
    $parts = @()
    if ($wantBypass) { $parts += $(if ($result.Bypass) { 'zapret OK' } else { 'zapret FAILED' }) }
    if ($wantWarp)   {
        $parts += $(if ($result.Warp) { 'WARP OK' } else { 'WARP off' })
        if (($Mode -eq 'warp') -or ($cfg.geo_routing -eq '1')) {
            $parts += $(if ($result.Pac) { "PAC OK ($($result.DomainCount))" } else { 'PAC off' })
        }
    }
    $result.Message = ($parts -join '   |   ')
    return $result
}

# Backward-compatible wrapper. Old callers (gui.ps1, launcher.ps1) used to
# branch on cfg.warp_autostart to decide whether to bring up WARP. Preserve
# that contract by mapping the toggle to the new Mode parameter.
function Start-Combined([hashtable]$cfg) {
    $mode = if ($cfg.warp_autostart -eq '1') { 'all' } else { 'dpi' }
    return Start-Mode -cfg $cfg -Mode $mode
}

function Stop-Combined([hashtable]$cfg) {
    Stop-Bypass

    # Always disable PAC + kill server even if cfg.warp_autostart toggled off
    # since last Start, otherwise we leak state.
    if (Test-PacEnabled $cfg) {
        Disable-PacAutoConfig
        Write-LauncherLog 'PAC routing disabled (AutoConfigURL removed).' 'DarkGray'
    }
    if (Test-PacServerRunning) {
        Stop-PacServer
        Write-LauncherLog 'PAC server stopped.' 'DarkGray'
    }

    $warp = Get-WarpStatus -Force
    if ($warp.Installed -and $warp.Connected) {
        try { Disconnect-Warp; Write-LauncherLog 'WARP disconnected.' 'DarkGray' } catch { }
    }
}

# ============================================================================
# Connectivity smoke-test
# ============================================================================
function Test-Connectivity([hashtable]$cfg) {
    # Returns @{ Dpi=@{Ok;Detail}; Geo=@{Ok;Detail}; PacServer=@{Ok;Detail}; Warp=@{Ok;Detail} }
    $r = @{
        Dpi       = @{ Ok=$false; Detail='not tested' }
        Geo       = @{ Ok=$false; Detail='not tested' }
        PacServer = @{ Ok=$false; Detail='not tested' }
        Warp      = @{ Ok=$false; Detail='not tested' }
    }

    # PAC server reachable?
    if (Test-PacServerRunning) {
        $port = Get-PacPort $cfg
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/launcher.pac" -UseBasicParsing -TimeoutSec 3
            # Invoke-WebRequest returns $resp.Content as a BYTE ARRAY when the
            # response Content-Type is not text/*. Our PAC server uses
            # 'application/x-ns-proxy-autoconfig', so we must decode manually.
            $body = if ($resp.Content -is [byte[]]) {
                [Text.Encoding]::UTF8.GetString($resp.Content)
            } else {
                [string]$resp.Content
            }
            if ($resp.StatusCode -eq 200 -and $body -match 'FindProxyForURL') {
                $r.PacServer = @{ Ok=$true; Detail="раздаётся на 127.0.0.1:$port ($([Math]::Round($body.Length/1024,1)) KB)" }
            } else {
                $r.PacServer = @{ Ok=$false; Detail="bad response: HTTP $($resp.StatusCode) (body $($body.Length) chars)" }
            }
        } catch { $r.PacServer = @{ Ok=$false; Detail="$_" } }
    } else {
        $r.PacServer = @{ Ok=$false; Detail='PAC-сервер не запущен' }
    }

    # WARP proxy port (40000) — TCP reachable? AND does SOCKS5 handshake work?
    $warpPing = $false
    $warpDetail = 'SOCKS5-порт 40000 не слушается (WARP в proxy-режиме не запущен)'
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync('127.0.0.1', 40000)
        if ($task.Wait(2000) -and $tcp.Connected) {
            # Port is open. Try SOCKS5 no-auth handshake to confirm it's
            # actually a SOCKS5 server and not some other process squatting
            # on :40000 (happens surprisingly often with other VPN clients).
            try {
                $stream = $tcp.GetStream()
                $stream.ReadTimeout = 1500
                $stream.WriteTimeout = 1500
                # Greeting: VER=5, NMETHODS=1, METHOD=0(no-auth)
                $stream.Write(([byte[]]@(0x05, 0x01, 0x00)), 0, 3)
                $buf = New-Object byte[] 2
                $read = $stream.Read($buf, 0, 2)
                if ($read -ge 2 -and $buf[0] -eq 0x05 -and $buf[1] -eq 0x00) {
                    $warpPing = $true
                    $warpDetail = 'SOCKS5-прокси на 127.0.0.1:40000 отвечает корректно'
                } else {
                    $warpDetail = "порт 40000 открыт, но не SOCKS5 (greeting: $($buf[0]),$($buf[1]))"
                }
            } catch {
                $warpDetail = "порт 40000 открыт, но SOCKS5 handshake упал: $($_.Exception.Message)"
            }
        }
        $tcp.Close()
    } catch { }
    $r.Warp = @{ Ok=$warpPing; Detail=$warpDetail }

    # DPI test — direct fetch to youtube. If zapret + winws is OK, this should
    # return 200/204 even on RU networks. We MUST bypass any system proxy so
    # the PAC doesn't redirect this through WARP (which would mask a DPI
    # failure as "OK"). Invoke-WebRequest -Proxy $null in PS5.1 does NOT reset
    # WebRequest.DefaultWebProxy — so use HttpWebRequest directly with an
    # explicit null proxy.
    try {
        $req = [System.Net.HttpWebRequest]::Create('https://www.youtube.com/generate_204')
        $req.Proxy = $null
        $req.AllowAutoRedirect = $false
        $req.Timeout = 6000
        $req.ReadWriteTimeout = 6000
        $req.UserAgent = 'codeDPI-smoketest/1.0'
        $resp = $req.GetResponse()
        try {
            $code = [int]$resp.StatusCode
            $r.Dpi = @{ Ok=($code -eq 204 -or $code -eq 200); Detail="HTTP $code from youtube.com (direct bypass-proxy)" }
        } finally { $resp.Close() }
    } catch [System.Net.WebException] {
        $we = $_.Exception
        $status = 0
        if ($we.Response) {
            try { $status = [int]([System.Net.HttpWebResponse]$we.Response).StatusCode } catch { }
            try { $we.Response.Close() } catch { }
        }
        if ($status -eq 204 -or $status -eq 200) {
            $r.Dpi = @{ Ok=$true; Detail="HTTP $status from youtube.com (direct bypass-proxy)" }
        } else {
            $r.Dpi = @{ Ok=$false; Detail="direct youtube.com failed: $($we.Message)" }
        }
    } catch {
        $r.Dpi = @{ Ok=$false; Detail="direct youtube.com failed: $($_.Exception.Message)" }
    }

    # Geo test — chatgpt.com via the WARP SOCKS5 proxy (if up).
    # Note: Invoke-WebRequest -Proxy does NOT support SOCKS5 in PS5.1.
    # We use a simple TCP connect + TLS handshake through the SOCKS proxy
    # to verify the route works. A full HTTP request through SOCKS5 requires
    # .NET 6+ (SocketsHttpHandler) which PS5.1 doesn't have. Instead we just
    # verify the SOCKS5 handshake succeeds and the remote host is reachable.
    if ($warpPing) {
        try {
            # SOCKS5 handshake to chatgpt.com:443 through 127.0.0.1:40000
            $tcp = New-Object System.Net.Sockets.TcpClient
            $task = $tcp.ConnectAsync('127.0.0.1', 40000)
            if (-not ($task.Wait(3000) -and $tcp.Connected)) {
                throw 'TCP connect to WARP proxy timed out'
            }
            $stream = $tcp.GetStream()
            $stream.ReadTimeout  = 5000
            $stream.WriteTimeout = 5000
            # SOCKS5 greeting: version=5, 1 auth method, no-auth=0
            $greeting = [byte[]]@(0x05, 0x01, 0x00)
            $stream.Write($greeting, 0, 3)
            $buf = New-Object byte[] 2
            $read = $stream.Read($buf, 0, 2)
            if ($read -lt 2 -or $buf[0] -ne 0x05) { throw 'SOCKS5 greeting failed' }
            # SOCKS5 connect request to chatgpt.com:443 (domain type=3)
            $domain = [Text.Encoding]::ASCII.GetBytes('chatgpt.com')
            $connReq = New-Object System.Collections.Generic.List[byte]
            $connReq.AddRange([byte[]]@(0x05, 0x01, 0x00, 0x03, [byte]$domain.Length))
            $connReq.AddRange($domain)
            $connReq.AddRange([byte[]]@(0x01, 0xBB))  # port 443 big-endian
            $stream.Write($connReq.ToArray(), 0, $connReq.Count)
            $resp = New-Object byte[] 10
            $read = $stream.Read($resp, 0, $resp.Length)
            if ($read -ge 2 -and $resp[1] -eq 0x00) {
                $r.Geo = @{ Ok=$true; Detail='SOCKS5 connect to chatgpt.com:443 via WARP succeeded' }
            } else {
                $r.Geo = @{ Ok=$false; Detail="SOCKS5 connect reply: status=$($resp[1]) (expected 0x00=success)" }
            }
            $tcp.Close()
        } catch {
            $r.Geo = @{ Ok=$false; Detail="chatgpt.com via WARP SOCKS5 failed: $($_.Exception.Message)" }
        }
    } else {
        $r.Geo = @{ Ok=$false; Detail='skipped (WARP proxy not up)' }
    }

    return $r
}

# ============================================================================
# Misc tools
# ============================================================================
function Update-Lists {
    Write-LauncherLog 'Pulling latest lists from upstream (flowseal/zapret-discord-youtube main)...' 'Yellow'
    $base = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists'
    $files = @('list-general.txt', 'list-google.txt', 'list-exclude.txt', 'ipset-exclude.txt', 'ipset-all.txt')
    foreach ($f in $files) {
        $dst = Join-Path $ListsDir $f
        try {
            Invoke-WebRequest -Uri "$base/$f" -OutFile $dst -UseBasicParsing -TimeoutSec 30
            Write-LauncherLog "  + $f" 'White'
        } catch {
            Write-LauncherLog "  ! $f ($_)" 'Red'
        }
    }
    Write-LauncherLog 'Done.' 'Green'
}

function Open-CustomDomains {
    $custom = Join-Path $ListsDir 'list-custom.txt'
    if (-not (Test-Path -LiteralPath $custom)) {
        Write-Utf8NoBom $custom @(
            '# Custom DPI domains — added to lists/list-general-user.txt on every Apply.',
            '# One domain per line. Lines starting with # are ignored.'
        )
    }
    Start-Process notepad.exe $custom
}

function Open-CustomGeoDomains {
    $f = Join-Path $ListsDir 'geo-custom.txt'
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Utf8NoBom $f @(
            '# Custom geo-blocked domains — routed via Cloudflare WARP (when WARP is running).',
            '# One domain per line. Lines starting with # are ignored.'
        )
    }
    Start-Process notepad.exe $f
}

function Run-Diagnostics {
    $svc = Join-Path $RepoRoot 'service.bat'
    # Launch in a separate window so it doesn't block the GUI/CLI thread.
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "call `"$svc`" admin") -WindowStyle Normal
}
