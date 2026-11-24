# ============================================================================
#  Zapret Ultimate - self-update from GitHub
#  Downloads only the code/config files over raw.githubusercontent.com (a few
#  hundred KB, GitHub release assets are throttled on some ISPs), validates
#  every PowerShell file, backs up the replaced files and applies the profile.
#  Binaries (bin\, yt-dlp.exe, ipset-all.txt) are never touched.
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
$rawBase = 'https://raw.githubusercontent.com/' + $repo + '/main/src'
$updateLog = Join-Path $ZLogs 'update.log'
$ProgressPreference = 'SilentlyContinue'

# Files that make up the program. Binaries and the big ipset are deliberately
# excluded: they never change between code releases and would make the update
# slow and fragile.
$updateFiles = @(
    'version.txt',
    'Zapret.ps1',
    'Zapret.bat',
    'Install.bat',
    'README.md',
    'КАК-УСТАНОВИТЬ.txt',
    'lib\common.ps1',
    'lib\engine.ps1',
    'lib\probe.ps1',
    'lib\browser.ps1',
    'tools\tune.ps1',
    'tools\watchdog.ps1',
    'tools\install.ps1',
    'tools\update.ps1',
    'tools\build-profiles.ps1',
    'tools\fix-encoding.cmd',
    'profiles\library.json',
    'config\targets.json',
    'config\settings.json',
    'lists\list-general.txt',
    'lists\list-general-user.txt',
    'lists\list-google.txt',
    'lists\list-exclude.txt',
    'lists\list-exclude-user.txt',
    'lists\ipset-exclude.txt',
    'lists\ipset-exclude-user.txt'
)

function Write-U {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
    Write-ZLog $Message INFO
    try { Add-Content -LiteralPath $updateLog -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}

# GitHub's raw CDN can serve a stale file for a while after a fresh publish,
# so the authoritative Contents API is used first; raw is only a fallback.
function Get-ZGitHubBytes {
    param([string]$RelPath, [int]$TimeoutSec = 60)
    $uri = 'https://api.github.com/repos/' + $repo + '/contents/src/' + ($RelPath.Replace('\', '/')) + '?ref=main'
    $json = (& curl.exe -fsSL --retry 2 --retry-delay 1 --max-time $TimeoutSec -H 'User-Agent: ZapretUltimate' $uri 2>$null) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $json) {
        try {
            $o = $json | ConvertFrom-Json
            if ($o.content) { return [Convert]::FromBase64String(($o.content -replace '\s', '')) }
        } catch { }
    }
    return $null
}

function Get-ZRemoteVersion {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    $bytes = Get-ZGitHubBytes -RelPath 'version.txt'
    if ($bytes) {
        $v = [Text.Encoding]::UTF8.GetString($bytes).Trim().TrimStart([char]0xFEFF)
        if ($v -match '^\d+\.\d+\.\d+$') { return $v }
    }
    try {
        $v = (Invoke-WebRequest -Uri ($rawBase + '/version.txt') -UseBasicParsing -TimeoutSec 20).Content.Trim().TrimStart([char]0xFEFF)
        if ($v -match '^\d+\.\d+\.\d+$') { return $v }
    } catch { }
    return $null
}

if (-not $Check) { Assert-ZAdmin }

$local = '0.0.0'
$versionFile = Join-Path $root 'version.txt'
if (Test-Path -LiteralPath $versionFile) {
    $v = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue).Trim().TrimStart([char]0xFEFF)
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
    Write-U 'Скачиваю файлы с GitHub...'
    foreach ($rel in $updateFiles) {
        $dst = Join-Path $tmp $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        $bytes = Get-ZGitHubBytes -RelPath $rel
        if ($bytes -and $bytes.Length -gt 0) {
            [IO.File]::WriteAllBytes($dst, $bytes)
        } else {
            # Fallback: raw CDN, which may lag behind the API after a publish.
            $uri = [Uri]::EscapeUriString($rawBase + '/' + $rel.Replace('\', '/'))
            & curl.exe -fsSL --retry 2 --retry-delay 1 --max-time 60 -o $dst $uri 2>$null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dst) -or (Get-Item -LiteralPath $dst).Length -eq 0) {
                throw ('Не удалось скачать ' + $rel)
            }
        }
    }
    $got = @(Get-ChildItem -LiteralPath $tmp -Recurse -File)
    if ($got.Count -lt ($updateFiles.Count - 1)) { throw ('Скачано только {0} из {1} файлов' -f $got.Count, $updateFiles.Count) }

    # The new main script and every library must parse before anything is replaced.
    foreach ($ps in @($got | Where-Object { $_.Extension -eq '.ps1' })) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($ps.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ('Новый файл ' + $ps.Name + ' не парсится: ' + $errors[0].Message) }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $ZState ('update-backup-' + $stamp)
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($rel in $updateFiles) {
        $cur = Join-Path $root $rel
        if (Test-Path -LiteralPath $cur) {
            $bd = Join-Path $backup $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bd) | Out-Null
            Copy-Item -LiteralPath $cur -Destination $bd -Force
        }
    }
    Write-U ('Бэкап заменяемых файлов: ' + $backup)

    foreach ($rel in $updateFiles) {
        $srcFile = Join-Path $tmp $rel
        $dstFile = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dstFile) | Out-Null
        $tmpDst = $dstFile + '.dsh-new'
        [IO.File]::WriteAllBytes($tmpDst, [IO.File]::ReadAllBytes($srcFile))
        Move-Item -LiteralPath $tmpDst -Destination $dstFile -Force
    }
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
