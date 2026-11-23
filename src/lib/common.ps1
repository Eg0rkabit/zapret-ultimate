# ============================================================================
#  Zapret Ultimate - common library
#  Paths, logging, elevation, service helpers, state/backup
# ============================================================================
$ErrorActionPreference = 'Stop'

$script:ZRoot = Split-Path -Parent $PSScriptRoot
$script:ZBin = Join-Path $ZRoot 'bin'
$script:ZLists = Join-Path $ZRoot 'lists'
$script:ZConf = Join-Path $ZRoot 'config'
$script:ZLogs = Join-Path $ZRoot 'logs'
$script:ZState = Join-Path $ZRoot 'state'
$script:ZProfilesDir = Join-Path $ZRoot 'profiles'
$script:ZTools = Join-Path $ZRoot 'tools'
$script:ZServiceName = 'zapret'
$script:ZActiveConf = Join-Path $ZConf 'active.conf'

foreach ($d in @($ZConf, $ZLogs, $ZState)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

$script:ZLogFile = Join-Path $ZLogs 'zapret.log'

function Write-ZLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }
    try {
        # Rotate the log once it grows past 5 MB (keep one previous file).
        $fi = Get-Item -LiteralPath $ZLogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 5MB) { Move-Item -LiteralPath $ZLogFile -Destination ($ZLogFile + '.1') -Force -ErrorAction SilentlyContinue }
    } catch { }
    try { Add-Content -LiteralPath $ZLogFile -Value $line -Encoding UTF8 } catch { }
}

# Atomic JSON write: a power loss must not leave a half-written state file.
function Write-ZJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object,
        [int]$Depth = 10
    )
    $tmp = $Path + '.tmp'
    ($Object | ConvertTo-Json -Depth $Depth) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-ZAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-ZAdmin {
    if (-not (Test-ZAdmin)) { throw 'Требуются права администратора. Запустите Zapret.bat (UAC).' }
}

# Run another .ps1 elevated. The child writes $OutputFile itself if it needs to
# return data; returns $true when the child exits with code 0.
function Invoke-ZElevated {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArgs = @(),
        [int]$TimeoutSec = 900
    )
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath)) + $ScriptArgs
    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argsList -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return $false
    }
    return ($p.ExitCode -eq 0)
}

# ---------------------------------------------------------------- service ---
function Get-ZServiceState {
    $s = Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue
    if ($null -eq $s) { return 'NotInstalled' }
    return $s.Status.ToString()
}

function Get-ZServiceImagePath {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ZServiceName"
    if (-not (Test-Path $key)) { return $null }
    return (Get-ItemProperty -Path $key -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
}

function Wait-ZServiceState {
    param([string]$Wanted, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ZServiceState) -eq $Wanted) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return ((Get-ZServiceState) -eq $Wanted)
}

function Stop-ZService {
    $st = Get-ZServiceState
    if ($st -eq 'NotInstalled') { return }
    Write-ZLog "Останавливаю службу $ZServiceName (текущее состояние: $st)..." INFO
    & sc.exe stop $ZServiceName | Out-Null
    if (-not (Wait-ZServiceState -Wanted 'Stopped' -TimeoutSec 25)) {
        Write-ZLog 'Служба не остановилась штатно, завершаю winws.exe принудительно.' WARN
        & taskkill.exe /IM winws.exe /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 700
    }
}

function Start-ZService {
    if ((Get-ZServiceState) -eq 'NotInstalled') { throw "Служба $ZServiceName не установлена." }
    Write-ZLog "Запускаю службу $ZServiceName..." INFO
    & sc.exe start $ZServiceName | Out-Null
    if (-not (Wait-ZServiceState -Wanted 'Running' -TimeoutSec 20)) {
        throw 'Служба не перешла в состояние Running.'
    }
}

function Restart-ZService {
    Stop-ZService
    Start-Sleep -Milliseconds 500
    Start-ZService
}

# ------------------------------------------------------------ winws procs ---
function Get-ZWinwsProcesses {
    # Only processes started from our own bin directory are ours. Another
    # zapret installation must not be killed by accident.
    $list = @()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue)) {
        $path = $p.ExecutablePath
        if (-not $path -or $path -like (Join-Path $ZBin '*')) {
            $list += [pscustomobject]@{ Id = [int]$p.ProcessId; Path = $path }
        }
    }
    return $list
}

function Stop-ZWinwsAll {
    $procs = @(Get-ZWinwsProcesses)
    if ($procs.Count -eq 0) { return }
    Write-ZLog "Завершаю $($procs.Count) процесс(ов) winws.exe..." DEBUG
    $procs | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { } }
    Start-Sleep -Milliseconds 600
    if (@(Get-ZWinwsProcesses).Count -gt 0) {
        foreach ($p in Get-ZWinwsProcesses) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Milliseconds 600
    }
}

# ------------------------------------------------------------- operation ---
# A named lock serialises tuning, installation and the watchdog. Without it the
# watchdog can start the service in the middle of a tuning pass and corrupt it.
function Enter-ZLock {
    param([string]$Name = 'operation', [int]$StaleMinutes = 45)
    $path = Join-Path $ZState ($Name + '.lock')
    if (Test-Path -LiteralPath $path) {
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime
            if ($age.TotalMinutes -lt $StaleMinutes) { return $false }
            Write-ZLog ("Снимаю просроченный lock {0} (возраст {1:N0} мин)." -f $Name, $age.TotalMinutes) WARN
        } catch { }
    }
    $info = '{0}|{1}|{2}' -f $PID, (Get-Date).ToString('o'), $Name
    Set-Content -LiteralPath $path -Value $info -Encoding UTF8
    return $true
}

function Exit-ZLock {
    param([string]$Name = 'operation')
    $path = Join-Path $ZState ($Name + '.lock')
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Test-ZLock {
    param([string]$Name = 'operation', [int]$StaleMinutes = 45)
    $path = Join-Path $ZState ($Name + '.lock')
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $age = (Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime
        return ($age.TotalMinutes -lt $StaleMinutes)
    } catch { return $false }
}

# ------------------------------------------------------------------ state ---
function Save-ZServiceBackup {
    $path = Join-Path $ZState 'service-backup.json'
    if (Test-Path -LiteralPath $path) { return }   # keep the very first backup
    $img = Get-ZServiceImagePath
    $svc = Get-Service -Name $ZServiceName -ErrorAction SilentlyContinue
    $obj = [ordered]@{
        existed     = ($null -ne $svc)
        imagePath   = $img
        displayName = $(if ($svc) { $svc.DisplayName } else { 'zapret' })
        startType   = $(if ($svc) { $svc.StartType.ToString() } else { 'Automatic' })
        backupTime  = (Get-Date).ToString('o')
    }
    Write-ZJson -Path $path -Object $obj -Depth 5
    if ($obj.existed) { Write-ZLog 'Резервная копия конфигурации старой службы сохранена.' OK }
}

function Get-ZServiceBackup {
    $path = Join-Path $ZState 'service-backup.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-ZInstalledInfo {
    param([string]$ProfileId, [string]$ProfileName)
    $obj = [ordered]@{
        version     = '1.0'
        profileId   = $ProfileId
        profileName = $ProfileName
        installedAt = (Get-Date).ToString('o')
        root        = $ZRoot
    }
    Write-ZJson -Path (Join-Path $ZState 'installed.json') -Object $obj -Depth 5
}

function Get-ZInstalledInfo {
    $p = Join-Path $ZState 'installed.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Clear-ZInstalledInfo {
    Remove-Item -LiteralPath (Join-Path $ZState 'installed.json') -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ misc ----
function Test-ZPortTcp {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

function Format-ZDuration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "$Seconds сек" }
    return ('{0} мин {1} сек' -f [int][math]::Floor($Seconds / 60), ($Seconds % 60))
}

function Read-ZPause {
    Read-Host '  Нажмите Enter для продолжения' | Out-Null
}

# ---------------------------------------------------------------------------
#  Console appearance.
#  Fresh cmd windows on some systems fall back to the raster "Terminal" font,
#  which simply has no Cyrillic glyphs: Russian menu items render as blanks.
#  Force a TrueType font for the current window and for future console windows.
# ---------------------------------------------------------------------------
function Initialize-ZConsole {
    # Font work needs Add-Type (~300 ms). Skip it for non-interactive runs
    # (watchdog, tuning, redirected output) where there is no console window.
    $interactive = $false
    try { $interactive = ($Host.Name -eq 'ConsoleHost') -and (-not [Console]::IsOutputRedirected) } catch { }
    if ($interactive) {
    try {
        if (-not ('ZapretConsole' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ZapretConsole {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFO_EX {
        public uint cbSize; public uint nFont; public short dwFontSizeX; public short dwFontSizeY;
        public int FontFamily; public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref CONSOLE_FONT_INFO_EX e);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref CONSOLE_FONT_INFO_EX e);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    public static string GetFace() {
        var e = new CONSOLE_FONT_INFO_EX();
        e.cbSize = (uint)Marshal.SizeOf(e);
        GetCurrentConsoleFontEx(GetStdHandle(-11), false, ref e);
        return e.FaceName;
    }
    public static bool SetFont(string face, short size) {
        var e = new CONSOLE_FONT_INFO_EX();
        e.cbSize = (uint)Marshal.SizeOf(e);
        e.nFont = 0; e.dwFontSizeX = 0; e.dwFontSizeY = size;
        e.FontFamily = 54; e.FontWeight = 400; e.FaceName = face;
        return SetCurrentConsoleFontEx(GetStdHandle(-11), false, ref e);
    }
}
'@
        }
        # The raster "Terminal" font has no Cyrillic glyphs at all. Only replace
        # it; a TrueType font chosen by the user is left alone.
        $face = ''
        try { $face = [ZapretConsole]::GetFace() } catch { }
        if ([string]::IsNullOrEmpty($face) -or $face -eq 'Terminal') {
            [void][ZapretConsole]::SetFont('Consolas', 18)
        }
    } catch { }
    }

    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    try { $global:OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}
