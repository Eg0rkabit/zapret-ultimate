# ============================================================================
#  Zapret Ultimate - CLI entry point
#  Usage: Zapret.ps1 [status|start|stop|restart|tune|quick|apply|list|test|
#                     diagnose|fix-hosts|quic-off|quic-on|ggc-check|ggc-reset|playback|check-video|update|
#                     fix-acl|disable-legacy|restore|uninstall|menu]
# ============================================================================
param(
    [Parameter(Position = 0)][string]$Command = 'menu',
    [Parameter(Position = 1)][string]$ProfileId = '',
    [switch]$Quick,
    [switch]$NoInstall,
    [switch]$Yes
)

$root = $PSScriptRoot
. "$root\lib\common.ps1"
. "$root\lib\engine.ps1"
. "$root\lib\probe.ps1"
. "$root\lib\browser.ps1"

# Chromium-based browsers read QuicAllowed from these machine policy keys.
$script:ZQuicPolicyKeys = @(
    'HKLM:\SOFTWARE\Policies\Google\Chrome',
    'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
    'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave',
    'HKLM:\SOFTWARE\Policies\YandexBrowser'
)

# Fix the raster "Terminal" font problem (no Cyrillic glyphs) before any output.
Initialize-ZConsole

# Self-elevate unless the caller explicitly opted out (or we already are admin).
if (-not (Test-ZAdmin) -and -not $env:ZAPRET_NO_ELEVATE) {
    $argLine = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), $Command)
    if ($ProfileId) { $argLine += @('-ProfileId', $ProfileId) }
    if ($Quick) { $argLine += '-Quick' }
    if ($NoInstall) { $argLine += '-NoInstall' }
    if ($Yes) { $argLine += '-Yes' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    exit 0
}

function Show-ZHeader {
    param([string]$Title)
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ("   ZAPRET ULTIMATE  ::  " + $Title) -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
}

function Get-ZActiveProfile {
    $img = Get-ZServiceImagePath
    if (-not $img) { return $null }
    try {
        $lib = Get-Content -LiteralPath (Join-Path $ZProfilesDir 'library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return $null }
    foreach ($p in @($lib.profiles)) {
        $line = Get-ZInlineArgLine -Arguments $p.args
        if ($line -and $img.Contains($line)) { return $p }
    }
    return $null
}

function Show-ZStatus {
    Show-ZHeader 'СТАТУС'
    $state = Get-ZServiceState
    $color = switch ($state) { 'Running' { 'Green' } 'Stopped' { 'Yellow' } default { 'Red' } }
    Write-Host ("  Служба zapret : {0}" -f $state) -ForegroundColor $color

    $active = Get-ZActiveProfile
    $info = Get-ZInstalledInfo
    if ($active) {
        Write-Host ("  Профиль       : {0} ({1})" -f $active.name, $active.id)
    } elseif ($info) {
        Write-Host ("  Профиль       : {0} ({1}) — по данным установки" -f $info.profileName, $info.profileId)
    } else {
        Write-Host '  Профиль       : не установлен через Zapret Ultimate'
    }
    if ($active -and $info -and $info.profileId -and $active.id -ne $info.profileId) {
        Write-Host ("  ВНИМАНИЕ      : служба запущена с профилем {0}, а установщик помнит {1}." -f $active.id, $info.profileId) -ForegroundColor Yellow
    }

    $img = Get-ZServiceImagePath
    if ($img) {
        $exe = $img
        if ($img -match '^"([^"]+)"') { $exe = $Matches[1] }
        elseif ($img -match '^(\S+\.exe)') { $exe = $Matches[1] }
        $argCount = ([regex]::Matches($img, '--')).Count
        Write-Host ("  Исполняемый   : {0}" -f $exe) -ForegroundColor DarkGray
        Write-Host ("  Аргументов    : {0}" -f $argCount) -ForegroundColor DarkGray
        if ($exe -notlike "$ZRoot*") {
            Write-Host '  ВНИМАНИЕ: служба запущена не из C:\Zapret (старая установка).' -ForegroundColor Yellow
        }
    }

    $w = Get-Service -Name 'WinDivert' -ErrorAction SilentlyContinue
    Write-Host ("  Драйвер       : {0}" -f $(if ($w) { $w.Status } else { 'не загружен' }))

    $allWinws = @(Get-ZWinwsProcesses)
    $ownWinws = @(Get-ZOwnWinwsProcesses)
    $procText = if ($ownWinws.Count -gt 0) { [string]$ownWinws.Count }
    elseif ($allWinws.Count -gt 0) { ('{0} (путь неизвестен)' -f $allWinws.Count) }
    else { '0' }
    Write-Host ("  Процессы winws: {0}" -f $procText)

    $svc = Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue
    if ($svc) { Write-Host ("  Автозапуск    : {0}" -f $svc.StartType) }

    try {
        if (-not (Test-ZRootAcl)) {
            Write-Host '  Права папки   : ОПАСНО — запись у обычных пользователей; исправить: Zapret.bat fix-acl' -ForegroundColor Red
        }
    } catch { }

    Write-Host ''
    if (Test-ZLock -Name 'operation') { Write-Host '  ВНИМАНИЕ: идёт тюнинг/установка — проверка может быть неточной.' -ForegroundColor Yellow }
    Write-Host '  Быстрая проверка доступности...' -ForegroundColor DarkGray
    $targets = @(Get-ZTargets | Where-Object { $_.key -in @('DiscordMain', 'YouTubeWeb', 'YouTubeRedirect', 'ControlYa') })
    $res = Invoke-ZProbe -Targets $targets -TimeoutMs 4000 -Quiet -NoRetry
    $sc = Get-ZProbeScore -Results $res
    Write-Host ('  ' + (Format-ZProbeSummary -Scored $sc)) -ForegroundColor $(if ($sc.score -ge 90 -and $sc.controlsOk) { 'Green' } else { 'Yellow' })
    foreach ($d in $sc.details) {
        $mark = if ($d.t13 -or $d.t12) { 'OK  ' } else { 'FAIL' }
        $col = if ($d.t13 -or $d.t12) { 'Green' } else { 'Red' }
        $tls = 'TLS1.2={0} TLS1.3={1}' -f $d.h12, $d.h13
        if ($d.via -eq 'curl') { $tls += ' (curl fallback)' }
        Write-Host ('    {0,-22} {1}' -f $d.key, $mark) -ForegroundColor $col -NoNewline
        Write-Host ('  ' + $tls) -ForegroundColor DarkGray
    }
}

function Show-ZProfileList {
    Show-ZHeader 'ПРОФИЛИ'
    $lib = Get-Content -LiteralPath (Join-Path $ZProfilesDir 'library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $info = Get-ZInstalledInfo
    $active = Get-ZActiveProfile
    $activeId = if ($active) { $active.id } elseif ($info) { $info.profileId } else { '' }
    $scores = @{}
    $rp = Join-Path $ZState 'tune-results.json'
    if (Test-Path -LiteralPath $rp) {
        $tr = Get-Content -LiteralPath $rp -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($tr.results)) { if ($r.id -and $r.score -ge 0) { $scores[$r.id] = $r.score } }
    }
    foreach ($p in @($lib.profiles)) {
        $mark = if ($activeId -and $activeId -eq $p.id) { '*' } else { ' ' }
        $sc = if ($scores.ContainsKey($p.id)) { ('{0}%' -f $scores[$p.id]) } else { '  -  ' }
        Write-Host ('  {0} {1,-20} {2,6}  {3}' -f $mark, $p.id, $sc, $p.name)
    }
    Write-Host ''
    Write-Host '  * — активный профиль. Применить: Zapret.bat apply <id>' -ForegroundColor DarkGray
    if ($scores.Count -eq 0) {
        Write-Host '  Оценок нет: полный автотюнинг ещё не сохранял state\tune-results.json (Zapret.bat tune).' -ForegroundColor DarkGray
    }
}

function Show-ZTest {
    Show-ZHeader 'ТЕСТ ДОСТУПНОСТИ'
    $targets = Get-ZTargets
    $res = Invoke-ZProbe -Targets $targets -TimeoutMs 5000
    $sc = Get-ZProbeScore -Results $res
    Write-Host ''
    Write-Host ('  ИТОГО: ' + (Format-ZProbeSummary -Scored $sc)) -ForegroundColor $(if ($sc.score -ge 90 -and $sc.controlsOk) { 'Green' } else { 'Yellow' })
    Write-Host ''
    Write-Host '  Скорость YouTube...' -ForegroundColor DarkGray
    $yt = Test-ZYouTubeSpeed
    if ($yt) {
        $col = if ($yt.mbps -ge 5) { 'Green' } elseif ($yt.mbps -gt 0) { 'Yellow' } else { 'Red' }
        Write-Host ('  YouTube: {0} Mbps ({1} байт за {2} мс)' -f $yt.mbps, $yt.bytes, $yt.ms) -ForegroundColor $col
    } else {
        Write-Host '  YouTube: измерить не удалось (нет tools\yt-dlp.exe — это Lite-версия, либо видео недоступно).' -ForegroundColor Yellow
    }

    $ytUrl = Get-ZYouTubeDirectUrl
    if ($ytUrl) { $freeze = Test-ZFreeze -Url $ytUrl } else { $freeze = Test-ZFreeze }
    if ($freeze) {
        if (-not $freeze.ok) {
            Write-Host ('  Тест заморозки не удался: {0}' -f $freeze.err) -ForegroundColor Yellow
        } elseif ($freeze.stalled) {
            Write-Host ('  ВНИМАНИЕ: похоже на "заморозку по объёму" — соединение встало после {0} КБ.' -f [int]($freeze.bytes / 1024)) -ForegroundColor Red
            Write-Host '  Это поведенческая блокировка ТСПУ: zapret её не лечит, нужен UDP-туннель/прокси.' -ForegroundColor Yellow
        } else {
            Write-Host ('  Объёмная заморозка не обнаружена ({0} КБ прошло).' -f [int]($freeze.bytes / 1024)) -ForegroundColor Green
        }
    }

    $rep = [ordered]@{
        time = (Get-Date).ToString('o'); score = $sc.score; categories = $sc.categories
        controlsOk = $sc.controlsOk; details = $sc.details; youtube = $yt; freeze = $freeze
        browser = $null; playback = $null; bulk = $null; profile = (Get-ZInstalledInfo)
        os = ((Get-CimInstance Win32_OperatingSystem).Caption + ' ' + [Environment]::OSVersion.Version.ToString())
        ps = $PSVersionTable.PSVersion.ToString()
        browsers = (@(Get-ZBrowserCandidates) | ForEach-Object { Split-Path $_ -Leaf }) -join ','
        quicOff = (Get-ZQuicPolicyState)
    }

    Write-Host '  Проверка больших загрузок (Cloudflare 2 МБ + Discord)...' -ForegroundColor DarkGray
    $bulk = Test-ZBulkHttp -TimeoutSec 15
    if ($bulk.ok) {
        Write-Host ('  Большие загрузки: OK (Cloudflare {0} КБ, Discord {1} КБ)' -f [int]($bulk.cloudflareBytes / 1024), [int]($bulk.discordBytes / 1024)) -ForegroundColor Green
    } else {
        Write-Host ('  Большие загрузки: ПРОВАЛ — ' + $bulk.err) -ForegroundColor Red
        Write-Host '  Такой профиль рвёт Discord: запустите Zapret.bat tune или примените другой профиль.' -ForegroundColor Yellow
    }
    $rep.bulk = $bulk

    Write-Host '  Проверка реального воспроизведения (Chrome/Edge/Brave/Yandex)...' -ForegroundColor DarkGray
    $play = Test-ZBrowserPlayback
    if ($play -and $play.available) {
        if ($play.ok) {
            Write-Host ('  Видео играет: {0} ({1:N1} c, буфер {2:N0} c, узел {3}, {4}, {5} Мбит/с)' -f `
                    $play.browser, $play.currentTime, $play.bufferedEnd, $play.ggcHost, ($play.protocols -join '/'), $play.ggcMbps) -ForegroundColor Green
        } else {
            Write-Host ('  Видео НЕ играет: {0}' -f $play.reason) -ForegroundColor Red
            if ($play.protocols -contains 'h3') {
                Write-Host '  Похоже на QUIC: выполните Zapret.bat quic-off и перезапустите браузер.' -ForegroundColor Yellow
            }
            if (@($play.hosts).Count -gt 0) {
                Write-Host '  Проверяю узлы, которые выбрал браузер, и блокирую мёртвые...' -ForegroundColor DarkGray
                try {
                    Invoke-ZGgcCheck -Hosts @($play.hosts) -Quiet -SkipRestore
                    $play2 = Test-ZBrowserPlayback
                    if ($play2.ok) {
                        Write-Host ('  После блокировки мёртвого узла видео играет: {0:N1} c, буфер {1:N0} c' -f $play2.currentTime, $play2.bufferedEnd) -ForegroundColor Green
                        $play = $play2
                    } else {
                        Write-Host '  Автоблокировка не помогла — нужен разбор (diagnose/DevTools).' -ForegroundColor Yellow
                    }
                } catch { }
            }
        }
        # Remember the nodes the browser actually used: the periodic GGC check
        # otherwise keeps watching a stale cluster from the seed list.
        if ($play.ok -and @($play.hosts).Count -gt 0) { Add-ZGgcWatchHosts -Hosts @($play.hosts) }
        $rep.playback = $play
    } else {
        Write-Host ('  Проверить воспроизведение не удалось: {0}' -f $(if ($play) { $play.reason } else { 'браузер не найден' })) -ForegroundColor Yellow
    }
    $out = Join-Path $ZLogs ('report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    ($rep | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $out -Encoding UTF8
    Write-Host ('  Отчёт сохранён: ' + $out) -ForegroundColor DarkGray
}

# One video can work while another hangs on a dead GGC node. This checks a few
# different videos, which is how node-specific stalls are found.
function Show-ZPlayback {
    param([int]$Count = 4)
    Show-ZHeader 'ПРОВЕРКА НЕСКОЛЬКИХ ВИДЕО'
    $ids = @('dQw4w9WgXcQ', 'jNQXAC9IVRw', '9bZkp7q19f0', 'kJQP7kiw5Fk')
    $take = [math]::Max(1, [math]::Min($Count, $ids.Count))
    $ids = @($ids | Select-Object -First $take)
    $okCount = 0
    $available = 0
    foreach ($id in $ids) {
        $u = 'https://www.youtube.com/watch?v=' + $id
        $r = Test-ZBrowserPlayback -Url $u -WaitSec 14 -TimeoutSec 60
        if (-not $r -or -not $r.available) {
            Write-Host ('  n/a  {0}  {1}' -f $id, $(if ($r) { $r.reason } else { 'браузер не найден' })) -ForegroundColor Yellow
            continue
        }
        $available++
        if ($r.ok) {
            $okCount++
            Write-Host ('  OK   {0}  {1:N1} c, буфер {2:N0} c, {3}' -f $id, $r.currentTime, $r.bufferedEnd, $r.ggcHost) -ForegroundColor Green
        } else {
            Write-Host ('  FAIL {0}  {1}' -f $id, $r.reason) -ForegroundColor Red
            $videoHosts = @($r.hosts | Where-Object { $_ })
            if ($videoHosts.Count -gt 0) {
                $aliveHosts = @($videoHosts | Where-Object { Test-ZHostReachable -HostName $_ })
                if ($aliveHosts.Count -eq 0) {
                    Write-Host ('       все {0} узла этого ролика недоступны на уровне IP (проверено через DoH) — заблокирован диапазон Google; zapret такое не обходит, нужен VPN/другой транспорт.' -f $videoHosts.Count) -ForegroundColor Yellow
                } else {
                    Write-Host ('       узлы ролика: живых {0}, недоступных {1}. Возможно, поможет Zapret.bat ggc-check.' -f $aliveHosts.Count, ($videoHosts.Count - $aliveHosts.Count)) -ForegroundColor Yellow
                }
            }
        }
    }
    if ($available -eq 0) { Write-Host '  Проверить не удалось: браузер не найден.' -ForegroundColor Yellow; return }
    $col = if ($okCount -eq $available) { 'Green' } elseif ($okCount -gt 0) { 'Yellow' } else { 'Red' }
    Write-Host ('  Итого: играют {0} из {1}.' -f $okCount, $available) -ForegroundColor $col
    if ($okCount -lt $available) {
        Write-Host '  Если узлы ролика недоступны на уровне IP — это ограничение провайдера, а не профиля zapret.' -ForegroundColor Yellow
    }
}

function Get-ZVideoId {
    param([string]$Value)
    if (-not $Value) { return $null }
    if ($Value -match '(?:v=|youtu\.be/|embed/|shorts/)([A-Za-z0-9_-]{11})') { return $Matches[1] }
    if ($Value -match '^[A-Za-z0-9_-]{11}$') { return $Value }
    return $null
}

# Answers the only question that matters for a specific video: are its CDN
# nodes reachable at all? If every node is blackholed, no DPI bypass helps.
function Show-ZVideoCheck {
    param([string]$Url = '')
    Show-ZHeader 'ПРОВЕРКА ВИДЕО'
    if (-not $Url) { $Url = Read-Host '  Ссылка на видео (или id)' }
    $id = Get-ZVideoId -Value $Url
    if (-not $id) { Write-Host '  Не удалось распознать id видео.' -ForegroundColor Red; return }
    $watch = 'https://www.youtube.com/watch?v=' + $id
    Write-Host ('  Видео: ' + $watch) -ForegroundColor DarkGray

    $ytdlp = Join-Path $ZTools 'yt-dlp.exe'
    if (Test-Path -LiteralPath $ytdlp) {
        $out = & $ytdlp --no-warnings --no-playlist -f 'bv*[height<=720]/b[height<=720]' -g $watch 2>&1
        $streams = @($out | Where-Object { $_ -like 'http*' })
        if ($streams.Count -eq 0) {
            Write-Host '  yt-dlp не смог получить поток (антибот/ограничение).' -ForegroundColor Yellow
        } else {
            $videoHosts = @($streams | ForEach-Object { ([Uri]$_).Host } | Select-Object -Unique)
            $alive = 0; $dead = 0
            foreach ($vh in $videoHosts) {
                if (Test-ZHostReachable -HostName $vh) {
                    $alive++
                    Write-Host ('  OK   ' + $vh) -ForegroundColor Green
                } else {
                    $dead++
                    Write-Host ('  DEAD ' + $vh) -ForegroundColor Red
                }
            }
            if ($alive -eq 0) {
                Write-Host '  Все узлы этого видео недоступны: провайдер выбрасывает TLS к их IP. zapret это не обходит — нужен VPN/транспорт.' -ForegroundColor Red
                return
            }
            Write-Host ('  Живых узлов: {0}, мёртвых: {1}.' -f $alive, $dead) -ForegroundColor Yellow
        }
    } else {
        Write-Host '  yt-dlp нет (Lite-версия) — проверяю только браузером.' -ForegroundColor Yellow
    }

    Write-Host '  Проверяю воспроизведение...' -ForegroundColor DarkGray
    $r = Test-ZBrowserPlayback -Url $watch -WaitSec 18 -TimeoutSec 75
    if ($r -and $r.available) {
        if ($r.ok) {
            Write-Host ('  Играет: {0:N1} c, буфер {1:N0} c, узел {2}' -f $r.currentTime, $r.bufferedEnd, $r.ggcHost) -ForegroundColor Green
        } else {
            Write-Host ('  Не играет: ' + $r.reason) -ForegroundColor Red
        }
    } else {
        Write-Host '  Браузер для проверки не найден.' -ForegroundColor Yellow
    }
}

function Show-ZDiagnose {
    Show-ZHeader 'ДИАГНОСТИКА'
    $issues = New-Object System.Collections.ArrayList

    Write-Host ("  Windows       : " + (Get-CimInstance Win32_OperatingSystem).Caption + ' ' + [Environment]::OSVersion.Version)
    Write-Host ("  Права         : " + $(if (Test-ZAdmin) { 'администратор' } else { 'НЕТ (нужен запуск от админа)' }))

    try {
        $weakAcl = @(Get-ZAclWeakAces -Path $ZRoot)
        if ($weakAcl.Count -gt 0) {
            Write-Host ("  Права папки   : ОПАСНО — запись у обычных пользователей (" + ((@($weakAcl | ForEach-Object { $_.Identity } | Select-Object -Unique)) -join ', ') + ')') -ForegroundColor Red
            [void]$issues.Add(('Папка {0} доступна на запись обычным пользователям, а сторож запускает из неё скрипты от SYSTEM. Исправление: Zapret.bat fix-acl (от администратора).' -f $ZRoot))
        } else {
            Write-Host '  Права папки   : ограничены (Administrators/SYSTEM — запись, Users — чтение)' -ForegroundColor Green
        }
    } catch { }

    $legacy = @(Get-ZLegacyTasks)
    if ($legacy.Count -gt 0) {
        Write-Host ("  Чужие задачи  : " + (($legacy | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
        [void]$issues.Add(('Задачи, запускающие zapret из другой папки: {0}. При загрузке/входе они могут поднять второй winws и перезаписать службу. Исправление: Zapret.bat disable-legacy' -f (($legacy | ForEach-Object { $_.Name + ' -> ' + $_.Execute }) -join '; ')))
    }

    $img = Get-ZServiceImagePath
    if ($img) {
        Write-Host ("  Служба        : " + (Get-ZServiceState))
        if ($img -notlike "*$ZRoot*") {
            $exe = $img
            if ($img -match '^"([^"]+)"') { $exe = $Matches[1] }
            elseif ($img -match '^(\S+\.exe)') { $exe = $Matches[1] }
            [void]$issues.Add('Служба zapret запущена из другой папки: ' + $exe)
        }
    } else {
        [void]$issues.Add('Служба zapret не установлена.')
    }

    $w = Get-Service -Name 'WinDivert' -ErrorAction SilentlyContinue
    Write-Host ("  WinDivert     : " + $(if ($w) { $w.Status } else { 'не загружен' }))
    if (-not $w) { [void]$issues.Add('Драйвер WinDivert не загружен — zapret не работает без него.') }

    $conflicts = @()
    foreach ($n in @('GoodbyeDPI', 'goodbyedpi', 'winws2', 'discordfix_zapret', 'byedpi', 'ciadpi')) {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p) { $conflicts += $n }
    }
    if ($conflicts.Count -gt 0) {
        Write-Host ("  Конфликты     : " + ($conflicts -join ', ')) -ForegroundColor Yellow
        [void]$issues.Add('Одновременно запущены другие DPI-обходчики: ' + ($conflicts -join ', '))
    }

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path $hostsPath) {
        $zero = @(Select-String -LiteralPath $hostsPath -Pattern '^\s*0\.0\.0\.0' -ErrorAction SilentlyContinue)
        if ($zero.Count -gt 0) {
            $managed = @($zero | Where-Object { $_.Line -match 'zapret-ultimate dead ggc' })
            $foreign = @($zero | Where-Object { $_.Line -notmatch 'zapret-ultimate dead ggc' })
            Write-Host ("  hosts         : {0} записей 0.0.0.0 (управляемых GGC: {1}, прочих: {2})" -f $zero.Count, $managed.Count, $foreign.Count) -ForegroundColor $(if ($foreign.Count -gt 0) { 'Yellow' } else { 'Green' })
            if ($managed.Count -gt 0) {
                Write-Host ("    {0} из них — сознательные блокировки мёртвых GGC-узлов (это норма; снять: Zapret.bat ggc-reset)" -f $managed.Count) -ForegroundColor DarkGray
            }
            $foreignYt = @($foreign | Where-Object { $_.Line -match 'googlevideo|youtube|ytimg' }).Count
            if ($foreignYt -gt 0) {
                [void]$issues.Add(('В hosts {0} посторонних записей 0.0.0.0 для YouTube/googlevideo — из-за них видео может не грузиться. Исправление: Zapret.bat fix-hosts' -f $foreignYt))
            } elseif ($foreign.Count -gt 0) {
                [void]$issues.Add('В hosts есть чужие записи 0.0.0.0 — проверьте, не блокируют ли они нужные домены (Zapret.bat fix-hosts).')
            }
        }
    }

    $dns = (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses
    Write-Host ("  DNS           : " + ($dns -join ', '))

    $quicOff = $false
    try { $quicOff = Get-ZQuicPolicyState } catch { }
    if ($quicOff) {
        Write-Host '  QUIC          : отключён политикой (Chrome/Edge/Brave/Yandex ходят по TCP)' -ForegroundColor Green
    } else {
        Write-Host '  QUIC          : включён (если видео YouTube встаёт — попробуйте Zapret.bat quic-off)' -ForegroundColor DarkGray
    }

    $v6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike 'fe80*' -and $_.IPAddress -ne '::1' }
    if ($v6) {
        Write-Host ("  IPv6          : включён ({0} адресов) — часть трафика может идти мимо zapret" -f @($v6).Count) -ForegroundColor Yellow
        [void]$issues.Add('IPv6 активен: zapret по умолчанию обрабатывает IPv4. Если сайты «то работают, то нет» — отключите IPv6 на адаптере.')
    } else {
        Write-Host '  IPv6          : не используется'
    }

    $proxy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue)
    if ($proxy -and $proxy.ProxyEnable -eq 1) {
        Write-Host ("  Прокси        : включён " + $proxy.ProxyServer) -ForegroundColor Yellow
        [void]$issues.Add('Включён системный прокси — он может конфликтовать с zapret.')
    }

    Write-Host ''
    Write-Host '  Тест объёмной заморозки...' -ForegroundColor DarkGray
    $ytUrl = Get-ZYouTubeDirectUrl
    if ($ytUrl) { $freeze = Test-ZFreeze -Url $ytUrl } else { $freeze = Test-ZFreeze }
    if ($freeze) {
        if (-not $freeze.ok) {
            Write-Host ('  Заморозка: тест не удался ({0})' -f $freeze.err) -ForegroundColor Yellow
        } elseif ($freeze.stalled) {
            Write-Host ('  Заморозка: ДА, после {0} КБ' -f [int]($freeze.bytes / 1024)) -ForegroundColor Red
            [void]$issues.Add('Обнаружена заморозка TCP по объёму. Это не SNI-блокировка: zapret бессилен, нужен UDP-туннель (AmneziaWG/WireGuard) или VLESS+REALITY+XHTTP.')
        } else {
            Write-Host ('  Заморозка: нет ({0} КБ)' -f [int]($freeze.bytes / 1024)) -ForegroundColor Green
        }
    }

    Write-Host ''
    if ($issues.Count -eq 0) {
        Write-Host '  Проблем не найдено.' -ForegroundColor Green
    } else {
        Write-Host '  Найдено:' -ForegroundColor Yellow
        $i = 0
        foreach ($x in $issues) { $i++; Write-Host ("   {0}. {1}" -f $i, $x) -ForegroundColor Yellow }
    }
}

function Invoke-ZUninstall {
    Show-ZHeader 'УДАЛЕНИЕ'
    Assert-ZAdmin
    if (-not $Yes) {
        $a = Read-Host '  Удалить службу zapret и задачу автопроверки? (y/N)'
        if ($a -notmatch '^[yY]') { Write-Host '  Отменено.'; return }
    }
    Stop-ZService
    Stop-ZWinwsAll
    $svc = Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue
    if ($svc) { & sc.exe delete $ZServiceName | Out-Null }
    & schtasks.exe /Delete /TN 'ZapretUltimate Watchdog' /F 2>$null | Out-Null
    $tsMarker = Join-Path $ZState 'timestamps-changed.json'
    if (Test-Path -LiteralPath $tsMarker) {
        try {
            & netsh interface tcp set global timestamps=disabled | Out-Null
            Remove-Item -LiteralPath $tsMarker -Force -ErrorAction SilentlyContinue
            Write-ZLog 'TCP timestamps возвращены в исходное состояние (disabled).' OK
        } catch { }
    }
    Clear-ZInstalledInfo
    Write-ZLog 'Служба и задача автопроверки удалены. Папка с программой сохранена.' OK
    Write-Host '  Готово. Папку можно удалить вручную.' -ForegroundColor Green
}

function Set-ZQuicPolicy {
    param([switch]$Disable)
    Assert-ZAdmin
    foreach ($key in $script:ZQuicPolicyKeys) {
        if ($Disable) {
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
            Set-ItemProperty -Path $key -Name 'QuicAllowed' -Value 0 -Type DWord
        } else {
            if (Test-Path -LiteralPath $key) {
                Remove-ItemProperty -Path $key -Name 'QuicAllowed' -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-ZQuicPolicyState {
    foreach ($key in $script:ZQuicPolicyKeys) {
        if (Test-Path -LiteralPath $key) {
            $v = (Get-ItemProperty -Path $key -Name 'QuicAllowed' -ErrorAction SilentlyContinue).QuicAllowed
            if ($null -ne $v -and [int]$v -eq 0) { return $true }
        }
    }
    return $false
}

$script:ZGgcWatchFile = Join-Path $ZState 'ggc-watch.txt'

function Initialize-ZGgcWatchList {
    if (Test-Path -LiteralPath $script:ZGgcWatchFile) { return }
    $list = @()
    foreach ($g in @('8v1l', '8v1s', 'n8vs')) {
        foreach ($n in 1..8) { $list += "rr$n---sn-8ph2xajvh-$g.googlevideo.com" }
    }
    $list | Set-Content -LiteralPath $script:ZGgcWatchFile -Encoding UTF8
}

function Add-ZGgcWatchHosts {
    param([string[]]$Hosts)
    Initialize-ZGgcWatchList
    $cands = @($Hosts | Where-Object { $_ -and $_.Trim() -ne '' } | Select-Object -Unique)
    if ($cands.Count -eq 0) { return }
    $known = @(Get-Content -LiteralPath $script:ZGgcWatchFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    $new = @($cands | Where-Object { $known -notcontains $_ })
    if ($new.Count -gt 0) {
        Add-Content -LiteralPath $script:ZGgcWatchFile -Value $new -Encoding UTF8
        Write-ZLog ('В список наблюдения GGC добавлено узлов: {0}.' -f $new.Count) DEBUG
    }
}

# A blocked node that came back to life must be unblocked, otherwise YouTube
# stays broken on that node forever. A blocked host resolves to 0.0.0.0, so the
# real address is taken over DoH and curl connects to it with --resolve.
function Resolve-ZDoHAddress {
    param([string]$HostName, [int]$TimeoutSec = 5)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    $urls = @(
        ('https://cloudflare-dns.com/dns-query?name={0}&type=A' -f $HostName),
        ('https://dns.google/resolve?name={0}&type=A' -f $HostName)
    )
    foreach ($u in $urls) {
        try {
            $r = Invoke-RestMethod -Uri $u -Headers @{ Accept = 'application/dns-json' } -TimeoutSec $TimeoutSec -ErrorAction Stop
            $a = @($r.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { [string]$_.data } |
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
            if ($a.Count -gt 0) { return $a[0] }
        } catch { }
    }
    return $null
}

function Test-ZHostReachable {
    param([string]$HostName, [int]$TimeoutSec = 4)
    $ip = Resolve-ZDoHAddress -HostName $HostName
    if (-not $ip) { return $false }
    # --resolve ignores the hosts file, so a managed block does not hide the truth.
    $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time $TimeoutSec --resolve "${HostName}:443:$ip" "https://$HostName/generate_204" 2>$null) -join ''
    return ($code -match '^(2|3)\d\d$')
}

function Restore-ZAliveGgcHosts {
    param([switch]$Quiet)
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hosts)) { return }
    $blocked = @()
    try {
        $blocked = @(Select-String -LiteralPath $hosts -Pattern '^\s*0\.0\.0\.0\s+(\S+).*zapret-ultimate dead ggc' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Matches[0].Groups[1].Value } | Where-Object { $_ } | Select-Object -Unique)
    } catch { }
    if ($blocked.Count -eq 0) { return }
    if (-not (Test-ZInternetAccess)) { return }
    $alive = @()
    foreach ($h in $blocked) {
        $ip = Resolve-ZDoHAddress -HostName $h
        if (-not $ip) { continue }
        # --resolve bypasses the hosts file, so a blocked node can be tested.
        $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 4 --resolve "${h}:443:$ip" "https://$h/generate_204" 2>$null) -join ''
        if ($code -match '^(2|3)\d\d$') { $alive += $h }
    }
    if ($alive.Count -eq 0) {
        Write-ZLog ('Заблокированные GGC-узлы: оживших нет (проверено {0}).' -f $blocked.Count) DEBUG
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $ZState ('hosts-ggc-unblock-' + $stamp + '.txt')
    Copy-Item -LiteralPath $hosts -Destination $backup -Force
    $lines = Get-Content -LiteralPath $hosts -Encoding Default
    $out = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $drop = $false
        foreach ($a in $alive) {
            if ($line -match ('^\s*0\.0\.0\.0\s+' + [regex]::Escape($a) + '\s')) { $drop = $true; break }
        }
        if (-not $drop) { [void]$out.Add($line) }
    }
    # Drop the group header too when no managed block is left.
    if (@($out | Where-Object { $_ -match '^\s*0\.0\.0\.0.*zapret-ultimate dead ggc' }).Count -eq 0) {
        $filtered = New-Object System.Collections.ArrayList
        foreach ($l in $out) { if ($l -ne '# zapret-ultimate dead ggc') { [void]$filtered.Add($l) } }
        $out = $filtered
    }
    [IO.File]::WriteAllLines($hosts, $out, [Text.Encoding]::Default)
    & ipconfig.exe /flushdns | Out-Null
    Write-ZLog ('Разблокировано оживших GGC-узлов: {0} (проверено {1}). Бэкап: {2}' -f $alive.Count, $blocked.Count, $backup) OK
    if (-not $Quiet) {
        Write-Host ('  Разблокировано оживших GGC-узлов: {0} ({1}).' -f $alive.Count, ($alive -join ', ')) -ForegroundColor Green
        Write-Host '  Полностью перезапустите браузер.' -ForegroundColor Yellow
    }
}

# Checks every host from state\ggc-watch.txt and blocks the dead ones in hosts.
# This is how "video hangs on a dead GGC node" is fixed without touching the
# working nodes (blocking the whole cluster broke playback for other videos).
function Invoke-ZGgcCheck {
    param(
        [string[]]$Hosts,
        [switch]$Quiet,
        [switch]$SkipRestore
    )
    Assert-ZAdmin
    Initialize-ZGgcWatchList
    if (-not $SkipRestore) { Restore-ZAliveGgcHosts -Quiet:$Quiet }
    if ($Hosts -and $Hosts.Count -gt 0) {
        Add-ZGgcWatchHosts -Hosts $Hosts
        $cands = @($Hosts | Where-Object { $_ -and $_.Trim() -ne '' } | Select-Object -Unique)
    } else {
        $cands = @(Get-Content -LiteralPath $script:ZGgcWatchFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
    }
    if ($cands.Count -eq 0) { if (-not $Quiet) { Write-Host '  Список state\ggc-watch.txt пуст.' -ForegroundColor Yellow }; return }
    # Already-blocked nodes cannot recover while hosts redirects them, so skip
    # them: after the first pass the periodic check touches only live nodes.
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $blockedNow = @()
    try {
        $blockedNow = @(Select-String -LiteralPath $hostsPath -Pattern '^\s*0\.0\.0\.0\s+(\S+).*zapret-ultimate dead ggc' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Matches[0].Groups[1].Value })
    } catch { }
    if ($blockedNow.Count -gt 0) { $cands = @($cands | Where-Object { $blockedNow -notcontains $_ }) }
    if ($cands.Count -eq 0) {
        if (-not $Quiet) { Write-Host '  Все известные мёртвые узлы уже заблокированы.' -ForegroundColor Green }
        return
    }
    # When the uplink itself is down every node fails the check. Without this
    # guard a single network hiccup would block every node for good.
    if (-not (Test-ZInternetAccess)) {
        Write-ZLog 'Нет доступа в интернет — проверка GGC-узлов пропущена (иначе все узлы выглядели бы мёртвыми).' WARN
        if (-not $Quiet) { Write-Host '  Нет интернета — проверка узлов отменена, hosts не изменён.' -ForegroundColor Yellow }
        return
    }
    if (-not $Quiet) { Write-Host ("  Проверяю {0} узлов GGC..." -f $cands.Count) -ForegroundColor DarkGray }
    $dead = @()
    foreach ($h in $cands) {
        $alive = $false
        for ($attempt = 1; $attempt -le 2 -and -not $alive; $attempt++) {
            $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 4 "https://$h/generate_204" 2>$null) -join ''
            if ($code -match '^(2|3)\d\d$') { $alive = $true }
            elseif ($attempt -eq 1) { Start-Sleep -Milliseconds 500 }
        }
        if (-not $alive) { $dead += $h }
    }
    if ($dead.Count -gt 1 -and $dead.Count -eq $cands.Count) {
        # Every single node "dead" at once is a network/DPI-wide event, not a
        # per-node failure. Blocking all of them is exactly what broke playback.
        Write-ZLog ("Все {0} узлов не ответили — похоже на сетевую проблему, блокировка не применена." -f $cands.Count) ERROR
        if (-not $Quiet) { Write-Host ("  Все {0} узлов не ответили одновременно — это похоже на проблему сети, а не на мёртвые узлы. hosts не изменён." -f $cands.Count) -ForegroundColor Red }
        return
    }
    if ($dead.Count -eq 0) {
        if (-not $Quiet) { Write-Host '  Мёртвых узлов не найдено.' -ForegroundColor Green }
        return
    }
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $blocked = @()
    try {
        $blocked = @(Select-String -LiteralPath $hosts -Pattern '^\s*0\.0\.0\.0\s+(\S+).*zapret-ultimate dead ggc' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Matches[0].Groups[1].Value })
    } catch { }
    $all = @(@($blocked) + @($dead) | Where-Object { $_ } | Select-Object -Unique)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $ZState ('hosts-ggc-backup-' + $stamp + '.txt')
    Copy-Item -LiteralPath $hosts -Destination $backup -Force
    $lines = Get-Content -LiteralPath $hosts -Encoding Default
    $out = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ($line -match 'zapret-ultimate dead ggc') { continue }
        [void]$out.Add($line)
    }
    [void]$out.Add('# zapret-ultimate dead ggc')
    foreach ($d in $all) { [void]$out.Add("0.0.0.0 $d # zapret-ultimate dead ggc") }
    [IO.File]::WriteAllLines($hosts, $out, [Text.Encoding]::Default)
    & ipconfig.exe /flushdns | Out-Null
    Write-ZLog ('Заблокировано мёртвых GGC-узлов: {0} (всего {1}). Бэкап: {2}' -f $dead.Count, $all.Count, $backup) OK
    if (-not $Quiet) {
        Write-Host ('  Заблокировано новых мёртвых узлов: {0}, всего заблокировано: {1}' -f $dead.Count, $all.Count) -ForegroundColor Green
        Write-Host ('  Бэкап: {0}' -f $backup) -ForegroundColor DarkGray
        Write-Host '  Полностью перезапустите браузер.' -ForegroundColor Yellow
    }
}

function Reset-ZGgcHosts {
    Assert-ZAdmin
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $ZState ('hosts-ggc-reset-' + $stamp + '.txt')
    Copy-Item -LiteralPath $hosts -Destination $backup -Force
    $lines = Get-Content -LiteralPath $hosts -Encoding Default
    $out = New-Object System.Collections.ArrayList
    $removed = 0
    foreach ($line in $lines) {
        if ($line -match 'zapret-ultimate dead ggc') { $removed++; continue }
        [void]$out.Add($line)
    }
    [IO.File]::WriteAllLines($hosts, $out, [Text.Encoding]::Default)
    & ipconfig.exe /flushdns | Out-Null
    Write-ZLog ('Снято GGC-блокировок: {0}. Бэкап: {1}' -f $removed, $backup) OK
    Write-Host ('  Снято блокировок GGC: {0}' -f $removed) -ForegroundColor Green
    Write-Host '  Полностью перезапустите браузер.' -ForegroundColor Yellow
}

function Repair-ZHosts {
    Show-ZHeader 'ИСПРАВЛЕНИЕ HOSTS'
    Assert-ZAdmin
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hosts)) { Write-Host '  hosts не найден.' -ForegroundColor Red; return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $ZState ('hosts-backup-' + $stamp + '.txt')
    Copy-Item -LiteralPath $hosts -Destination $backup -Force
    Copy-Item -LiteralPath $hosts -Destination ($hosts + '.bak') -Force

    $lines = Get-Content -LiteralPath $hosts -Encoding Default
    $out = New-Object System.Collections.ArrayList
    $removed = 0
    foreach ($line in $lines) {
        # Keep our own managed dead-GGC blocks: fix-hosts is for stale/foreign
        # YouTube entries, not for undoing ggc-check. Use ggc-reset to clear them.
        if ($line -match 'zapret-ultimate dead ggc') { [void]$out.Add($line); continue }
        # A stale "YouTube GGC fix" maps CDN nodes to 0.0.0.0. YouTube then
        # picks exactly those nodes for some videos and playback never starts.
        if ($line -match '^\s*0\.0\.0\.0\s+\S*(googlevideo|youtube|ytimg|ggpht)\.') { $removed++; continue }
        if ($line -match 'YouTube GGC fix|fix_youtube_hosts') { $removed++; continue }
        [void]$out.Add($line)
    }
    if ($removed -eq 0) {
        Write-Host '  Блокирующих записей YouTube/googlevideo в hosts нет.' -ForegroundColor Green
        return
    }
    $final = New-Object System.Collections.ArrayList
    $blank = 0
    foreach ($l in $out) {
        if ($l.Trim() -eq '') { $blank++; if ($blank -gt 1) { continue } } else { $blank = 0 }
        [void]$final.Add($l)
    }
    [IO.File]::WriteAllLines($hosts, $final, [Text.Encoding]::Default)
    & ipconfig.exe /flushdns | Out-Null
    Write-ZLog ('Удалено записей из hosts: {0}. Резервная копия: {1}' -f $removed, $backup) OK
    Write-Host ('  Удалено записей: {0}' -f $removed) -ForegroundColor Green
    Write-Host ('  Резервная копия: {0}' -f $backup) -ForegroundColor DarkGray
    Write-Host '  Перезапустите браузер, чтобы он сбросил свой DNS-кэш.' -ForegroundColor Yellow
}

# ---------------------------------------------------------- system hygiene --
# Any scheduled task that starts zapret from another folder can bring up a
# second winws at boot and overwrite our service, so it is reported and can be
# disabled from here.
function Get-ZLegacyTasks {
    param([string]$Exclude = 'ZapretUltimate Watchdog')
    $list = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if (-not $t -or $t.TaskName -eq $Exclude) { continue }
        # A disabled task cannot fire, so it is not a problem any more.
        if ([string]$t.State -eq 'Disabled') { continue }
        foreach ($a in @($t.Actions)) {
            if (-not $a -or -not $a.Execute) { continue }
            # A task may hide the old path in Arguments (powershell -File ...).
            $cmd = (([string]$a.Execute) + ' ' + ([string]$a.Arguments)).Trim()
            if ($cmd -match 'zapret|winws' -and $cmd -notmatch [regex]::Escape($ZRoot)) {
                $list += [pscustomobject]@{ Name = $t.TaskName; Path = $t.TaskPath; Execute = $cmd; State = [string]$t.State }
            }
        }
    }
    return $list
}

function Invoke-ZFixAcl {
    Show-ZHeader 'ПРАВА НА ПАПКУ'
    Assert-ZAdmin
    $weak = @(Get-ZAclWeakAces -Path $ZRoot)
    if ($weak.Count -eq 0) {
        Write-Host '  Права уже ограничены.' -ForegroundColor Green
        return
    }
    $weakText = @($weak | ForEach-Object { $_.Identity + ' (' + $_.Rights + ')' } | Select-Object -Unique) -join ', '
    Write-Host ('  Сейчас папка доступна на запись: ' + $weakText) -ForegroundColor Yellow
    Set-ZRootAcl -Path $ZRoot
    Write-Host '  Готово: запись — Administrators и SYSTEM, чтение — Users.' -ForegroundColor Green
}

function Disable-ZLegacyTasks {
    Show-ZHeader 'ЧУЖИЕ ЗАДАЧИ ZAPRET'
    Assert-ZAdmin
    $list = @(Get-ZLegacyTasks)
    if ($list.Count -eq 0) { Write-Host '  Чужих задач не найдено.' -ForegroundColor Green; return }
    foreach ($l in $list) {
        Write-Host ('  {0} [{1}]' -f $l.Name, $l.State) -ForegroundColor Yellow
        Write-Host ('    ' + $l.Execute) -ForegroundColor DarkGray
    }
    if (-not $Yes) {
        $a = Read-Host '  Отключить эти задачи? (y/N)'
        if ($a -notmatch '^[yY]') { Write-Host '  Отменено.'; return }
    }
    foreach ($l in $list) {
        $ref = if ($l.Path -and $l.Path -ne '\') { $l.Path.TrimEnd('\') + '\' + $l.Name } else { $l.Name }
        & schtasks.exe /Change /TN $ref /DISABLE | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ('  Отключена: ' + $ref) -ForegroundColor Green
            Write-ZLog ('Отключена чужая задача ' + $ref + ' (' + $l.Execute + ')') WARN
        } else {
            Write-Host ('  Не удалось отключить: ' + $ref) -ForegroundColor Red
        }
    }
}

function Show-ZMenu {
    while ($true) {
        try { Clear-Host } catch { }
        try { $Host.UI.RawUI.WindowTitle = 'Zapret Ultimate' } catch { }
        Show-ZHeader 'МЕНЮ'
        $state = Get-ZServiceState
        $info = Get-ZInstalledInfo
        Write-Host ("  Служба: {0}   Профиль: {1}" -f $state, $(if ($info) { $info.profileId } else { '-' })) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   1. Статус и быстрая проверка'
        Write-Host '   2. Запустить службу'
        Write-Host '   3. Остановить службу'
        Write-Host '   4. Перезапустить службу'
        Write-Host '   5. АВТОТЮНИНГ (полный, ~3 мин)'
        Write-Host '   6. АВТОТЮНИНГ (быстрый, ~2 мин)'
        Write-Host '   7. Полный тест + скорость YouTube'
        Write-Host '   8. Диагностика'
        Write-Host '   9. Список профилей'
        Write-Host '  10. Применить профиль по id'
        Write-Host '  11. Вернуть исходную конфигурацию'
        Write-Host '  12. Удалить службу'
        Write-Host '  13. Исправить hosts (битые GGC-записи YouTube)'
        Write-Host '  14. Отключить QUIC (Chrome/Edge/Brave/Yandex)'
        Write-Host '  15. Включить QUIC обратно'
        Write-Host '  16. Проверить и заблокировать мёртвые GGC-узлы'
        Write-Host '  17. Снять блокировки GGC (вернуть все узлы)'
        Write-Host '  18. Исправить права на папку (закрыть дыру в ACL)'
        Write-Host '  19. Отключить чужие задачи zapret'
        Write-Host '  20. Проверка нескольких видео (4 ролика)'
        Write-Host '  21. Проверить видео по ссылке'
        Write-Host '  22. Обновление из GitHub'
        Write-Host '   0. Выход'
        Write-Host ''
        $c = Read-Host '  Выбор'
        switch ($c) {
            '1' { Show-ZStatus; Read-ZPause }
            '2' { Start-ZService; Write-Host '  Запущено.' -ForegroundColor Green; Read-ZPause }
            '3' { Stop-ZService; Write-Host '  Остановлено.' -ForegroundColor Yellow; Read-ZPause }
            '4' { Restart-ZService; Write-Host '  Перезапущено.' -ForegroundColor Green; Read-ZPause }
            '5' {
                try { & "$root\tools\tune.ps1" -Mode full }
                catch { Write-Host ('  Автотюнинг прерван: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '6' {
                try { & "$root\tools\tune.ps1" -Mode quick }
                catch { Write-Host ('  Автотюнинг прерван: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '7' { Show-ZTest; Read-ZPause }
            '8' { Show-ZDiagnose; Read-ZPause }
            '9' { Show-ZProfileList; Read-ZPause }
            '10' {
                Show-ZProfileList
                $id = Read-Host '  id профиля'
                if ($id) {
                    try {
                        $lib = Get-Content -LiteralPath (Join-Path $ZProfilesDir 'library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                        $p = @($lib.profiles | Where-Object { $_.id -eq $id })[0]
                        if ($p) { Apply-ZProfile -ProfileObject $p | Out-Null; Write-Host '  Применено.' -ForegroundColor Green }
                        else { Write-Host '  Профиль не найден.' -ForegroundColor Red }
                    } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                }
                Read-ZPause
            }
            '11' {
                try { Restore-ZOriginalService; Write-Host '  Исходная конфигурация восстановлена.' -ForegroundColor Green }
                catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '12' { Invoke-ZUninstall; Read-ZPause }
            '13' { Repair-ZHosts; Read-ZPause }
            '14' {
                try {
                    Set-ZQuicPolicy -Disable
                    Write-Host '  QUIC отключён для Chrome/Edge/Brave/Yandex. Полностью закройте и откройте браузер.' -ForegroundColor Green
                } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '17' {
                try { Reset-ZGgcHosts } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '16' {
                try { Invoke-ZGgcCheck } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '15' {
                try {
                    Set-ZQuicPolicy
                    Write-Host '  QUIC снова включён. Перезапустите браузер.' -ForegroundColor Green
                } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '18' {
                try { Invoke-ZFixAcl } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '19' {
                try { Disable-ZLegacyTasks } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '20' {
                try { Show-ZPlayback } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '21' {
                try { Show-ZVideoCheck } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '22' {
                try { & "$root\tools\update.ps1" } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '0' { return }
            default { }
        }
    }
}

# ------------------------------------------------------------------ router --
try {
    switch ($Command.ToLower()) {
        'status' { Show-ZStatus }
        'start' { Start-ZService; Write-Host 'Служба запущена.' -ForegroundColor Green }
        'stop' { Stop-ZService; Write-Host 'Служба остановлена.' -ForegroundColor Yellow }
        'restart' { Restart-ZService; Write-Host 'Служба перезапущена.' -ForegroundColor Green }
        'list' { Show-ZProfileList }
        'test' { Show-ZTest }
        'diagnose' { Show-ZDiagnose }
        'tune' { & "$root\tools\tune.ps1" -Mode full }
        'quick' { & "$root\tools\tune.ps1" -Mode quick }
        'apply' {
            if (-not $ProfileId) { Show-ZProfileList; $ProfileId = Read-Host 'Введите id профиля' }
            $lib = Get-Content -LiteralPath (Join-Path $ZProfilesDir 'library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $p = @($lib.profiles | Where-Object { $_.id -eq $ProfileId })[0]
            if (-not $p) { throw "Профиль '$ProfileId' не найден." }
            Apply-ZProfile -ProfileObject $p | Out-Null
            Write-Host ('Профиль применён: ' + $p.name) -ForegroundColor Green
        }
        'restore' { Restore-ZOriginalService; Write-Host 'Исходная конфигурация восстановлена.' -ForegroundColor Green }
        'fix-hosts' { Repair-ZHosts }
        'quic-off' {
            Set-ZQuicPolicy -Disable
            Write-Host 'QUIC отключён для Chrome/Edge/Brave/Yandex. Полностью закройте и откройте браузер.' -ForegroundColor Green
        }
        'ggc-check' { Invoke-ZGgcCheck }
        'ggc-reset' { Reset-ZGgcHosts }
        'playback' { Show-ZPlayback }
        'check-video' { Show-ZVideoCheck -Url $ProfileId }
        'update' { & "$root\tools\update.ps1" }
        'update-check' { & "$root\tools\update.ps1" -Check }
        'fix-acl' { Invoke-ZFixAcl }
        'disable-legacy' { Disable-ZLegacyTasks }
        'quic-on' {
            Set-ZQuicPolicy
            Write-Host 'QUIC снова включён. Перезапустите браузер.' -ForegroundColor Green
        }
        'uninstall' { Invoke-ZUninstall }
        'menu' { Show-ZMenu }
        default {
            Write-Host 'Команды: status, start, stop, restart, tune, quick, apply <id>, list, test, diagnose, fix-hosts, quic-off, quic-on, ggc-check, ggc-reset, playback, check-video, update, update-check, fix-acl, disable-legacy, restore, uninstall, menu'
        }
    }
} catch {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    Write-ZLog ('Ошибка выполнения команды ' + $Command + ': ' + $_.Exception.Message) ERROR
    $global:LASTEXITCODE = 1
    throw
}
