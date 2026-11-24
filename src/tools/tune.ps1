# ============================================================================
#  Zapret Ultimate - auto tuner
#
#  Measures what is actually blocked on this ISP right now, benchmarks every
#  strategy from profiles\library.json, then validates the finalists with a real
#  YouTube download and a real Chrome/Edge page before installing anything.
#
#  Safety:
#   * one global operation lock (the watchdog respects it);
#   * the whole run is wrapped in try/finally: if it crashes or is interrupted,
#     the previous service configuration is restored;
#   * if the winning profile fails the final check, the previous configuration
#     is restored automatically.
# ============================================================================
param(
    [ValidateSet('quick', 'full')][string]$Mode = 'full',
    [int]$TimeoutMs = 2000,
    [int]$MaxProfiles = 0,
    [switch]$SkipSpeed,
    [switch]$SkipBrowser,
    [switch]$NoInstall
)

$root = Split-Path -Parent $PSScriptRoot
. "$root\lib\common.ps1"
. "$root\lib\engine.ps1"
. "$root\lib\probe.ps1"

$ErrorActionPreference = 'Stop'
Assert-ZAdmin

# The report is saved several times during a run: a tuning pass takes minutes
# and must not lose its results if it is interrupted or the PC goes to sleep.
function Save-ZTuneReport {
    param($Report)
    if ($null -eq $Report) { return }
    try { Write-ZJson -Path (Join-Path $ZState 'tune-results.json') -Object $Report -Depth 10 }
    catch { Write-ZLog ('Не удалось сохранить state\tune-results.json: ' + $_.Exception.Message) WARN }
}

# The lite package has no yt-dlp: speed measurement is then skipped instead of
# rejecting every profile.
if (-not $SkipSpeed -and -not (Test-Path -LiteralPath (Join-Path $ZTools 'yt-dlp.exe'))) {
    $SkipSpeed = $true
    Write-ZLog 'yt-dlp не найден — тест скорости YouTube будет пропущен.' WARN
}

if (-not (Enter-ZLock -Name 'operation')) {
    throw 'Другая операция (тюнинг/установка) уже выполняется. Подождите или удалите state\operation.lock.'
}

$installedOk = $false
$appliedNew = $false
$startedAt = Get-Date
$prevImage = Get-ZServiceImagePath
$baselineScore = 0.0

try {
    $lib = Get-Content -LiteralPath (Join-Path $ZProfilesDir 'library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $allProfiles = @($lib.profiles)
    if ($Mode -eq 'quick') {
        $preferred = @('fake-hfs-ts', 'fake-ms-seqovl', 'fake-mdo-badseq', 'hostfakesplit-only', 'fake-ms-4pda', 'fakedsplit')
        $allProfiles = @($allProfiles | Where-Object { $preferred -contains $_.id })
    }
    if ($MaxProfiles -gt 0) { $allProfiles = @($allProfiles | Select-Object -First $MaxProfiles) }

    # Screening is intentionally small: tuning stops the service, so every second
    # counts. The winners are re-checked against the full target list later.
    $screenKeys = @('DiscordMain', 'YouTubeWeb', 'YouTubeRedirect', 'GoogleMain', 'ControlYa')
    $screenTargets = @(Get-ZTargets | Where-Object { $screenKeys -contains $_.key })
    $fullTargets = @(Get-ZTargets)
    if ($screenTargets.Count -lt 3) { throw 'Не удалось загрузить список целей (config\targets.json).' }

    $tuneDir = Join-Path $ZState 'tune'
    if (-not (Test-Path -LiteralPath $tuneDir)) { New-Item -ItemType Directory -Force -Path $tuneDir | Out-Null }

    Write-ZLog '==================================================================' INFO
    Write-ZLog ('АВТОТЮНИНГ: профилей {0}, режим {1}, проверка ~2-3 мин' -f $allProfiles.Count, $Mode) INFO
    Write-ZLog 'ВНИМАНИЕ: на время тюнинга служба останавливается, YouTube/Discord недоступны.' WARN
    Write-ZLog '==================================================================' INFO

    Save-ZServiceBackup
    Stop-ZService
    Stop-ZWinwsAll
    Start-Sleep -Milliseconds 800

    # ----------------------------------------------------------- baseline ---
    Write-ZLog 'Базовый замер БЕЗ обхода...' INFO
    $baseResults = Invoke-ZProbe -Targets $screenTargets -TimeoutMs $TimeoutMs -Quiet
    $baseScore = Get-ZProbeScore -Results $baseResults
    $baselineScore = $baseScore.score
    Write-ZLog ('БЕЗ ОБХОДА: ' + (Format-ZProbeSummary -Scored $baseScore)) WARN

    # ---------------------------------------------------------- benchmark ---
    $results = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($profile in $allProfiles) {
        $i++
        $cfg = Join-Path $tuneDir ($profile.id + '.conf')
        try {
            Write-ZWinwsConfig -Arguments $profile.args -Path $cfg | Out-Null
            $check = Test-ZWinwsConfig -Path $cfg
            if (-not $check.ok) {
                Write-ZLog ("[{0}/{1}] {2}: конфигурация отклонена winws" -f $i, $allProfiles.Count, $profile.id) ERROR
                [void]$results.Add([pscustomobject]@{ id = $profile.id; name = $profile.name; score = -1; controlsOk = $false; categories = $null; error = $check.output; ms = 0; avgMs = 9999 })
                continue
            }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $probe = Invoke-ZWinwsSession -ConfigPath $cfg -Action {
                Start-Sleep -Milliseconds 350
                Invoke-ZProbe -Targets $screenTargets -TimeoutMs $TimeoutMs -Quiet
            }
            $sc = Get-ZProbeScore -Results $probe
            $sw.Stop()
            $meas = @($sc.details | Where-Object { $_.cat -ne 'control' -and $_.ms -gt 0 })
            $avgMs = 0
            if ($meas.Count -gt 0) { $avgMs = [int](($meas | Measure-Object -Property ms -Average).Average) }
            [void]$results.Add([pscustomobject]@{
                    id = $profile.id; name = $profile.name; score = $sc.score; controlsOk = $sc.controlsOk
                    categories = $sc.categories; details = $sc.details; ms = [int]$sw.ElapsedMilliseconds; avgMs = $avgMs; error = ''
                })
            Write-ZLog ("[{0}/{1}] {2,-20} {3}" -f $i, $allProfiles.Count, $profile.id, (Format-ZProbeSummary -Scored $sc)) $(if ($sc.score -ge 90 -and $sc.controlsOk) { 'OK' } elseif ($sc.score -ge 50) { 'WARN' } else { 'INFO' })
        } catch {
            Write-ZLog ("[{0}/{1}] {2,-20} ОШИБКА: {3}" -f $i, $allProfiles.Count, $profile.id, $_.Exception.Message) ERROR
            [void]$results.Add([pscustomobject]@{ id = $profile.id; name = $profile.name; score = -1; controlsOk = $false; categories = $null; error = $_.Exception.Message; ms = 0; avgMs = 9999 })
        } finally {
            Stop-ZWinwsAll
            Start-Sleep -Milliseconds 300
        }
    }

    # ---------------------------------------------------------- selection ---
    $valid = @($results | Where-Object { $_.score -ge 0 -and $_.controlsOk } |
        Sort-Object -Property @{Expression = 'score'; Descending = $true },
        @{Expression = { $_.categories.youtube }; Descending = $true },
        @{Expression = { $_.categories.discord }; Descending = $true },
        @{Expression = 'avgMs'; Descending = $false })

    $report = [ordered]@{
        startedAt  = $startedAt.ToString('o')
        mode       = $Mode
        baseline   = [ordered]@{ score = $baseScore.score; categories = $baseScore.categories; controlsOk = $baseScore.controlsOk }
        results    = @($results)
        finalists  = @()
        best       = $null
        applied    = $false
    }

    if ($valid.Count -eq 0) {
        Write-ZLog 'Ни один профиль не прошёл проверку. Возвращаю исходную конфигурацию.' ERROR
        throw 'Автотюнинг не нашёл рабочего профиля.'
    }

    # Nothing to do if the ISP is not blocking at all.
    if ($baselineScore -ge 95 -and -not $NoInstall) {
        Write-ZLog ('Блокировок не обнаружено (baseline {0}%). Установка не требуется.' -f $baselineScore) OK
        $report.applied = $false
        Write-ZJson -Path (Join-Path $ZState 'tune-results.json') -Object $report -Depth 10
        exit 0
    }

    # Save screening results right away: the finalist/browser phase takes
    # minutes, and an interruption must not lose everything measured so far.
    Save-ZTuneReport -Report $report

    # ---------------------------------------------------------- finalists ---
    # A profile is only accepted after a real YouTube download and a real
    # Chrome/Edge page load. Synthetic TLS probes alone are not enough.
    $chosen = $null
    $chosenSpeed = $null
    $chosenBrowser = $null
    # Finalists that failed their checks must never become the fallback.
    $rejected = @()
    foreach ($f in @($valid | Select-Object -First 2)) {
        $cfg = Join-Path $tuneDir ($f.id + '.conf')
        Write-ZLog ('Проверяю финалиста {0} (браузер + скорость)...' -f $f.id) INFO
        $speed = $null; $browser = $null; $full = $null; $bulk = $null
        try {
            $full = Invoke-ZWinwsSession -ConfigPath $cfg -Action {
                Start-Sleep -Milliseconds 350
                Invoke-ZProbe -Targets $fullTargets -TimeoutMs 3000 -Quiet
            }
        } catch { Write-ZLog ('  полный probe не удался: ' + $_.Exception.Message) WARN }

        $fullScore = $null
        if ($full) { $fullScore = Get-ZProbeScore -Results $full }

        # Large transfers: catches profiles that pass TLS but freeze after ~16 KB
        # (this exact failure kept the Discord window from ever loading).
        try {
            $bulk = Invoke-ZWinwsSession -ConfigPath $cfg -Action {
                Start-Sleep -Milliseconds 300
                Test-ZBulkHttp
            }
        } catch { Write-ZLog ('  bulk-тест не удался: ' + $_.Exception.Message) WARN }

        if (-not $SkipSpeed) {
            try {
                $speed = Invoke-ZWinwsSession -ConfigPath $cfg -Action {
                    Start-Sleep -Milliseconds 350
                    Test-ZYouTubeSpeed
                }
            } catch { Write-ZLog ('  тест скорости не удался: ' + $_.Exception.Message) WARN }
        }
        if (-not $SkipBrowser) {
            try {
                $browser = Invoke-ZWinwsSession -ConfigPath $cfg -Action {
                    Start-Sleep -Milliseconds 350
                    Test-ZBrowserPlayback -WaitSec 15 -TimeoutSec 70
                }
            } catch { Write-ZLog ('  браузерный тест не удался: ' + $_.Exception.Message) WARN }
        }
        Start-Sleep -Milliseconds 300

        $okSpeed = ($SkipSpeed -or ($speed -and $speed.ok -and $speed.mbps -ge 2))
        $okBrowser = ($SkipBrowser -or ($browser -and ($browser.ok -or (-not $browser.available))))
        $okFull = ($fullScore -and $fullScore.controlsOk -and $fullScore.score -ge 80)
        $okBulk = ($bulk -and $bulk.ok)
        $okScreen = ($f.score -ge 80 -and $f.controlsOk)

        Write-ZLog ('  {0}: screen={1}% full={2}% speed={3} Mbps bulk={4} browser={5} => {6}' -f `
                $f.id, $f.score, $(if ($fullScore) { $fullScore.score } else { 'n/a' }),
                $(if ($speed) { $speed.mbps } else { 'n/a' }),
                $(if ($bulk) { ('{0}/{1} КБ' -f [int]($bulk.cloudflareBytes / 1024), [int]($bulk.discordBytes / 1024)) } else { 'n/a' }),
                $(if ($browser) { ($(if ($browser.ok) { 'OK' } else { 'FAIL: ' + $browser.reason })) } else { 'n/a' }),
                $(if ($okSpeed -and $okBrowser -and $okFull -and $okBulk -and $okScreen) { 'ПОДХОДИТ' } else { 'отклонён' })) `
            $(if ($okSpeed -and $okBrowser -and $okFull -and $okBulk -and $okScreen) { 'OK' } else { 'WARN' })

        $report.finalists += [ordered]@{
            id = $f.id; screen = $f.score; full = $(if ($fullScore) { $fullScore.score } else { $null })
            speedMbps = $(if ($speed) { $speed.mbps } else { $null })
            bulkCloudflare = $(if ($bulk) { $bulk.cloudflareBytes } else { $null })
            bulkDiscord = $(if ($bulk) { $bulk.discordBytes } else { $null })
            browser = $(if ($browser) { $browser.reason } else { $null })
            accepted = ($okSpeed -and $okBrowser -and $okFull -and $okBulk -and $okScreen)
        }

        if ($okSpeed -and $okBrowser -and $okFull -and $okBulk -and $okScreen) {
            $chosen = $f
            $chosenSpeed = $speed
            $chosenBrowser = $browser
            break
        }
        else { $rejected += $f.id }
    }

    Save-ZTuneReport -Report $report

    if (-not $chosen) {
        Write-ZLog 'Ни один профиль не прошёл финальную проверку (браузер/скорость). Возвращаю исходную конфигурацию.' ERROR
        $report.applied = $false
        Write-ZJson -Path (Join-Path $ZState 'tune-results.json') -Object $report -Depth 10
        throw 'Финальная проверка не пройдена: профиль не открывает YouTube в браузере или режет скорость.'
    }

    $best = $chosen
    $report.best = $best
    # Runner-up for the watchdog. Chosen AFTER the winner is known and never
    # equal to it: otherwise the fallback is the profile that was just installed
    # (or one that failed its finalist checks) and the watchdog can never switch.
    $fallbackPath = Join-Path $ZState 'fallback-profile.json'
    $runnerUp = @($valid | Where-Object { $_.id -ne $best.id -and $rejected -notcontains $_.id } | Select-Object -First 1)
    if ($runnerUp.Count -gt 0) {
        $fbProfile = @($allProfiles | Where-Object { $_.id -eq $runnerUp[0].id })[0]
        if ($fbProfile) {
            Write-ZJson -Path $fallbackPath -Object ([ordered]@{ id = $fbProfile.id; name = $fbProfile.name; desc = $fbProfile.desc; engine = 'winws1'; args = $fbProfile.args }) -Depth 6
            Write-ZLog ('Резервный профиль: {0} ({1})' -f $fbProfile.name, $fbProfile.id) INFO
        }
    } else {
        Remove-Item -LiteralPath $fallbackPath -Force -ErrorAction SilentlyContinue
    }
    Write-ZLog ('ЛУЧШИЙ ПРОФИЛЬ: {0} ({1})' -f $best.name, $best.id) OK

    # ------------------------------------------------------------ install ---
    if (-not $NoInstall) {
        $bestProfile = @($allProfiles | Where-Object { $_.id -eq $best.id })[0]
        try {
            Apply-ZProfile -ProfileObject $bestProfile | Out-Null
            $appliedNew = $true
        } catch {
            Write-ZLog ('Не удалось установить лучший профиль: ' + $_.Exception.Message) ERROR
            throw
        }
        Start-Sleep -Milliseconds 700
        $finalResults = Invoke-ZProbe -Targets $fullTargets -TimeoutMs 3000 -Quiet
        $final = Get-ZProbeScore -Results $finalResults
        Write-ZLog ('ПОСЛЕ УСТАНОВКИ: ' + (Format-ZProbeSummary -Scored $final)) INFO

        $finalOk = ($final.controlsOk -and $final.score -ge 80)
        if ($finalOk -and -not $SkipBrowser) {
            $finalBrowser = Test-ZBrowserPlayback -WaitSec 15 -TimeoutSec 70
            if ($finalBrowser -and $finalBrowser.available -and -not $finalBrowser.ok) {
                $finalOk = $false
                Write-ZLog ('Финальная браузерная проверка не пройдена: ' + $finalBrowser.reason) ERROR
            } elseif (-not $finalBrowser.available) {
                Write-ZLog ('Браузерная проверка недоступна: ' + $finalBrowser.reason) WARN
            }
        }
        if ($finalOk) {
            $finalBulk = Test-ZBulkHttp
            if (-not $finalBulk.ok) {
                $finalOk = $false
                Write-ZLog ('Финальная проверка больших загрузок не пройдена: ' + $finalBulk.err) ERROR
            }
            $report['bulk'] = [ordered]@{ cloudflareBytes = $finalBulk.cloudflareBytes; discordBytes = $finalBulk.discordBytes; ok = $finalBulk.ok }
        }
        if (-not $finalOk) {
            Write-ZLog 'Итоговая проверка неудовлетворительна — откатываюсь на предыдущую конфигурацию.' ERROR
            throw 'Не удалось подтвердить работоспособность после установки. Выполнен откат.'
        }
        $installedOk = $true
        $report.applied = $true
        $report['final'] = [ordered]@{ score = $final.score; categories = $final.categories; controlsOk = $final.controlsOk }
    }

    Write-ZJson -Path (Join-Path $ZState 'tune-results.json') -Object $report -Depth 10

    $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
    Write-ZLog ('АВТОТЮНИНГ ЗАВЕРШЁН за ' + (Format-ZDuration $elapsed)) OK
    Write-Host ''
    Write-Host '  Итоговая таблица:' -ForegroundColor Cyan
    $results | Sort-Object score -Descending | ForEach-Object {
        Write-Host ('   {0,-22} {1,6}%  controls={2,-6} {3}' -f $_.id, $_.score, $_.controlsOk, $_.error)
    }
} finally {
    # Best-effort: keep whatever was measured even if the run failed halfway.
    Save-ZTuneReport -Report $report
    Exit-ZLock
    if (-not $installedOk) {
        if ($appliedNew -and $prevImage) {
            try {
                Install-ZServiceByImagePath -ImagePath $prevImage
                Write-ZLog 'Новый профиль отклонён — предыдущая конфигурация восстановлена.' WARN
            } catch { Write-ZLog ('Откат не удался: ' + $_.Exception.Message) ERROR }
        } else {
            # Never leave the machine without a working service after a crash.
            $state = Get-ZServiceState
            if ($state -eq 'Running') {
                # service is alive (e.g. NoInstall mode) - nothing to do
            } elseif ($state -ne 'NotInstalled') {
                try { Start-ZService; Write-ZLog 'Служба снова запущена (аварийное восстановление).' WARN } catch { }
            } elseif ($prevImage) {
                try { Install-ZServiceByImagePath -ImagePath $prevImage; Write-ZLog 'Предыдущая конфигурация восстановлена.' WARN } catch { }
            } else {
                $bk = Get-ZServiceBackup
                if ($bk -and $bk.existed) { try { Restore-ZOriginalService } catch { } }
            }
        }
    }
}
