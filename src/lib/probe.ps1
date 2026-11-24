# ============================================================================
#  Zapret Ultimate - probe engine
#  Real TLS 1.2 / TLS 1.3 handshakes with SNI + optional HTTP request.
#  Certificate validation is intentionally ignored: we measure DPI behaviour,
#  not PKI.
# ============================================================================
$ZRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-ZTargets {
    param([string[]]$Categories = $null, [switch]$WithoutControl)
    $file = Join-Path $ZConf 'targets.json'
    $parsed = $null
    try {
        # ConvertFrom-Json returns the whole array as one object in Windows
        # PowerShell; unwrap it explicitly so callers always get a flat list.
        $parsed = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-ZLog ('Не удалось прочитать targets.json: ' + $_.Exception.Message + ' — использую встроенный список.') WARN
        $parsed = @(
            [pscustomobject]@{ key = 'DiscordMain'; host = 'discord.com'; cat = 'discord'; weight = 3; http = $false },
            [pscustomobject]@{ key = 'YouTubeWeb'; host = 'www.youtube.com'; cat = 'youtube'; weight = 3; http = $false },
            [pscustomobject]@{ key = 'YouTubeRedirect'; host = 'redirector.googlevideo.com'; cat = 'youtube'; weight = 3; http = $false },
            [pscustomobject]@{ key = 'GoogleMain'; host = 'www.google.com'; cat = 'google'; weight = 2; http = $false },
            [pscustomobject]@{ key = 'ControlYa'; host = 'ya.ru'; cat = 'control'; weight = 2; http = $false }
        )
    }
    $all = @($parsed | ForEach-Object { $_ })
    if ($Categories) { $all = @($all | Where-Object { $Categories -contains $_.cat }) }
    if ($WithoutControl) { $all = @($all | Where-Object { $_.cat -ne 'control' }) }
    return $all
}

# A scriptblock cannot be used as a certificate callback: the handshake runs on
# a worker thread with no runspace. A tiny compiled delegate avoids that.
if (-not ('ZapretTls' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net.Security;
public static class ZapretTls {
    public static RemoteCertificateValidationCallback AcceptAll =
        new RemoteCertificateValidationCallback(delegate { return true; });
}
'@ -ErrorAction Stop
}

function Test-ZTlsHttp {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Proto,
        [int]$TimeoutMs = 5000,
        [switch]$Http
    )
    $res = [ordered]@{
        host = $HostName; proto = $Proto; ok = $false; http = 0; ms = 0; err = ''; negotiated = ''
        handshake = $false; via = ''
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object Net.Sockets.TcpClient
    $ssl = $null
    try {
        $client.NoDelay = $true
        $iar = $client.BeginConnect($HostName, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw 'tcp-timeout' }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs

        $protos = if ($Proto -eq 'TLS1.3') {
            [System.Security.Authentication.SslProtocols]::Tls13
        } else {
            [System.Security.Authentication.SslProtocols]::Tls12
        }
        $cb = [Net.Security.RemoteCertificateValidationCallback][ZapretTls]::AcceptAll
        $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false, $cb)
        $ssl.ReadTimeout = $TimeoutMs
        $ssl.WriteTimeout = $TimeoutMs

        $ar = $ssl.BeginAuthenticateAsClient($HostName, $null, $protos, $false, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw 'tls-timeout' }
        $ssl.EndAuthenticateAsClient($ar)
        $res.ok = $ssl.IsAuthenticated
        $res.negotiated = $ssl.SslProtocol.ToString()
        $res.handshake = [bool]$res.ok
        $res.via = 'tls'

        if ($res.ok -and $Http) {
            $req = "GET / HTTP/1.1`r`nHost: $HostName`r`nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) ZapretProbe/1.0`r`nAccept: */*`r`nConnection: close`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($req)
            $ssl.Write($bytes, 0, $bytes.Length)
            $ssl.Flush()
            $buf = New-Object byte[] 256
            $n = $ssl.Read($buf, 0, $buf.Length)
            if ($n -gt 0) {
                $line = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
                if ($line -match '^HTTP/\d\.\d\s+(\d{3})') { $res.http = [int]$Matches[1] }
            }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $msg + ' | ' + $_.Exception.InnerException.Message }
        $res.err = $msg
        # SslStream sends a different ClientHello than a real browser/Schannel.
        # Some desync modes interact badly with it while real clients work, so
        # fall back to curl (Schannel) before declaring the target blocked.
        try {
            $sec = [math]::Max(1, [math]::Ceiling($TimeoutMs / 1000))
            $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time $sec "https://$HostName/" 2>$null) -join ''
            if ($code -match '^\d{3}$' -and [int]$code -ge 200 -and [int]$code -lt 500) {
                $res.ok = $true
                $res.http = [int]$code
                $res.negotiated = 'curl'
                $res.handshake = $false
                $res.via = 'curl'
                $res.err = ''
            }
        } catch { }
    } finally {
        $res.ms = [int]$sw.ElapsedMilliseconds
        if ($ssl) { try { $ssl.Dispose() } catch { } }
        try { $client.Close() } catch { }
    }
    return [pscustomobject]$res
}

# Global connectivity check. When the whole uplink is down every GGC node looks
# dead, and blocking all of them would break YouTube for good, so the GGC check
# refuses to act without this.
function Test-ZInternetAccess {
    param([int]$TimeoutSec = 5)
    foreach ($u in @('https://www.google.com/generate_204', 'https://ya.ru/')) {
        try {
            $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time $TimeoutSec $u 2>$null) -join ''
            if ($code -match '^\d{3}$') { return $true }
        } catch { }
    }
    return (Test-ZPortTcp -HostName '1.1.1.1' -Port 443 -TimeoutMs 3000)
}

# Runs the full matrix. TLS1.2 for every target, TLS1.3 for every target,
# HTTP only on targets that ask for it (and only once, on the TLS1.3 pass).
function Invoke-ZProbe {
    param(
        [object[]]$Targets = $null,
        [int]$TimeoutMs = 5000,
        [switch]$Quiet,
        [switch]$NoRetry
    )
    if (-not $Targets) { $Targets = Get-ZTargets }
    $results = New-Object System.Collections.ArrayList
    foreach ($t in $Targets) {
        foreach ($proto in @('TLS1.2', 'TLS1.3')) {
            $doHttp = ($t.http -and $proto -eq 'TLS1.3')
            $r = Test-ZTlsHttp -HostName $t.host -Proto $proto -TimeoutMs $TimeoutMs -Http:$doHttp
            if (-not $r.ok -and -not $NoRetry) {
                # One retry: TSPU/Cloudflare answers are not perfectly stable and
                # a single timeout should not mark a working profile as broken.
                Start-Sleep -Milliseconds 250
                $r2 = Test-ZTlsHttp -HostName $t.host -Proto $proto -TimeoutMs $TimeoutMs -Http:$doHttp
                if ($r2.ok) { $r = $r2 }
            }
            $r | Add-Member -NotePropertyName key -NotePropertyValue $t.key -Force
            $r | Add-Member -NotePropertyName cat -NotePropertyValue $t.cat -Force
            $r | Add-Member -NotePropertyName weight -NotePropertyValue ([int]$t.weight) -Force
            [void]$results.Add($r)
            if (-not $Quiet) {
                $st = if ($r.ok) { 'OK  ' } else { 'FAIL' }
                Write-Host ('  {0,-22} {1,-7} {2} {3,5} ms  {4}' -f $r.key, $proto, $st, $r.ms, $r.err) -ForegroundColor $(if ($r.ok) { 'Green' } else { 'DarkYellow' })
            }
        }
    }
    return $results
}

function Get-ZProbeScore {
    param([object[]]$Results)
    $byKey = @{}
    foreach ($r in $Results) {
        if (-not $byKey.ContainsKey($r.key)) {
            $byKey[$r.key] = [ordered]@{ key = $r.key; cat = $r.cat; weight = $r.weight; t12 = $false; t13 = $false; h12 = $false; h13 = $false; via = ''; http = 0; ms = 0; host = $r.host }
        }
        $e = $byKey[$r.key]
        if ($r.proto -eq 'TLS1.2' -and $r.ok) { $e.t12 = $true }
        if ($r.proto -eq 'TLS1.3' -and $r.ok) { $e.t13 = $true }
        if ($r.proto -eq 'TLS1.2' -and $r.handshake -eq $true) { $e.h12 = $true }
        if ($r.proto -eq 'TLS1.3' -and $r.handshake -eq $true) { $e.h13 = $true }
        if ($r.via) { $e.via = [string]$r.via }
        if ($r.http -gt 0) { $e.http = $r.http }
        if ($r.ms -gt 0) { $e.ms = [math]::Max($e.ms, $r.ms) }
    }

    $total = 0.0; $got = 0.0
    $cats = @{}
    $controlsOk = $true
    $controlSeen = 0
    foreach ($e in $byKey.Values) {
        $succ = ($e.t12 -or $e.t13)
        if ($e.cat -eq 'control') {
            $controlSeen++
            if (-not $succ) { $controlsOk = $false }
            continue
        }
        $w = [double]$e.weight
        $total += $w
        if ($succ) { $got += $w }
        if (-not $cats.ContainsKey($e.cat)) { $cats[$e.cat] = [ordered]@{ total = 0.0; got = 0.0 } }
        $cats[$e.cat].total += $w
        if ($succ) { $cats[$e.cat].got += $w }
    }
    $score = if ($total -gt 0) { [math]::Round(100.0 * $got / $total, 1) } else { 0 }
    $catScores = [ordered]@{}
    foreach ($k in $cats.Keys) {
        $c = $cats[$k]
        $catScores[$k] = if ($c.total -gt 0) { [math]::Round(100.0 * $c.got / $c.total, 1) } else { 0 }
    }
    # Without control results we cannot claim the profile is safe to install.
    if ($controlSeen -eq 0) { $controlsOk = $false }
    return [pscustomobject]@{
        score      = $score
        controlsOk = $controlsOk
        categories = $catScores
        details    = @($byKey.Values | ForEach-Object { [pscustomobject]$_ })
    }
}

function Format-ZProbeSummary {
    param([object]$Scored)
    $parts = @()
    foreach ($k in $Scored.categories.Keys) { $parts += ('{0}={1}%' -f $k, $Scored.categories[$k]) }
    return ('score={0}% [{1}] controls={2}' -f $Scored.score, ($parts -join ' '), $(if ($Scored.controlsOk) { 'OK' } else { 'BROKEN' }))
}

# Detects the November-2026 style "volume freeze": the TCP connection opens,
# passes a little data (often ~8-32 KB) and then stalls forever without RST.
# This is a behavioural TSPU block; packet-level desync cannot fix it, so it is
# important to tell the user honestly which problem they have.
function Get-ZYouTubeDirectUrl {
    param([string]$VideoId = 'dQw4w9WgXcQ')
    $ytdlp = Join-Path $ZTools 'yt-dlp.exe'
    if (-not (Test-Path -LiteralPath $ytdlp)) { return $null }
    try {
        $url = & $ytdlp --no-warnings --no-playlist -f 'bv*[height<=720]/b[height<=720]' -g "https://www.youtube.com/watch?v=$VideoId" 2>$null |
            Where-Object { $_ -like 'http*' } | Select-Object -First 1
        return $url
    } catch { return $null }
}

function Test-ZFreeze {
    param(
        [string]$Url = 'https://speed.cloudflare.com/__down?bytes=8000000',
        [int]$BudgetMs = 15000,
        [int]$StallMs = 7000
    )
    $res = [ordered]@{ ok = $false; bytes = 0; stalled = $false; seconds = 0; err = ''; host = '' }
    try {
        $uri = [Uri]$Url
        $HostName = $uri.Host
        $Path = $uri.PathAndQuery
    } catch {
        $res.err = 'некорректный URL теста'
        return [pscustomobject]$res
    }
    $res.host = $HostName
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object Net.Sockets.TcpClient
    $ssl = $null
    try {
        $iar = $client.BeginConnect($HostName, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(5000)) { throw 'tcp-timeout' }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = 5000
        $cb = [Net.Security.RemoteCertificateValidationCallback][ZapretTls]::AcceptAll
        $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false, $cb)
        $ssl.AuthenticateAsClient($HostName)
        $req = "GET $Path HTTP/1.1`r`nHost: $HostName`r`nUser-Agent: Mozilla/5.0`r`nAccept: */*`r`nRange: bytes=0-4000000`r`nConnection: close`r`n`r`n"
        $b = [Text.Encoding]::ASCII.GetBytes($req)
        $ssl.Write($b, 0, $b.Length); $ssl.Flush()

        $buf = New-Object byte[] 32768
        $lastData = $sw.ElapsedMilliseconds
        $res.ok = $true
        while ($sw.ElapsedMilliseconds -lt $BudgetMs) {
            $ssl.ReadTimeout = 1000
            $n = 0
            try { $n = $ssl.Read($buf, 0, $buf.Length) }
            catch {
                # SslStream wraps read timeouts differently than NetworkStream,
                # so catch everything and decide by the idle time.
                $msg = $_.Exception.Message
                if ($_.Exception.InnerException) { $msg += ' ' + $_.Exception.InnerException.Message }
                if ($msg -match 'reset|forcibly closed|принудительно|оборвано') {
                    $res.err = 'соединение сброшено: ' + $msg
                    $res.ok = $false
                    break
                }
                if (($sw.ElapsedMilliseconds - $lastData) -ge $StallMs) { $res.stalled = $true; break }
                continue
            }
            if ($n -le 0) { break }
            $res.bytes += $n
            $lastData = $sw.ElapsedMilliseconds
            if ($res.bytes -ge 4000000) { break }
        }
        if (-not $res.stalled -and $res.ok -and ($sw.ElapsedMilliseconds - $lastData) -ge $StallMs -and $res.bytes -lt 4000000) {
            $res.stalled = $true
        }
        # A tiny response means the measurement itself failed (redirect, error
        # page, blocked CDN). Do not report "no freeze" in that case.
        if (-not $res.stalled -and $res.ok -and $res.bytes -lt 50000) {
            $res.ok = $false
            $res.err = ('получено всего {0} байт — тест недостоверен' -f $res.bytes)
        }
    } catch {
        $res.err = $_.Exception.Message
    } finally {
        $res.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        if ($ssl) { try { $ssl.Dispose() } catch { } }
        try { $client.Close() } catch { }
    }
    return [pscustomobject]$res
}

# Some desync modes pass a TLS handshake but corrupt larger TCP flows: the
# connection freezes after ~16-22 KB. Discord desktop loads its UI from
# discord.com (Cloudflare) and stays hidden forever if that download stalls, so
# every candidate profile must prove it can pull a multi-megabyte response.
function Test-ZBulkHttp {
    param([int]$TimeoutSec = 25)
    $res = [ordered]@{
        ok = $false; cloudflareBytes = 0; discordBytes = 0
        cloudflareMs = 0; discordMs = 0; err = ''
    }
    try {
        $cf = (& curl.exe -s -o NUL -w '%{http_code};%{size_download};%{time_total}' --max-time $TimeoutSec 'https://speed.cloudflare.com/__down?bytes=2000000') -join ''
        $dc = (& curl.exe -s -o NUL -w '%{http_code};%{size_download};%{time_total}' --max-time $TimeoutSec 'https://discord.com/app') -join ''
        $cfp = $cf -split ';'
        $dcp = $dc -split ';'
        if ($cfp.Count -ge 3) { $res.cloudflareBytes = [int64]$cfp[1]; $res.cloudflareMs = [int]([double]$cfp[2] * 1000) }
        if ($dcp.Count -ge 3) { $res.discordBytes = [int64]$dcp[1]; $res.discordMs = [int]([double]$dcp[2] * 1000) }
        $res.ok = ($cfp[0] -eq '200' -and $res.cloudflareBytes -ge 1500000 -and
                   $dcp[0] -eq '200' -and $res.discordBytes -ge 50000)
        if (-not $res.ok) {
            $res.err = ('cloudflare={0} байт, discord={1} байт' -f $res.cloudflareBytes, $res.discordBytes)
        }
    } catch {
        $res.err = $_.Exception.Message
    }
    return [pscustomobject]$res
}

function Test-ZYouTubeSpeed {
    param([string]$VideoId = 'dQw4w9WgXcQ', [int]$MaxBytes = 3000000)
    $ytdlp = Join-Path $ZTools 'yt-dlp.exe'
    if (-not (Test-Path -LiteralPath $ytdlp)) { return $null }
    try {
        $url = & $ytdlp --no-warnings --no-playlist -f 'bv*[height<=720]/b[height<=720]' -g "https://www.youtube.com/watch?v=$VideoId" 2>$null | Select-Object -First 1
        if (-not $url) { return $null }
        $tmp = Join-Path $env:TEMP ('zapret_speed_{0}.bin' -f ([guid]::NewGuid().ToString('N')))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & curl.exe -s -L --max-time 20 -r ("0-{0}" -f $MaxBytes) -o $tmp $url 2>$null
        $el = [math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        $len = 0
        if (Test-Path -LiteralPath $tmp) { $len = (Get-Item -LiteralPath $tmp).Length; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return [pscustomobject]@{ ok = ($len -gt 100000); bytes = $len; ms = [int]$sw.ElapsedMilliseconds; mbps = [math]::Round(($len * 8 / 1e6) / $el, 2) }
    } catch {
        return [pscustomobject]@{ ok = $false; bytes = 0; ms = 0; mbps = 0; err = $_.Exception.Message }
    }
}
