# ============================================================================
#  Zapret Ultimate - winws engine
#  Config generation, process control, Windows service install/restore.
# ============================================================================
$ZRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

function Expand-ZWinwsArgs {
    param([string[]]$Arguments)
    $out = @()
    foreach ($a in $Arguments) {
        $out += $a.Replace('{BIN}', $ZBin).Replace('{LISTS}', $ZLists)
    }
    return $out
}

function Write-ZWinwsConfig {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $expanded = Expand-ZWinwsArgs -Arguments $Arguments
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $text = ($expanded -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
    return $expanded
}

function Test-ZWinwsConfig {
    param([Parameter(Mandatory = $true)][string]$Path)
    # winws writes its diagnostics to stderr; with ErrorActionPreference=Stop a
    # merged 2>&1 stream would abort the script, so relax it locally.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & (Join-Path $ZBin 'winws.exe') --dry-run "@$Path" 2>&1
        $code = $LASTEXITCODE
        $text = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    } finally {
        $ErrorActionPreference = $oldEap
    }
    # --dry-run also refuses to run when the same filter is already active.
    # That is not a configuration error.
    $sameFilter = $text -match 'already running with the same filter'
    return [pscustomobject]@{ ok = ($code -eq 0 -or $sameFilter); output = $text }
}

function Start-ZWinwsProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$LogPath = (Join-Path $ZLogs 'winws-stdout.log')
    )
    $exe = Join-Path $ZBin 'winws.exe'
    $p = Start-Process -FilePath $exe -ArgumentList @("@$ConfigPath") -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath + '.err')
    Start-Sleep -Milliseconds 1300
    if ($p.HasExited) {
        $err = ''
        foreach ($f in @($LogPath + '.err', $LogPath)) {
            if (Test-Path -LiteralPath $f) { $err += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
        }
        throw ("winws.exe завершился с кодом {0}. {1}" -f $p.ExitCode, $err.Trim())
    }
    return $p
}

function Stop-ZWinwsProcess {
    param($Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction Stop }
    } catch { }
    Start-Sleep -Milliseconds 500
}

# Start winws with a config, run the supplied probe script block, always stop.
function Invoke-ZWinwsSession {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    $p = $null
    try {
        $p = Start-ZWinwsProcess -ConfigPath $ConfigPath
        $result = & $Action
        return $result
    } finally {
        Stop-ZWinwsProcess -Process $p
    }
}

# --------------------------------------------------------------- service ----
function Get-ZInlineArgLine {
    param([string[]]$Arguments)
    $expanded = Expand-ZWinwsArgs -Arguments $Arguments
    $parts = foreach ($a in $expanded) {
        if ($a -match '\s') { '"' + $a + '"' } else { $a }
    }
    return ($parts -join ' ')
}

function Get-ZExeFromImagePath {
    param([string]$ImagePath)
    if (-not $ImagePath) { return $null }
    if ($ImagePath -match '^\s*"([^"]+)"') { return $Matches[1] }
    if ($ImagePath -match '^\s*(.+?\.exe)(?:\s|$)') { return $Matches[1] }
    return ($ImagePath -split '\s+')[0]
}

# Recreates the service from a raw ImagePath (used for rollback and restore).
function Install-ZServiceByImagePath {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [string]$DisplayName = 'zapret',
        [string]$StartType = 'Automatic'
    )
    $exe = Get-ZExeFromImagePath -ImagePath $ImagePath
    if (-not (Test-Path -LiteralPath $exe)) { throw ("Файл не найден: " + $exe) }
    Stop-ZService
    Stop-ZWinwsAll
    $existing = Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        & sc.exe delete $ZServiceName | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            if (-not (Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue)) { break }
        }
    }
    $mode = 'Automatic'
    if ($StartType -match 'Manual') { $mode = 'Manual' }
    if ($StartType -match 'Disabled') { $mode = 'Disabled' }
    New-Service -Name $ZServiceName -BinaryPathName $ImagePath -DisplayName $DisplayName -StartupType $mode | Out-Null
    & sc.exe description $ZServiceName 'Zapret DPI bypass software' | Out-Null
    if ($mode -ne 'Disabled') { Start-ZService }
}

function Install-ZService {
    param(
        [string]$ConfigPath,
        [string[]]$Arguments,
        [string]$DisplayName = 'zapret'
    )
    Assert-ZAdmin
    $exe = Join-Path $ZBin 'winws.exe'
    if (-not $Arguments) {
        if (-not $ConfigPath) { throw 'Нужны Arguments или ConfigPath.' }
        $Arguments = @(Get-Content -LiteralPath $ConfigPath -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
    }
    # winws service mode does not accept "@config" as its only argument, so the
    # service is always created with the full inline argument list.
    $argLine = Get-ZInlineArgLine -Arguments $Arguments
    $binPath = '"{0}" {1}' -f $exe, $argLine

    Save-ZServiceBackup
    $previousImage = Get-ZServiceImagePath
    Stop-ZService
    Stop-ZWinwsAll

    $existing = Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        & sc.exe delete $ZServiceName | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            if (-not (Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue)) { break }
        }
    }

    try {
        $created = $false
        try {
            New-Service -Name $ZServiceName -BinaryPathName $binPath -DisplayName $DisplayName -StartupType Automatic -ErrorAction Stop | Out-Null
            $created = $true
        } catch {
            Write-ZLog ("New-Service не сработал ({0}), пробую sc.exe create" -f $_.Exception.Message) WARN
        }
        if (-not $created) {
            # sc.exe requires "name=" and the value as SEPARATE arguments.
            & sc.exe create $ZServiceName 'binPath=' $binPath 'DisplayName=' $DisplayName 'start=' 'auto' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ("sc.exe create завершился с кодом " + $LASTEXITCODE) }
        }
        & sc.exe description $ZServiceName 'Zapret DPI bypass software (Zapret Ultimate)' | Out-Null
        # Restart automatically if winws dies.
        & sc.exe failure $ZServiceName 'reset=' '86400' 'actions=' 'restart/3000/restart/3000/restart/3000' | Out-Null
        & sc.exe failureflag $ZServiceName '1' | Out-Null

        Start-ZService
        Start-Sleep -Milliseconds 1200
        if ((Get-ZServiceState) -ne 'Running') { throw 'Служба создана, но не запустилась.' }
        if (-not (Test-ZWinwsRunning)) { throw 'Служба запущена, но процесс winws.exe отсутствует.' }
    } catch {
        $failMsg = $_.Exception.Message
        Write-ZLog ('Не удалось установить службу: ' + $failMsg) ERROR
        if ($previousImage) {
            try {
                Install-ZServiceByImagePath -ImagePath $previousImage
                Write-ZLog 'Предыдущая конфигурация службы восстановлена.' WARN
            } catch {
                Write-ZLog ('Откат службы не удался: ' + $_.Exception.Message) ERROR
            }
        }
        throw
    }
    Write-ZLog 'Служба zapret установлена и запущена.' OK
}

function Restore-ZOriginalService {
    Assert-ZAdmin
    $b = Get-ZServiceBackup
    if ($null -eq $b) { throw 'Резервная копия службы не найдена.' }
    if ($b.existed) {
        $exe = Get-ZExeFromImagePath -ImagePath ([string]$b.imagePath)
        if (-not (Test-Path -LiteralPath $exe)) {
            throw ('Исходный winws.exe больше не существует: {0}. Служба не тронута. Установите профиль заново: Zapret.bat tune' -f $exe)
        }
    }
    Stop-ZService
    Stop-ZWinwsAll
    $existing = Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        & sc.exe delete $ZServiceName | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            if (-not (Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue)) { break }
        }
    }
    if (-not $b.existed) {
        Clear-ZInstalledInfo
        Write-ZLog 'До установки службы не было — возвращаю систему в исходное состояние (без службы).' OK
        return
    }
    $display = 'zapret'
    if ($b.PSObject.Properties.Name -contains 'displayName' -and $b.displayName) { $display = $b.displayName }
    $start = 'Automatic'
    if ($b.PSObject.Properties.Name -contains 'startType' -and $b.startType) { $start = $b.startType }
    Install-ZServiceByImagePath -ImagePath $b.imagePath -DisplayName $display -StartType $start
    Clear-ZInstalledInfo
    Write-ZLog 'Исходная служба восстановлена.' OK
}

function Get-ZServiceCommandLine {
    $img = Get-ZServiceImagePath
    if (-not $img) { return $null }
    return $img
}

# Applies a profile file (json) to the live service.
function Apply-ZProfile {
    param(
        [string]$ProfilePath,
        [object]$ProfileObject,
        [switch]$NoRestart
    )
    $profile = $ProfileObject
    if ($null -eq $profile) {
        if (-not $ProfilePath) { throw 'Нужен ProfilePath или ProfileObject.' }
        $profile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    Write-ZWinwsConfig -Arguments $profile.args -Path $ZActiveConf | Out-Null
    $check = Test-ZWinwsConfig -Path $ZActiveConf
    if (-not $check.ok) { throw ("Конфигурация не прошла проверку: " + $check.output) }

    # Nothing to do if the very same command line is already running.
    $newBinPath = '"{0}" {1}' -f (Join-Path $ZBin 'winws.exe'), (Get-ZInlineArgLine -Arguments $profile.args)
    $curBinPath = Get-ZServiceImagePath
    if ($curBinPath -and $curBinPath.Trim() -eq $newBinPath.Trim() -and (Get-ZServiceState) -eq 'Running' -and (Test-ZWinwsRunning)) {
        Save-ZInstalledInfo -ProfileId $profile.id -ProfileName $profile.name
        Write-ZLog ("Профиль {0} уже активен, перезапуск не требуется." -f $profile.id) OK
        return $profile
    }

    Install-ZService -ConfigPath $ZActiveConf -Arguments $profile.args
    Save-ZInstalledInfo -ProfileId $profile.id -ProfileName $profile.name
    Write-ZLog ("Применён профиль: {0} ({1})" -f $profile.name, $profile.id) OK
    return $profile
}
