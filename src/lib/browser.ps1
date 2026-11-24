# ============================================================================
#  Zapret Ultimate - real browser playback probe (Chrome DevTools Protocol)
#  Requires PowerShell 5.1 / .NET 4.5+ (ClientWebSocket). No Node.js needed.
# ============================================================================

function Get-ZBrowserCandidates {
    $list = @()
    $list += (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe')
    if (${env:ProgramFiles(x86)}) { $list += (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application\brave.exe') }
    $list += (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
    $list += (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    if (${env:ProgramFiles(x86)}) { $list += (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe') }
    if (${env:ProgramFiles(x86)}) { $list += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    $list += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    # Yandex Browser is Chromium-based and speaks CDP; it is used for the
    # playback test if nothing else is installed.
    $list += (Join-Path $env:LOCALAPPDATA 'Yandex\YandexBrowser\Application\browser.exe')
    $list += (Join-Path $env:ProgramFiles 'Yandex\YandexBrowser\Application\browser.exe')
    if (${env:ProgramFiles(x86)}) { $list += (Join-Path ${env:ProgramFiles(x86)} 'Yandex\YandexBrowser\Application\browser.exe') }
    return @($list | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Get-ZFreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    $port = $l.LocalEndpoint.Port
    $l.Stop()
    return $port
}

function Send-ZCdp {
    param($Socket, $Id, [string]$Method, $Params = @{})
    $msg = @{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 8
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
    $Socket.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Receive-ZCdp {
    param($Socket, [int]$TimeoutMs = 10000)
    $buf = New-Object byte[] 131072
    $sb = New-Object Text.StringBuilder
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buf)
        $task = $Socket.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        if (-not $task.Wait($TimeoutMs)) { return $null }
        $res = $task.Result
        if ($res.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
        if ($res.EndOfMessage) { break }
    }
    $text = $sb.ToString()
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

# Waits for a response with the given id, skipping events.
function Wait-ZCdpResponse {
    param($Socket, [int]$Id, [int]$TimeoutMs = 15000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $msg = Receive-ZCdp -Socket $Socket -TimeoutMs 5000
        if ($null -eq $msg) { return $null }
        if ($msg.id -eq $Id) { return $msg }
    }
    return $null
}

function Invoke-ZCdpEval {
    param($Socket, [int]$Id, [string]$Expression)
    Send-ZCdp -Socket $Socket -Id $Id -Method 'Runtime.evaluate' -Params @{ expression = $Expression; returnByValue = $true }
    $resp = Wait-ZCdpResponse -Socket $Socket -Id $Id -TimeoutMs 15000
    if ($resp -and $resp.result -and $resp.result.result) { return $resp.result.result.value }
    return $null
}

# Launches a browser with remote debugging. When the caller is elevated the
# browser is started through Explorer/wscript so it runs as the logged-on user
# (elevated Chromium builds refuse to render properly).
function Start-ZBrowserForCdp {
    param([string]$Browser, [string]$ProfileDir, [int]$Port, [string]$Url)
    $argLine = '--headless=new --disable-gpu --no-first-run --no-default-browser-check --mute-audio ' +
    '--autoplay-policy=no-user-gesture-required --remote-debugging-port=' + $Port +
    ' --user-data-dir="' + $ProfileDir + '" "' + $Url + '"'

    $isAdmin = $false
    try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }

    if (-not $isAdmin) {
        Start-Process -FilePath $Browser -ArgumentList $argLine -WindowStyle Hidden | Out-Null
        return
    }
    $dir = Split-Path -Parent $ProfileDir
    $cmdFile = Join-Path $dir 'start-browser.cmd'
    $vbsFile = Join-Path $dir 'start-browser.vbs'
    $cmdText = '@echo off' + "`r`n" + '"' + $Browser + '" ' + $argLine
    [IO.File]::WriteAllText($cmdFile, $cmdText, (New-Object Text.UTF8Encoding($false)))
    $vbsText = 'Set sh = CreateObject("WScript.Shell")' + "`r`n" + 'sh.Run "cmd /c ""' + $cmdFile + '""", 0, False'
    [IO.File]::WriteAllText($vbsFile, $vbsText, (New-Object Text.UTF8Encoding($false)))
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $vbsFile + '"') | Out-Null
}

function Test-ZBrowserPlayback {
    param(
        [string]$Url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        [int]$WaitSec = 18,
        [int]$TimeoutSec = 75,
        [string]$BrowserPath = ''
    )
    $result = [ordered]@{
        ok = $false; available = $false; browser = ''; reason = ''
        currentTime = 0; readyState = 0; error = 0; bufferedEnd = 0
        hosts = @(); protocols = @(); ggcHost = ''; ggcMbps = 0; sampleUrl = ''
    }
    $browser = $BrowserPath
    if (-not $browser) {
        $cands = Get-ZBrowserCandidates
        if ($cands.Count -gt 0) { $browser = $cands[0] }
    }
    if (-not $browser) { $result.reason = 'браузер не найден'; return [pscustomobject]$result }
    $result.browser = Split-Path $browser -Leaf
    $result.available = $true

    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path $env:TEMP ('zapret-play-' + $id)
    $prof = Join-Path $dir 'profile'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $port = Get-ZFreePort
    $ws = $null
    $procIds = @()
    try {
        Start-ZBrowserForCdp -Browser $browser -ProfileDir $prof -Port $port -Url $Url
        # Wait for the debugging endpoint.
        $targets = $null
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            try {
                $targets = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/list" -f $port) -TimeoutSec 3
                if ($targets) { break }
            } catch { }
            Start-Sleep -Milliseconds 500
        }
        if (-not $targets) { $result.reason = 'DevTools не ответил'; return [pscustomobject]$result }

        $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.url -like '*youtube*' }) | Select-Object -First 1
        if (-not $page) { $page = @($targets | Where-Object { $_.type -eq 'page' }) | Select-Object -First 1 }
        if (-not $page) { $result.reason = 'нет вкладки'; return [pscustomobject]$result }

        $ws = New-Object Net.WebSockets.ClientWebSocket
        $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(5)
        $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

        Send-ZCdp -Socket $ws -Id 1 -Method 'Runtime.enable'
        [void](Wait-ZCdpResponse -Socket $ws -Id 1)

        Start-Sleep -Seconds 3
        [void](Invoke-ZCdpEval -Socket $ws -Id 2 -Expression "(()=>{const v=document.querySelector('video'); if(v){v.muted=true; try{v.play()}catch(e){}} return !!v})()")

        # Poll instead of sleeping the full window: healthy playback is detected
        # in ~6-9 s, while a real stall still gets the whole WaitSec.
        for ($elapsed = 0; $elapsed -lt $WaitSec; $elapsed += 3) {
            Start-Sleep -Seconds 3
            $quick = Invoke-ZCdpEval -Socket $ws -Id 10 -Expression "(()=>{const v=document.querySelector('video'); return v?JSON.stringify({t:v.currentTime||0,e:v.error?v.error.code:0}):''})()"
            if ($quick) {
                try {
                    $q = $quick | ConvertFrom-Json
                    if ([double]$q.t -ge 5 -and [int]$q.e -eq 0) { break }
                } catch { }
            }
        }

        $expr = @'
(() => {
  const v = document.querySelector('video');
  const rs = performance.getEntriesByType('resource').filter(r => r.name.includes('googlevideo'));
  const hosts = [...new Set(rs.map(r => { try { return new URL(r.name).host } catch(e) { return '' } }).filter(Boolean))];
  const protocols = [...new Set(rs.map(r => r.nextHopProtocol).filter(Boolean))];
  const sampleUrl = rs.length ? rs[0].name : '';
  let mbps = 0;
  if (rs.length) {
    const b = rs.reduce((a, c) => ((c.transferSize || 0) > (a.transferSize || 0) ? c : a), rs[0]);
    if (b && b.transferSize && b.duration) {
      mbps = Math.round((b.transferSize * 8 / 1e6) / (b.duration / 1000) * 100) / 100;
    }
  }
  let cur = 0, ready = 0, err = 0, bufEnd = 0;
  if (v) {
    cur = v.currentTime || 0; ready = v.readyState || 0; err = v.error ? v.error.code : 0;
    if (v.buffered && v.buffered.length) bufEnd = v.buffered.end(v.buffered.length - 1);
  }
  return JSON.stringify({ currentTime: cur, readyState: ready, error: err, bufferedEnd: bufEnd, hosts, protocols, sampleUrl, mbps, title: document.title });
})()
'@
        $json = Invoke-ZCdpEval -Socket $ws -Id 3 -Expression $expr
        if ($json) {
            $state = $json | ConvertFrom-Json
            $result.currentTime = [double]$state.currentTime
            $result.readyState = [int]$state.readyState
            $result.error = [int]$state.error
            $result.bufferedEnd = [double]$state.bufferedEnd
            $result.hosts = @($state.hosts)
            $result.protocols = @($state.protocols)
            $result.sampleUrl = [string]$state.sampleUrl
            if ($null -ne $state.mbps) { $result.ggcMbps = [double]$state.mbps }
            if ($result.hosts.Count -gt 0) { $result.ggcHost = $result.hosts[0] }
        }

        $result.ok = ($result.error -eq 0 -and $result.currentTime -ge 5)
        if (-not $result.ok) {
            $result.reason = ('видео не играет (currentTime={0:N1}s, readyState={1}, error={2})' -f $result.currentTime, $result.readyState, $result.error)
        } else {
            $result.reason = 'ok'
        }
    } catch {
        $result.reason = $_.Exception.Message
    } finally {
        if ($ws) { try { $ws.Dispose() } catch { } }
        try {
            Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='brave.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($prof) } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { }
        Start-Sleep -Milliseconds 300
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]$result
}
