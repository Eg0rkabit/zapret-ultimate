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
        Write-ZLog 'Служба не остановилась штатно, завершаю только свои winws.exe.' WARN
        Stop-ZWinwsAll
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
    # Every winws.exe on the machine. Path is empty when the caller is not
    # allowed to read ExecutablePath (a non-elevated query of a SYSTEM process).
    $list = @()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue)) {
        $list += [pscustomobject]@{ Id = [int]$p.ProcessId; Path = $p.ExecutablePath }
    }
    return $list
}

function Get-ZOwnWinwsProcesses {
    # Only processes started from our own bin directory are ours. A process
    # whose path cannot be read is never treated as ours: killing it could hit
    # another zapret installation.
    return @(Get-ZWinwsProcesses | Where-Object { $_.Path -and $_.Path -like (Join-Path $ZBin '*') })
}

function Test-ZWinwsRunning {
    $all = @(Get-ZWinwsProcesses)
    if ($all.Count -eq 0) { return $false }
    if (@(Get-ZOwnWinwsProcesses).Count -gt 0) { return $true }
    # Without elevation ExecutablePath is unreadable for SYSTEM-owned
    # processes; a single unreadable winws is our service.
    return ($all.Count -eq 1 -and -not $all[0].Path)
}

function Stop-ZWinwsAll {
    $all = @(Get-ZWinwsProcesses)
    if ($all.Count -eq 0) { return }
    $procs = @(Get-ZOwnWinwsProcesses)
    $foreign = @($all | Where-Object { $_.Path -and $_.Path -notlike (Join-Path $ZBin '*') })
    $unknown = @($all | Where-Object { -not $_.Path })
    if ($foreign.Count -gt 0) {
        Write-ZLog ('Не трогаю чужие winws.exe: {0}' -f (($foreign | ForEach-Object { $_.Path }) -join '; ')) WARN
    }
    if ($procs.Count -eq 0) {
        if ($unknown.Count -gt 0) {
            Write-ZLog ('Не могу определить путь {0} процесс(ов) winws.exe — не завершаю их.' -f $unknown.Count) WARN
        }
        return
    }
    Write-ZLog "Завершаю $($procs.Count) процесс(ов) winws.exe..." DEBUG
    $procs | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { } }
    Start-Sleep -Milliseconds 600
    $left = @(Get-ZOwnWinwsProcesses)
    if ($left.Count -gt 0) {
        foreach ($p in $left) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Milliseconds 600
    }
}

# ------------------------------------------------------------- operation ---
# A named lock serialises tuning, installation and the watchdog. Without it the
# watchdog can start the service in the middle of a tuning pass and corrupt it.
# File format: "PID|ISO-time|operation". The PID is checked before the lock is
# considered alive, so a killed tune cannot block the watchdog for an hour.
function Get-ZLockData {
    param([string]$Name = 'operation')
    $path = Join-Path $ZState ($Name + '.lock')
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = ''
    try { $raw = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim() } catch { }
    $age = [double]::MaxValue
    try { $age = ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalMinutes } catch { }
    $ownerPid = 0
    $stamp = [datetime]::MinValue
    $parts = @($raw -split '\|')
    if ($parts.Count -ge 1) { [void][int]::TryParse($parts[0], [ref]$ownerPid) }
    if ($parts.Count -ge 2) { [void][datetime]::TryParse($parts[1], [ref]$stamp) }
    return [pscustomobject]@{
        Path       = $path
        Raw        = $raw
        Pid        = $ownerPid
        Stamp      = $(if ($stamp -ne [datetime]::MinValue) { $stamp } else { $null })
        AgeMinutes = $age
    }
}

function Test-ZLockOwnerAlive {
    param([int]$OwnerPid)
    if ($OwnerPid -le 0) { return $false }
    try { return [bool](Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue) } catch { return $false }
}

function Enter-ZLock {
    param([string]$Name = 'operation', [int]$StaleMinutes = 20)
    $path = Join-Path $ZState ($Name + '.lock')
    if (Test-Path -LiteralPath $path) {
        $d = Get-ZLockData -Name $Name
        $ownerAlive = ($d -and $d.Pid -gt 0 -and (Test-ZLockOwnerAlive -OwnerPid $d.Pid))
        $freshUnknown = ($d -and $d.Pid -le 0 -and $d.AgeMinutes -lt $StaleMinutes)
        if ($ownerAlive -or $freshUnknown) { return $false }
        Write-ZLog ("Снимаю просроченный lock {0} (PID {1}, возраст {2:N0} мин)." -f $Name, $(if ($d) { $d.Pid } else { '?' }), $(if ($d) { $d.AgeMinutes } else { 0 })) WARN
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $info = '{0}|{1}|{2}' -f $PID, (Get-Date).ToString('o'), $Name
    try {
        # CreateNew is atomic: two concurrent processes cannot both win.
        $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
        } finally { $fs.Close() }
        return $true
    } catch [IO.IOException] {
        Write-ZLog ("Lock {0} только что занял другой процесс." -f $Name) WARN
        return $false
    } catch {
        Write-ZLog ("Не удалось создать lock {0}: {1}" -f $Name, $_.Exception.Message) ERROR
        return $false
    }
}

function Exit-ZLock {
    param([string]$Name = 'operation')
    $path = Join-Path $ZState ($Name + '.lock')
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Test-ZLock {
    param([string]$Name = 'operation', [int]$StaleMinutes = 20)
    $d = Get-ZLockData -Name $Name
    if ($null -eq $d) { return $false }
    # A lock whose owner process is gone is stale immediately: every stage of
    # tune/watchdog writes its own PID, and none of them outlives its process.
    if ($d.Pid -gt 0) { return (Test-ZLockOwnerAlive -OwnerPid $d.Pid) }
    return ($d.AgeMinutes -lt $StaleMinutes)
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

# ------------------------------------------------------------------- ACL ----
# The watchdog task runs scripts from this folder as SYSTEM, so a folder that
# ordinary users can write to is a local privilege escalation. These helpers
# apply and verify the hardening that README promises.
function Get-ZAclWeakAces {
    param([string]$Path = $ZRoot)
    $weak = @()
    try {
        $acl = Get-Acl -LiteralPath $Path
        # Authenticated Users, Everyone, Users. Compare SIDs: names are localized.
        $unprivileged = @('S-1-5-11', 'S-1-1-0', 'S-1-5-32-545')
        # Only rights that let a user change the files. FullControl/Modify are
        # composites that also contain read bits, so testing them directly would
        # flag harmless read-only grants.
        $dangerousParts = @(
            [int64][Security.AccessControl.FileSystemRights]::Write,
            [int64][Security.AccessControl.FileSystemRights]::Delete,
            [int64][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
            [int64][Security.AccessControl.FileSystemRights]::ChangePermissions,
            [int64][Security.AccessControl.FileSystemRights]::TakeOwnership,
            [int64]0x40000000,   # GENERIC_WRITE
            [int64]0x10000000    # GENERIC_ALL
        )
        $dangerous = [int64]0
        foreach ($part in $dangerousParts) { $dangerous = $dangerous -bor $part }
        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne 'Allow') { continue }
            $sid = $null
            try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
            if (-not $sid -or ($unprivileged -notcontains $sid)) { continue }
            if (([int64]$ace.FileSystemRights -band $dangerous) -ne 0) {
                $weak += [pscustomobject]@{
                    Identity  = $ace.IdentityReference.Value
                    Sid       = $sid
                    Rights    = $ace.FileSystemRights.ToString()
                    Inherited = $ace.IsInherited
                }
            }
        }
    } catch { }
    return $weak
}

function Test-ZRootAcl {
    param([string]$Path = $ZRoot)
    return (@(Get-ZAclWeakAces -Path $Path).Count -eq 0)
}

function Set-ZRootAcl {
    param([string]$Path = $ZRoot)
    Assert-ZAdmin
    $admins = '*S-1-5-32-544:(OI)(CI)F'
    $system = '*S-1-5-18:(OI)(CI)F'
    $users = '*S-1-5-32-545:(OI)(CI)RX'
    # Drop the permissive ACEs inherited from C:\ and grant only what is needed.
    # /remove:g is best-effort: inherited entries are already gone by then.
    & icacls.exe $Path '/inheritance:r' '/grant:r' $admins $system $users '/remove:g' '*S-1-5-11' '*S-1-1-0' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & icacls.exe $Path '/inheritance:r' '/grant:r' $admins $system $users | Out-Null
    }
    $weak = @(Get-ZAclWeakAces -Path $Path)
    if ($weak.Count -gt 0) {
        $summary = ($weak | ForEach-Object { $_.Identity + '=' + $_.Rights }) -join '; '
        throw ("Права на {0} не удалось ограничить: {1}" -f $Path, $summary)
    }
    Write-ZLog ('Права на {0} ограничены: Administrators/SYSTEM — запись, Users — чтение.' -f $Path) OK
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
