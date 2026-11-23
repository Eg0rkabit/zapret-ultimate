# ============================================================================
#  Zapret Ultimate - installer
#  Copies the package to C:\Zapret (stable path for the service), runs a quick
#  tuning pass, installs the service and the 5-minute watchdog task.
# ============================================================================
param([switch]$SkipTune, [switch]$SkipWatchdog)

$src = Split-Path -Parent $PSScriptRoot
$dest = 'C:\Zapret'

function Write-I { param([string]$m, [string]$c = 'Gray') Write-Host $m -ForegroundColor $c }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Нужны права администратора.'
}

Write-I '  ZAPRET ULTIMATE — установка' Cyan
Write-I '  ============================================================' DarkCyan

if ($src.TrimEnd('\') -ne $dest) {
    Write-I ("  Копирую программу в {0} ..." -f $dest) Gray
    # winws.exe is locked while the service runs - stop it before overwriting.
    $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-I '  Останавливаю службу перед обновлением файлов...' Gray
        & sc.exe stop zapret | Out-Null
        Start-Sleep -Seconds 2
        & taskkill.exe /IM winws.exe /F 2>$null | Out-Null
    }
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
    $rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList @(('"{0}"' -f $src), ('"{0}"' -f $dest), '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/R:1', '/W:1', '/XD', 'logs', 'state') -Wait -PassThru -WindowStyle Hidden
    if ($rc.ExitCode -ge 8) { throw ("robocopy завершился с кодом " + $rc.ExitCode) }
    foreach ($d in @('logs', 'state')) {
        $p = Join-Path $dest $d
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    }
    Write-I '  Скопировано.' Green
} else {
    Write-I '  Программа уже находится в C:\Zapret.' Green
}

$entry = Join-Path $dest 'Zapret.ps1'
if (-not (Test-Path -LiteralPath $entry)) { throw ('Не найден ' + $entry) }

if (-not $SkipTune) {
    Write-I ''
    Write-I '  Запускаю быстрый автотюнинг (2-4 минуты, служба будет кратко остановлена)...' Cyan
    $tuneOk = $false
    try {
        & $entry quick
        $tuneOk = $true
    } catch {
        Write-I ('  Автотюнинг завершился с ошибкой: ' + $_.Exception.Message) Red
    }
    $svcState = (Get-Service -Name 'zapret' -ErrorAction SilentlyContinue).Status
    if (-not $tuneOk -or $svcState -ne 'Running') {
        Write-I ('  ВНИМАНИЕ: служба в состоянии ' + $svcState + '. Смотрите logs\zapret.log') Yellow
    }
} else {
    & $entry start
}

# The "ts" fooling mode requires TCP timestamps (RFC 1323). Flowseal's bundle
# enables them too; remember the change so it can be reverted on uninstall.
try {
    $tcp = netsh interface tcp show global | Out-String
    if ($tcp -match 'Timestamps\s+:\s+disabled') {
        Write-I '  Включаю TCP timestamps (нужны для fooling=ts)...' Gray
        & netsh interface tcp set global timestamps=enabled | Out-Null
        $marker = Join-Path $dest 'state\timestamps-changed.json'
        ([ordered]@{ changedAt = (Get-Date).ToString('o'); previous = 'disabled' } | ConvertTo-Json) |
            Set-Content -LiteralPath $marker -Encoding UTF8
    }
} catch {
    Write-I ('  Не удалось проверить TCP timestamps: ' + $_.Exception.Message) Yellow
}

if (-not $SkipWatchdog) {
    $wd = Join-Path $dest 'tools\watchdog.ps1'
    $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $wd + '"'
    & schtasks.exe /Create /TN 'ZapretUltimate Watchdog' /TR $tr /SC MINUTE /MO 5 /RU 'SYSTEM' /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-I '  Задача автопроверки создана (каждые 5 минут).' Green }
    else { Write-I '  Не удалось создать задачу автопроверки.' Yellow }
}

# The folder is executed as SYSTEM by the watchdog and as admin by the service.
# Default C:\ ACLs let any authenticated user modify it, which would be a local
# privilege escalation, so lock it down: admins/SYSTEM full, users read-only.
try {
    & icacls.exe $dest /inheritance:r | Out-Null
    & icacls.exe $dest /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    & icacls.exe $dest /remove:g '*S-1-5-11' | Out-Null
    Write-I '  Права на папку ограничены (Administrators/SYSTEM — запись, Users — чтение).' Green
} catch {
    Write-I ('  Не удалось ограничить права на папку: ' + $_.Exception.Message) Yellow
}

Write-I ''
Write-I '  Готово. Запуск меню: C:\Zapret\Zapret.bat' Green
Write-I '  Статус: C:\Zapret\Zapret.bat status' DarkGray