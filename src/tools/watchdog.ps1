# ============================================================================
#  Zapret Ultimate - watchdog
#  Runs from Task Scheduler as SYSTEM every 5 minutes.
#  1. ensuress the service and winws.exe are alive;
#  2. probes Discord/YouTube/control host;
#  3. restarts the service once, then switches to the fallback profile.
#  Everything is rate limited so a broken ISP cannot cause a restart loop.
# ============================================================================
param([switch]$Force)

$root = Split-Path -Parent $PSScriptRoot
. "$root\lib\common.ps1"
. "$root\lib\engine.ps1"
. "$root\lib\probe.ps1"

$watchLog = Join-Path $ZLogs 'watchdog.log'
function Write-WLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $watchLog -Value $line -Encoding UTF8
    if ($Level -ne 'DEBUG') { Write-ZLog $Message $Level }
}

# The tuner/installer holds this lock while it stops the service. Starting the
# service in the middle of a tuning pass would corrupt the measurements.
if (Test-ZLock -Name 'operation') {
    Write-WLog 'Идёт тюнинг/установка — проверка пропущена.' DEBUG
    return
}

$statePath = Join-Path $ZState 'watchdog.json'
$ws = [ordered]@{ restarts = @(); lastProfileSwitch = $null }
if (Test-Path -LiteralPath $statePath) {
    try { $ws = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$now = Get-Date
$recent = @($ws.restarts | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Where-Object { ($now - $_) -lt [timespan]::FromMinutes(30) })

function Save-WState {
    $obj = [ordered]@{ restarts = @($recent | ForEach-Object { $_.ToString('o') }); lastProfileSwitch = $ws.lastProfileSwitch }
    Write-ZJson -Path $statePath -Object $obj -Depth 4
}

# ---------------------------------------------------------------- liveness --
$state = Get-ZServiceState
$procs = @(Get-ZWinwsProcesses)
if ($state -ne 'Running' -or $procs.Count -eq 0) {
    if ($recent.Count -ge 3 -and -not $Force) {
        Write-WLog ("Служба не работает, но лимит перезапусков исчерпан ({0} за 30 мин). Жду." -f $recent.Count) WARN
        return
    }
    Write-WLog ("Служба: state={0}, процессов winws={1}. Запускаю." -f $state, $procs.Count) WARN
    try {
        if ($state -eq 'NotInstalled') {
            # Reinstall the last known profile instead of giving up.
            $info = Get-ZInstalledInfo
            $reinstalled = $false
            if ($info -and $info.profileId) {
                $lib = Get-Content -LiteralPath (Join-Path $ZProfilesDir 'library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $prof = @(@($lib.profiles) | Where-Object { $_.id -eq $info.profileId })[0]
                if ($prof) {
                    Apply-ZProfile -ProfileObject $prof | Out-Null
                    $reinstalled = $true
                    Write-WLog ('Служба отсутствовала — переустановлен профиль {0}.' -f $prof.id) WARN
                }
            }
            if (-not $reinstalled) { throw 'Служба не установлена, профиль для восстановления не найден' }
        } elseif ($state -ne 'Running') {
            Start-ZService
        } else {
            Restart-ZService
        }
        $recent += (Get-Date)
        Save-WState
    } catch {
        Write-WLog ('Не удалось запустить службу: ' + $_.Exception.Message) ERROR
    }
    Start-Sleep -Seconds 3
}

# ------------------------------------------------------------------- probe --
$targets = @(Get-ZTargets | Where-Object { $_.key -in @('DiscordMain', 'YouTubeWeb', 'YouTubeRedirect', 'ControlYa') })
$res = Invoke-ZProbe -Targets $targets -TimeoutMs 3500 -Quiet -NoRetry
$sc = Get-ZProbeScore -Results $res
Write-WLog ('Проверка: ' + (Format-ZProbeSummary -Scored $sc)) DEBUG

# Every 30 minutes scan known GGC nodes in a hidden process and block the dead
# ones. This is what makes the fix automatic: no manual commands after a hang.
$ggcStamp = Join-Path $ZState 'ggc-last.txt'
$lastGgc = $null
if (Test-Path -LiteralPath $ggcStamp) {
    try { $lastGgc = [datetime]::Parse((Get-Content -LiteralPath $ggcStamp -Raw).Trim()) } catch { }
}
if (-not $lastGgc -or ((Get-Date) - $lastGgc).TotalMinutes -ge 30) {
    if (-not (Test-ZLock -Name 'operation')) {
        try {
            $zp = Join-Path (Split-Path -Parent $PSScriptRoot) 'Zapret.ps1'
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ("& '" + $zp + "' ggc-check")) -WindowStyle Hidden | Out-Null
            (Get-Date).ToString('o') | Set-Content -LiteralPath $ggcStamp -Encoding UTF8
            Write-WLog 'Запущена фоновая проверка GGC-узлов.' DEBUG
        } catch {
            Write-WLog ('GGC-проверка не запустилась: ' + $_.Exception.Message) WARN
        }
    }
}

if ($sc.controlsOk -and $sc.score -ge 60) { return }   # everything is fine

function Test-ZAfterRestart {
    Start-Sleep -Seconds 4
    $r = Invoke-ZProbe -Targets $targets -TimeoutMs 3500 -Quiet -NoRetry
    return (Get-ZProbeScore -Results $r)
}

# --------------------------------------------------------------- recovery ---
if ($recent.Count -lt 3 -or $Force) {
    Write-WLog 'Доступность упала — перезапускаю службу.' WARN
    try {
        Restart-ZService
        $recent += (Get-Date)
        Save-WState
        $after = Test-ZAfterRestart
        Write-WLog ('После перезапуска: ' + (Format-ZProbeSummary -Scored $after)) INFO
        if ($after.controlsOk -and $after.score -ge 60) { return }
    } catch {
        Write-WLog ('Перезапуск не помог: ' + $_.Exception.Message) ERROR
    }
}

# Fallback profile: second best result from the last tuning run.
$fallbackPath = Join-Path $ZState 'fallback-profile.json'
$info = Get-ZInstalledInfo
if ((Test-Path -LiteralPath $fallbackPath) -and $info) {
    $fb = Get-Content -LiteralPath $fallbackPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($fb.id -and $fb.id -ne $info.profileId) {
        Write-WLog ("Переключаюсь на резервный профиль: {0}" -f $fb.id) WARN
        try {
            Apply-ZProfile -ProfileObject $fb | Out-Null
            $after = Test-ZAfterRestart
            Write-WLog ('После резервного профиля: ' + (Format-ZProbeSummary -Scored $after)) INFO
            if ($after.controlsOk -and $after.score -ge 60) { return }
        } catch {
            Write-WLog ('Резервный профиль не сработал: ' + $_.Exception.Message) ERROR
        }
    }
}

Write-WLog 'Автовосстановление не помогло. Требуется полный автотюнинг (Zapret.bat tune).' ERROR
