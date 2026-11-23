# ============================================================================
#  Zapret Ultimate - CLI entry point
#  Usage: Zapret.ps1 [status|start|stop|restart|tune|quick|apply|list|test|
#                     diagnose|restore|uninstall|menu]
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
    'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
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

    $procs = @(Get-ZWinwsProcesses)
    Write-Host ("  Процессы winws: {0}" -f $procs.Count)

    $svc = Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue
    if ($svc) { Write-Host ("  Автозапуск    : {0}" -f $svc.StartType) }

    Write-Host ''
    Write-Host '  Быстрая проверка доступности...' -ForegroundColor DarkGray
    $targets = @(Get-ZTargets | Where-Object { $_.key -in @('DiscordMain', 'YouTubeWeb', 'YouTubeRedirect', 'ControlYa') })
    $res = Invoke-ZProbe -Targets $targets -TimeoutMs 4000 -Quiet
    $sc = Get-ZProbeScore -Results $res
    Write-Host ('  ' + (Format-ZProbeSummary -Scored $sc)) -ForegroundColor $(if ($sc.score -ge 90 -and $sc.controlsOk) { 'Green' } else { 'Yellow' })
    foreach ($d in $sc.details) {
        $mark = if ($d.t13 -or $d.t12) { 'OK  ' } else { 'FAIL' }
        $col = if ($d.t13 -or $d.t12) { 'Green' } else { 'Red' }
        Write-Host ('    {0,-22} {1}' -f $d.key, $mark) -ForegroundColor $col -NoNewline
        Write-Host ('  TLS1.2={0} TLS1.3={1}' -f $d.t12, $d.t13) -ForegroundColor DarkGray
    }
}

function Show-ZProfileList {
    Show-ZHeader 'ПРОФИЛИ'
    $lib = Get-Content -LiteralPath (Join-Path $ZProfilesDir 'library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $info = Get-ZInstalledInfo
    $scores = @{}
    $rp = Join-Path $ZState 'tune-results.json'
    if (Test-Path -LiteralPath $rp) {
        $tr = Get-Content -LiteralPath $rp -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($tr.results)) { if ($r.id) { $scores[$r.id] = $r.score } }
    }
    foreach ($p in @($lib.profiles)) {
        $mark = if ($info -and $info.profileId -eq $p.id) { '*' } else { ' ' }
        $sc = if ($scores.ContainsKey($p.id)) { ('{0}%' -f $scores[$p.id]) } else { '  -  ' }
        Write-Host ('  {0} {1,-20} {2,6}  {3}' -f $mark, $p.id, $sc, $p.name)
    }
    Write-Host ''
    Write-Host '  * — активный профиль. Применить: Zapret.bat apply <id>' -ForegroundColor DarkGray
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

    Write-Host '  Проверка реального воспроизведения (Brave/Chrome/Edge)...' -ForegroundColor DarkGray
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
        }
        $rep.playback = $play
    } else {
        Write-Host ('  Проверить воспроизведение не удалось: {0}' -f $(if ($play) { $play.reason } else { 'браузер не найден' })) -ForegroundColor Yellow
    }
    $out = Join-Path $ZLogs ('report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    ($rep | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $out -Encoding UTF8
    Write-Host ('  Отчёт сохранён: ' + $out) -ForegroundColor DarkGray
}

function Show-ZDiagnose {
    Show-ZHeader 'ДИАГНОСТИКА'
    $issues = New-Object System.Collections.ArrayList

    Write-Host ("  Windows       : " + (Get-CimInstance Win32_OperatingSystem).Caption + ' ' + [Environment]::OSVersion.Version)
    Write-Host ("  Права         : " + $(if (Test-ZAdmin) { 'администратор' } else { 'НЕТ (нужен запуск от админа)' }))

    $img = Get-ZServiceImagePath
    if ($img) {
        Write-Host ("  Служба        : " + (Get-ZServiceState))
        if ($img -notlike "*$ZRoot*") {
            [void]$issues.Add('Служба указывает на старую папку: ' + $img)
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
            Write-Host ("  hosts         : {0} записей 0.0.0.0 (блокировка доменов)" -f $zero.Count) -ForegroundColor Yellow
            $ggc = @($zero | Where-Object { $_.Line -match 'googlevideo|youtube|ytimg' }).Count
            if ($ggc -gt 0) {
                [void]$issues.Add(('В hosts {0} записей 0.0.0.0 для YouTube/googlevideo — именно из-за них видео не грузится. Исправление: Zapret.bat fix-hosts' -f $ggc))
            } else {
                [void]$issues.Add('В hosts есть записи 0.0.0.0 — проверьте, не блокируют ли они нужные домены (Zapret.bat fix-hosts чинит записи YouTube).')
            }
        }
    }

    $dns = (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses
    Write-Host ("  DNS           : " + ($dns -join ', '))

    $quicOff = $false
    try { $quicOff = Get-ZQuicPolicyState } catch { }
    if ($quicOff) {
        Write-Host '  QUIC          : отключён политикой (Brave/Chrome/Edge ходят по TCP)' -ForegroundColor Green
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

function Repair-ZHosts {    Show-ZHeader 'ИСПРАВЛЕНИЕ HOSTS'
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
        Write-Host '   5. АВТОТЮНИНГ (полный, ~5-10 мин)'
        Write-Host '   6. АВТОТЮНИНГ (быстрый, ~1-2 мин)'
        Write-Host '   7. Полный тест + скорость YouTube'
        Write-Host '   8. Диагностика'
        Write-Host '   9. Список профилей'
        Write-Host '  10. Применить профиль по id'
        Write-Host '  11. Вернуть исходную конфигурацию'
        Write-Host '  12. Удалить службу'
        Write-Host '  13. Исправить hosts (битые GGC-записи YouTube)'
        Write-Host '  14. Отключить QUIC (Brave/Chrome/Edge)'
        Write-Host '  15. Включить QUIC обратно'
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
                    Write-Host '  QUIC отключён для Brave/Chrome/Edge. Полностью закройте и откройте браузер.' -ForegroundColor Green
                } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
                Read-ZPause
            }
            '15' {
                try {
                    Set-ZQuicPolicy
                    Write-Host '  QUIC снова включён. Перезапустите браузер.' -ForegroundColor Green
                } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
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
            Write-Host 'QUIC отключён для Brave/Chrome/Edge. Полностью закройте и откройте браузер.' -ForegroundColor Green
        }
        'quic-on' {
            Set-ZQuicPolicy
            Write-Host 'QUIC снова включён. Перезапустите браузер.' -ForegroundColor Green
        }
        'uninstall' { Invoke-ZUninstall }
        'menu' { Show-ZMenu }
        default {
            Write-Host 'Команды: status, start, stop, restart, tune, quick, apply <id>, list, test, diagnose, fix-hosts, quic-off, quic-on, restore, uninstall, menu'
        }
    }
} catch {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    Write-ZLog ('Ошибка выполнения команды ' + $Command + ': ' + $_.Exception.Message) ERROR
    $global:LASTEXITCODE = 1
    throw
}
