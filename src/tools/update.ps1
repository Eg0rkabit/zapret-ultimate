# ============================================================================
#  Zapret Ultimate - self-update from GitHub
#  Downloads the release ZIP, validates it, backs up the current package and
#  copies the new files over the installed folder. The current profile is
#  re-applied afterwards unless -NoApply is given.
# ============================================================================
param(
    [switch]$Check,
    [switch]$Quiet,
    [switch]$NoApply,
    [switch]$Force
)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')

$repo = 'Eg0rkabit/zapret-ultimate'
$versionUrl = 'https://raw.githubusercontent.com/' + $repo + '/main/src/version.txt'
$zipUrl = 'https://github.com/' + $repo + '/releases/latest/download/Zapret-Ultimate-Full.zip'
$updateLog = Join-Path $ZLogs 'update.log'

function Write-U {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
    Write-ZLog $Message INFO
    try { Add-Content -LiteralPath $updateLog -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}

function Get-ZRemoteVersion {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        $v = (Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -TimeoutSec 15).Content.Trim()
        if ($v -match '^\d+\.\d+\.\d+$') { return $v }
    } catch { }
    return $null
}

if (-not $Check) { Assert-ZAdmin }

$local = '0.0.0'
$versionFile = Join-Path $root 'version.txt'
if (Test-Path -LiteralPath $versionFile) {
    $v = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($v -match '^\d+\.\d+\.\d+$') { $local = $v }
}
Write-U ("Текущая версия: {0}" -f $local)

$remote = Get-ZRemoteVersion
if (-not $remote) {
    Write-U 'Не удалось узнать версию на GitHub (нет сети или репозиторий недоступен).' Yellow
    try { (Get-Date).ToString('o') | Set-Content -LiteralPath (Join-Path $ZState 'update-last.txt') -Encoding UTF8 } catch { }
    return
}
Write-U ("Версия на GitHub: {0}" -f $remote)

if (-not $Force -and ([version]$remote) -le ([version]$local)) {
    Write-U 'Обновление не требуется.' Green
    try { (Get-Date).ToString('o') | Set-Content -LiteralPath (Join-Path $ZState 'update-last.txt') -Encoding UTF8 } catch { }
    return
}
if ($Check) {
    Write-U 'Доступно обновление. Запустите: Zapret.bat update' Yellow
    return
}

$tmp = Join-Path $env:TEMP ('zapret-update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp 'pkg.zip'
    Write-U 'Скачиваю пакет с GitHub...'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 240
    $x = Join-Path $tmp 'x'
    Expand-Archive -LiteralPath $zip -DestinationPath $x -Force
    $pkg = Get-ChildItem -LiteralPath $x -Directory | Select-Object -First 1
    if (-not $pkg -or -not (Test-Path -LiteralPath (Join-Path $pkg.FullName 'Zapret.ps1'))) {
        throw 'Архив обновления повреждён: нет Zapret.ps1'
    }
    # Cheap sanity check: the new main script must at least parse.
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $pkg.FullName 'Zapret.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ('Новый Zapret.ps1 не парсится: ' + $errors[0].Message) }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $ZState ('update-backup-' + $stamp)
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    Write-U ('Сохраняю текущую версию в ' + $backup)
    $rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList @(
        ('"{0}"' -f $root), ('"{0}"' -f $backup),
        '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/XD', 'logs', 'state', '/R:1', '/W:1'
    ) -Wait -PassThru -WindowStyle Hidden
    if ($rc.ExitCode -ge 8) { throw ('Не удалось создать бэкап (robocopy ' + $rc.ExitCode + ')') }

    Write-U 'Копирую новые файлы...'
    $rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList @(
        ('"{0}"' -f $pkg.FullName), ('"{0}"' -f $root),
        '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/XD', 'logs', 'state', '/XF', '*.zip', '/R:1', '/W:1'
    ) -Wait -PassThru -WindowStyle Hidden
    if ($rc.ExitCode -ge 8) { throw ('robocopy завершился с кодом ' + $rc.ExitCode) }
    $enc = Join-Path $root 'tools\fix-encoding.cmd'
    if (Test-Path -LiteralPath $enc) { & $enc | Out-Null }
    Set-Content -LiteralPath $versionFile -Value $remote -Encoding ASCII
    Write-U ('Обновлено до версии ' + $remote + '. Бэкап: ' + $backup) Green

    if (-not $NoApply) {
        $info = Get-ZInstalledInfo
        if ($info -and $info.profileId) {
            Write-U ('Применяю профиль ' + $info.profileId + ' к обновлённой библиотеке...')
            & (Join-Path $root 'Zapret.ps1') apply $info.profileId | Out-Null
            Write-U 'Профиль применён.' Green
        }
    }
    try { ('updated ' + $remote + ' ' + (Get-Date).ToString('o')) | Set-Content -LiteralPath (Join-Path $ZState 'update-result.txt') -Encoding UTF8 } catch { }
} catch {
    Write-U ('Ошибка обновления: ' + $_.Exception.Message) Red
    try { ('failed ' + (Get-Date).ToString('o') + ': ' + $_.Exception.Message) | Set-Content -LiteralPath (Join-Path $ZState 'update-result.txt') -Encoding UTF8 } catch { }
} finally {
    try { (Get-Date).ToString('o') | Set-Content -LiteralPath (Join-Path $ZState 'update-last.txt') -Encoding UTF8 } catch { }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
