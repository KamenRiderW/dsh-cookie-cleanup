#requires -Version 5.1
<#
.SYNOPSIS
  Clean the stale dsh-auth-* cookies that DSH Desktop accumulates on every launch.

.DESCRIPTION
  DSH Desktop starts its local host with "--port 0" (a random free port).  The
  host names its browser-session cookie after the request authority, so every
  launch creates a new "dsh-auth-<hash>" cookie for 127.0.0.1.  Each cookie is
  kept for 30 days and the shell never deletes old ones.  Chromium sends every
  cookie for the host, and Node's HTTP server rejects a request whose header is
  larger than 16 KiB, which is reached at roughly 72 launches.

  This script removes those leftover cookies while the Desktop app is closed.
  It only deletes rows whose name starts with "dsh-auth-".  The cookies are
  per-launch browser credentials, not the DeepSeek account token, so removing
  them does not sign you out.  A consistent SQLite backup is written first.

.PARAMETER DbPath
  Clean this cookie database instead of auto-detecting the Desktop profile.
  Useful together with -SkipProcessCheck on a copy for testing.

.PARAMETER UserDataDir
  Use this DSH user-data directory instead of the default
  %APPDATA%\@deepseek-ai\dsh-desktop path.

.PARAMETER AllProfiles
  Also clean the "Partitions\*\Network\Cookies" databases of the Desktop profile.

.PARAMETER DryRun
  Report what would be deleted, but change nothing.

.PARAMETER ReportOnly
  Same as -DryRun.

.PARAMETER KeepLatest
  Keep the N most recently used dsh-auth-* cookies.  Default 0 (delete all).

.PARAMETER BackupRoot
  Root directory for backup folders.  Default: <script>\backups.

.PARAMETER KeepBackups
  Number of normal backup folders to keep.  0 keeps all.  Default 30.

.PARAMETER KeepPreRestore
  Number of pre-restore snapshots to keep, counted separately.  0 keeps all.
  Default 5.

.PARAMETER LogPath
  Log file path.  Default: <script>\logs\cleanup.log.

.PARAMETER Quiet
  Suppress console output; the log file is still written.

.PARAMETER SkipProcessCheck
  Do not check whether DeepSeek Harness is running.  Intended for tests and
  copies of the database.

.PARAMETER IfRunning
  What to do when DeepSeek Harness is still running: Fail (default), Skip, Wait.

.PARAMETER WaitSeconds
  How long -IfRunning Wait waits for the app to exit.  0 waits forever.

.PARAMETER StartApp
  Start DeepSeek Harness after a successful cleanup (used by the launcher).
  When the cleanup is skipped or fails, the app is not started; pass -ForceStart
  to start it anyway.

.PARAMETER ForceStart
  With -StartApp, start the app even when the cleanup was skipped or failed.

.PARAMETER CheckPython
  Run a one-time `python -c "import sqlite3"` preflight.  Off by default because
  the DSH Python can take seconds to cold-start; without it, a broken Python is
  reported by the first real call together with its path and stderr.

.PARAMETER KillApp
  Force-stop every DeepSeek Harness process before cleaning.  Use this to
  recover from a 431 crash loop, where the shell keeps restarting its host and
  keeps the cookie database locked.  This can interrupt in-flight work.

.PARAMETER AppExe
  Path to DeepSeek Harness.exe for -StartApp.  An explicitly supplied path
  that does not exist is an error.

.PARAMETER AppProcessName
  Process name to watch.  Matched literally; wildcard characters are escaped.

.PARAMETER HeartbeatMinutes
  In -Watch mode, also check every N minutes while the app is not running and
  clean when more than HeartbeatThreshold dsh-auth-* cookies are present.
  Default 10; 0 disables the heartbeat.

.PARAMETER HeartbeatThreshold
  The heartbeat only cleans above this many dsh-auth-* rows.  Default 5.

.PARAMETER Restore
  Restore a backup folder produced by this script.  Requires -DbPath.

.PARAMETER Watch
  Stay in the background, wait for DeepSeek Harness to exit, clean, and repeat.
  Intended for the logon scheduled task installed by install-task.ps1.

.PARAMETER WatchMinutes
  Stop the watcher after this many minutes.  0 means forever (the installer uses
  0 for the logon task).

.PARAMETER PollSeconds
  Process poll interval in Watch mode.  Must be >= 1.

.EXAMPLE
  .\cleanup.ps1
  .\cleanup.ps1 -DryRun
  .\cleanup.ps1 -Watch -Quiet
  .\cleanup.ps1 -Restore .\backups\Cookies-20261112-113000 -DbPath 'C:\...\Cookies'
#>
[CmdletBinding()]
param(
    [string]$DbPath,
    [string]$UserDataDir,
    [switch]$AllProfiles,
    [switch]$DryRun,
    [switch]$ReportOnly,
    [int]$KeepLatest = 0,
    [ValidateSet('Fail', 'Skip', 'Wait')]
    [string]$IfRunning = 'Fail',
    [int]$WaitSeconds = 300,
    [string]$BackupRoot,
    [int]$KeepBackups = 30,
    [int]$KeepPreRestore = 5,
    [string]$LogPath,
    [switch]$Quiet,
    [switch]$SkipProcessCheck,
    [switch]$StartApp,
    [switch]$ForceStart,
    [switch]$CheckPython,
    [switch]$KillApp,
    [string]$AppExe,
    [string]$AppProcessName = 'DeepSeek Harness',
    [string]$Restore,
    [switch]$Watch,
    [int]$WatchMinutes = 0,
    [int]$PollSeconds = 5,
    [int]$HeartbeatMinutes = 10,
    [int]$HeartbeatThreshold = 5
)

$ErrorActionPreference = 'Stop'
$script:Quiet = [bool]$Quiet
$script:Python = $null
$script:LogFile = $null
$script:WatchMutex = $null
$script:RestorePrePath = $null
$script:LastCookieReadError = $null
$script:ScriptPath = $MyInvocation.MyCommand.Path
if (-not $script:ScriptPath) { $script:ScriptPath = $PSCommandPath }
$script:ScriptDir = Split-Path -Parent $script:ScriptPath
$script:PyScript = Join-Path $script:ScriptDir 'cleanup_db.py'

try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
} catch { }

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]
        [string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $script:Quiet) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'OK'    { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line }
        }
    }
    if ($script:LogFile) {
        try {
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $enc)
        } catch { }
    }
}

function Initialize-Log {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:ScriptDir 'logs\cleanup.log' }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $rotatedTo = $null
        if ($dir -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $logItem = Get-Item -LiteralPath $Path
            if ($logItem.Length -gt 5MB) {
                $rotatedTo = Join-Path $dir ('cleanup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                try {
                    Move-Item -LiteralPath $Path -Destination $rotatedTo -Force
                    Get-ChildItem -LiteralPath $dir -Filter 'cleanup-*.log' -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^cleanup-\d{8}-\d{6}\.log$' } |
                        Sort-Object Name -Descending |
                        Select-Object -Skip 5 |
                        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                } catch {
                    $rotatedTo = $null
                }
            }
        }
        # Windows PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI, so make
        # sure the log starts with a BOM once; later appends stay BOM-less.
        $bom = New-Object System.Text.UTF8Encoding($true)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            if (-not $hasBom) {
                $existing = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
                [System.IO.File]::WriteAllText($Path, $existing, $bom)
            }
        } else {
            [System.IO.File]::WriteAllText($Path, '', $bom)
        }
        $script:LogFile = $Path
        if ($rotatedTo) {
            Write-Log ('日志已轮转到 {0}' -f $rotatedTo) 'INFO'
        }
    } catch {
        # A read-only install directory must not break the cleanup itself.
        $fallback = Join-Path $env:LOCALAPPDATA 'dsh-cookie-cleanup\cleanup.log'
        try {
            $dir = Split-Path -Parent $fallback
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $fallbackBom = New-Object System.Text.UTF8Encoding($true)
            if (Test-Path -LiteralPath $fallback -PathType Leaf) {
                $existing = [System.IO.File]::ReadAllText($fallback, [System.Text.Encoding]::UTF8)
                [System.IO.File]::WriteAllText($fallback, $existing, $fallbackBom)
            } else {
                [System.IO.File]::WriteAllText($fallback, '', $fallbackBom)
            }
            $script:LogFile = $fallback
        } catch {
            $script:LogFile = $null
        }
    }
}

function Resolve-Python {
    $candidates = @()
    if ($env:DSH_COOKIE_CLEANUP_PYTHON) { $candidates += $env:DSH_COOKIE_CLEANUP_PYTHON }
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe')
    }
    foreach ($candidate in $candidates) {
        # The Microsoft Store alias under WindowsApps is a stub, not a Python.
        if ($candidate -match '(?i)\\WindowsApps\\') { continue }
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    foreach ($name in @('python.exe', 'python', 'python3.exe', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd -or -not $cmd.Source) { continue }
        if ($cmd.Source -match '(?i)\\WindowsApps\\') { continue }
        return $cmd.Source
    }
    $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($py -and $py.Source -and $py.Source -notmatch '(?i)\\WindowsApps\\') {
        return $py.Source
    }
    return $null
}

function Invoke-PythonCapture {
    param([string[]]$Arguments)
    # Native stderr is converted to ErrorRecord objects by 2>&1.  With the
    # script-wide ErrorActionPreference=Stop that becomes a terminating error
    # and skips every diagnostic branch below, so keep this call non-terminating.
    $savedPreference = $ErrorActionPreference
    $savedEncoding = $env:PYTHONIOENCODING
    $ErrorActionPreference = 'Continue'
    $output = @()
    $exitCode = -1
    try {
        $output = @(& $script:Python @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $output = @($_)
        $exitCode = -1
    } finally {
        if ($null -eq $savedEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        } else {
            $env:PYTHONIOENCODING = $savedEncoding
        }
        $ErrorActionPreference = $savedPreference
    }
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
}

function Assert-Python {
    if (-not $script:Python) { throw '找不到可用的 Python 3（已跳过 Microsoft Store 的 WindowsApps 转发器）。请安装 Python，或设置环境变量 DSH_COOKIE_CLEANUP_PYTHON 指向 python.exe。' }
    if ($CheckPython) {
        $capture = Invoke-PythonCapture -Arguments @('-c', 'import sqlite3;print(1)')
        $sawOne = $false
        foreach ($line in $capture.Output) {
            if ([string]$line -eq '1') { $sawOne = $true }
        }
        $text = ($capture.Output | ForEach-Object { [string]$_ }) -join "`n"
        if ($capture.ExitCode -ne 0 -or -not $sawOne) {
            throw "Python 预检失败（-CheckPython）：$script:Python`n$text"
        }
    }
}

function Get-AppProcesses {
    # -Name treats its value as a wildcard pattern.  Escape it so a value such
    # as "*" cannot match every process (or make -KillApp kill everything).
    $escaped = [System.Management.Automation.WildcardPattern]::Escape($AppProcessName)
    @(Get-Process -Name $escaped -ErrorAction SilentlyContinue)
}

function Get-WatcherPidFile {
    return Join-Path $script:ScriptDir 'state\watcher.pid'
}

function Write-WatcherPidFile {
    $path = Get-WatcherPidFile
    $dir = Split-Path -Parent $path
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $startTime = 0L
        try { $startTime = (Get-Process -Id $PID).StartTime.ToFileTimeUtc() } catch { }
        Set-Content -LiteralPath $path -Value @($PID, $startTime) -Encoding ASCII
    } catch {
        Write-Log ('无法写入监视器 PID 文件（-Status 可能看不到本进程）: {0}' -f $_.Exception.Message) 'WARN'
    }
}

function Remove-WatcherPidFile {
    $path = Get-WatcherPidFile
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $lines = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim() -split "`r?`n"
        if ($lines.Count -ge 1 -and $lines[0].Trim() -eq [string]$PID) {
            Remove-Item -LiteralPath $path -Force
            $dir = Split-Path -Parent $path
            if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) {
                Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

function Get-WatcherStopFile {
    return Join-Path $script:ScriptDir 'state\watcher.stop'
}

function Test-WatcherStopRequested {
    $path = Get-WatcherStopFile
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $content = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim()
    } catch {
        return $false
    }
    if (-not $content) { return $false }
    $start = 0L
    try { $start = (Get-Process -Id $PID).StartTime.ToFileTimeUtc() } catch { return $false }
    $token = '{0}:{1}' -f $PID, $start
    foreach ($line in ($content -split "`r?`n")) {
        if ($line.Trim() -eq $token) { return $true }
    }
    return $false
}

function Resolve-AppExe {
    # An explicitly supplied path must be valid.  Silently falling back could
    # start a different installation than the database that was just cleaned.
    if ($AppExe) {
        if (Test-Path -LiteralPath $AppExe -PathType Leaf) {
            return (Get-Item -LiteralPath $AppExe).FullName
        }
        throw "-AppExe 指定的文件不存在或不是文件: $AppExe"
    }
    if ($env:DSH_DESKTOP_EXE) {
        if (Test-Path -LiteralPath $env:DSH_DESKTOP_EXE -PathType Leaf) {
            return (Get-Item -LiteralPath $env:DSH_DESKTOP_EXE).FullName
        }
        throw "环境变量 DSH_DESKTOP_EXE 指向的文件不存在或不是文件: $env:DSH_DESKTOP_EXE"
    }
    $root = Split-Path -Parent (Split-Path -Parent $script:ScriptDir)
    if ($root) {
        $candidate = Join-Path $root 'DeepSeek Harness\DeepSeek Harness.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $candidate = Join-Path $root 'DeepSeek Harness.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $proc = Get-AppProcesses | Select-Object -First 1
    if ($proc -and $proc.Path) { return $proc.Path }
    return $null
}

function Get-CookieDbPaths {
    if ($DbPath) { return @([System.IO.Path]::GetFullPath($DbPath)) }
    $root = $UserDataDir
    if (-not $root) { $root = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop' }
    $paths = @()
    $main = Join-Path $root 'Network\Cookies'
    if (Test-Path -LiteralPath $main) { $paths += $main }
    if ($AllProfiles) {
        $partitions = Join-Path $root 'Partitions'
        if (Test-Path -LiteralPath $partitions) {
            Get-ChildItem -LiteralPath $partitions -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Join-Path $_.FullName 'Network\Cookies'
                if (Test-Path -LiteralPath $p) { $paths += $p }
            }
        }
    }
    return $paths
}

function Enter-NamedMutex {
    param([string]$Name)
    try {
        $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList @($false, $Name)
    } catch {
        return $null
    }
    try {
        if (-not $mutex.WaitOne(0)) {
            $mutex.Dispose()
            return $null
        }
        return $mutex
    } catch [System.Threading.AbandonedMutexException] {
        # A previous owner was killed without releasing it; this thread now
        # owns the mutex, so the operation may continue.
        return $mutex
    } catch {
        try { $mutex.Dispose() } catch { }
        return $null
    }
}

function Release-NamedMutex {
    param($Mutex)
    if ($Mutex) {
        try { $Mutex.ReleaseMutex() } catch { }
        try { $Mutex.Dispose() } catch { }
    }
}

function Enter-WatchMutex {
    return Enter-NamedMutex -Name 'Local\DshCookieCleanup.Watch'
}

function Exit-WatchMutex {
    Release-NamedMutex -Mutex $script:WatchMutex
    $script:WatchMutex = $null
}

function Get-CookieAuthCount {
    param([string]$Db)
    # Reports take the same mutex as cleanups/restores, so a heartbeat cannot
    # read a database that a restore is moving.
    $dataMutex = Enter-NamedMutex -Name 'Local\DshCookieCleanup.Restore'
    if (-not $dataMutex) {
        $script:LastCookieReadError = '另一个清理/恢复正在进行，稍后再试。'
        return -1
    }
    try {
        $pyArgs = @($script:PyScript, '--db', $Db, '--json', '--report-only')
        $capture = Invoke-PythonCapture -Arguments $pyArgs
        $output = $capture.Output
        $jsonText = $output | Where-Object { [string]$_ -match '^\s*\{' } | Select-Object -Last 1
        if (-not $jsonText) {
            $script:LastCookieReadError = ('Python exit={0}（{1}）：{2}' -f $capture.ExitCode, $script:Python, ($output -join ' '))
            return -1
        }
        try {
            $r = $jsonText | ConvertFrom-Json
        } catch {
            $script:LastCookieReadError = ('JSON 解析失败：{0}' -f $_.Exception.Message)
            return -1
        }
        if (-not $r.ok) {
            $script:LastCookieReadError = [string]$r.error
            return -1
        }
        return [int]$r.auth
    } finally {
        Release-NamedMutex -Mutex $dataMutex
    }
}

function Invoke-HeartbeatCheck {
    param([int]$Threshold)
    $dbs = Get-CookieDbPaths
    $total = 0
    $failed = @()
    $script:LastCookieReadError = $null
    foreach ($db in $dbs) {
        $count = Get-CookieAuthCount -Db $db
        if ($count -lt 0) {
            $failed += $db
            continue
        }
        $total += $count
    }
    if ($failed.Count -gt 0) {
        $detail = ''
        if ($script:LastCookieReadError) { $detail = '；最后错误: ' + $script:LastCookieReadError }
        Write-Log ('心跳检查：无法读取 {0} 个库，已跳过：{1}{2}' -f $failed.Count, ($failed -join '; '), $detail) 'WARN'
    }
    if ($total -le $Threshold) { return }
    Write-Log ('心跳检查：应用未运行，累计 {0} 个 dsh-auth-*（阈值 {1}），执行兜底清理。' -f $total, $Threshold) 'WARN'
    foreach ($db in $dbs) {
        [void](Invoke-CleanupDb -Db $db)
    }
    if (-not ($DryRun -or $ReportOnly)) {
        Remove-OldBackups -Root $script:BackupRoot -KeepCookies $KeepBackups -KeepPreRestore $KeepPreRestore
    }
}

function Invoke-VerifyDb {
    param([string]$Db)
    $pyArgs = @($script:PyScript, '--db', $Db, '--json', '--verify')
    $capture = Invoke-PythonCapture -Arguments $pyArgs
    $output = $capture.Output
    $jsonText = $output | Where-Object { [string]$_ -match '^\s*\{' } | Select-Object -Last 1
    if (-not $jsonText) {
        Write-Log ('校验失败：Python exit={0}（{1}）：{2}' -f $capture.ExitCode, $script:Python, ($output -join ' ')) 'WARN'
        return $null
    }
    try {
        return $jsonText | ConvertFrom-Json
    } catch {
        Write-Log ('校验失败：返回内容不是 JSON：{0}' -f $_.Exception.Message) 'WARN'
        return $null
    }
}

function Wait-ForAppExit {
    param([int]$TimeoutSeconds)
    $deadline = $null
    if ($TimeoutSeconds -gt 0) { $deadline = (Get-Date).AddSeconds($TimeoutSeconds) }
    while ($true) {
        if ((Get-AppProcesses).Count -eq 0) { return $true }
        if ($deadline -and (Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 2
    }
}

function Remove-OldBackups {
    param([string]$Root, [int]$KeepCookies, [int]$KeepPreRestore)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return }
    # Rotation deletes backup folders.  Share the data mutex so it cannot
    # remove a backup that a restore is reading.  A same-thread call (from
    # Invoke-Restore) re-enters the mutex safely.
    $mutex = Enter-NamedMutex -Name 'Local\DshCookieCleanup.Restore'
    if (-not $mutex) { return }
    try {
        $reparse = [int][System.IO.FileAttributes]::ReparsePoint
        if ($KeepCookies -gt 0) {
            Get-ChildItem -LiteralPath $Root -Directory -Filter 'Cookies-*' -ErrorAction SilentlyContinue |
                Where-Object {
                    -not ([int]$_.Attributes -band $reparse) -and
                    $_.Name -match '^Cookies-\d{8}-\d{6}-\d{3}-.+'
                } |
                Sort-Object Name -Descending |
                Select-Object -Skip $KeepCookies |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force } catch { }
                }
        }
        if ($KeepPreRestore -gt 0) {
            Get-ChildItem -LiteralPath $Root -Directory -Filter 'pre-restore-*' -ErrorAction SilentlyContinue |
                Where-Object {
                    -not ([int]$_.Attributes -band $reparse) -and
                    $_.Name -match '^pre-restore-\d{8}-\d{6}-\d{3}$'
                } |
                Sort-Object Name -Descending |
                Select-Object -Skip $KeepPreRestore |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force } catch { }
                }
        }
    } finally {
        Release-NamedMutex -Mutex $mutex
    }
}

function Protect-BackupRoot {
    param([string]$Root)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return }
    # Only harden the default location.  A user-supplied -BackupRoot may be a
    # shared/backup volume whose ACLs are managed elsewhere.
    $defaultRoot = [System.IO.Path]::GetFullPath((Join-Path $script:ScriptDir 'backups'))
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    if (-not [string]::Equals($fullRoot, $defaultRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return }

    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
    if (-not $rootItem) { return }
    if ([int]$rootItem.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) {
        Write-Log ('备份目录是 reparse point，跳过 ACL 收紧: {0}' -f $Root) 'WARN'
        return
    }

    $icacls = 'icacls.exe'
    if ($env:SystemRoot) { $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe' }
    if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) { return }

    $sid = $null
    try { $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    if (-not $sid) { return }

    $dirGrants = @(
        "*${sid}:(OI)(CI)F",
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F'
    )
    $fileGrants = @(
        "*${sid}:F",
        '*S-1-5-18:F',
        '*S-1-5-32-544:F'
    )
    $output = @()
    $code = -1
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $icacls $Root /inheritance:r /grant:r @dirGrants /T /C /Q 2>&1)
        $code = $LASTEXITCODE

        # (OI)(CI) is a directory-inheritance grant.  Applied to a file by
        # /T, it leaves the file with no effective ACE after /inheritance:r.
        # Grant each existing file an explicit, non-inherited FullControl ACE
        # so backups remain readable and restorable.  New files inherit the
        # directory grant above.
        $fileFailures = New-Object System.Collections.ArrayList
        $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            $fileOutput = @(& $icacls $file.FullName /grant:r @fileGrants /C /Q 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $fileDetail = ($fileOutput | ForEach-Object { [string]$_ }) -join ' '
                [void]$fileFailures.Add(('{0}: {1}' -f $file.FullName, $fileDetail))
            }
        }
        if ($fileFailures.Count -gt 0) {
            $detail = ($fileFailures | Select-Object -First 5) -join '; '
            Write-Log ('无法修复部分备份文件 ACL，备份可能无法恢复: {0}' -f $detail) 'WARN'
        }
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($code -ne 0) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join ' '
        Write-Log ('无法收紧备份目录 ACL（可能不是 NTFS）: {0}' -f $detail) 'WARN'
    }
}

function Remove-RestoreStaging {
    param([string]$Path)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    if (Test-Path -LiteralPath $Path) {
        Write-Log ('无法删除临时恢复文件，请手动删除: {0}' -f $Path) 'WARN'
        return $false
    }
    return $true
}

function Remove-StaleRestoreFiles {
    param([string]$Directory)
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { return }
    Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Cookies.restore-*' -or $_.Name -like 'Cookies.rollback-*' } |
        ForEach-Object {
            $path = $_.FullName
            if ((Test-Path -LiteralPath $path) -and (Remove-RestoreStaging -Path $path)) {
                Write-Log ('已清理残留临时恢复文件: {0}' -f $path) 'INFO'
            }
        }
}

function Get-PathTag {
    param([string]$Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
            $hash = $sha.ComputeHash($bytes)
            return ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 8).ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } catch {
        return ([guid]::NewGuid()).ToString('N').Substring(0, 8)
    }
}

function Invoke-CleanupDbCore {
    param([string]$Db)

    if (-not ($DryRun -or $ReportOnly)) {
        Remove-StaleRestoreFiles -Directory (Split-Path -Parent $Db)
    }

    $name = Split-Path -Leaf (Split-Path -Parent $Db)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $tag = Get-PathTag -Path $Db
    $backupDir = Join-Path $script:BackupRoot ('Cookies-{0}-{1}-{2}' -f $stamp, ($name -replace '[^A-Za-z0-9._-]', '_'), $tag)

    $pyArgs = @($script:PyScript, '--db', $Db, '--json')
    if ($DryRun -or $ReportOnly) {
        $pyArgs += '--dry-run'
    } else {
        $pyArgs += @('--backup-dir', $backupDir)
    }
    if ($KeepLatest -gt 0) { $pyArgs += @('--keep-latest', [string]$KeepLatest) }

    $capture = Invoke-PythonCapture -Arguments $pyArgs
    $output = $capture.Output
    $exit = $capture.ExitCode
    $jsonText = $output | Where-Object { [string]$_ -match '^\s*\{' } | Select-Object -Last 1
    if (-not $jsonText) {
        Write-Log ('清理失败（Python 无法运行或缺少 sqlite3，exit={0}）' -f $exit) 'ERROR'
        Write-Log ('  Python: {0}' -f $script:Python) 'ERROR'
        if ($output) { Write-Log ('  输出: {0}' -f ($output -join ' ')) 'ERROR' }
        return [pscustomobject]@{ Status = 'error'; Db = $Db }
    }
    $r = $jsonText | ConvertFrom-Json

    if (-not $r.ok) {
        $msg = [string]$r.error
        if ($r.locked) {
            Write-Log ('跳过 {0}：数据库被占用（应用可能仍在运行）。{1}' -f $Db, $msg) 'WARN'
            return [pscustomobject]@{ Status = 'skipped'; Db = $Db; Locked = $true; Reason = 'locked' }
        }
        Write-Log ('失败 {0}：{1}' -f $Db, $msg) 'ERROR'
        return [pscustomobject]@{ Status = 'error'; Db = $Db }
    }

    $pct = 0
    if ([int]$r.header_limit -gt 0) {
        $pct = [math]::Round(100.0 * [int]$r.header_total / [int]$r.header_limit, 1)
    }
    Write-Log ('数据库: {0}' -f $r.db)
    Write-Log ('Cookie 总数 {0}；dsh-auth-* {1} 个（有效期内 {2}，已过期 {3}）；估算请求头 {4} / {5} 字节（{6}%），其中 Cookie 占 {7}' -f $r.total, $r.auth, $r.active, $r.expired, $r.header_total, $r.header_limit, $pct, $r.header_bytes)
    if ($r.oldest_expires) {
        Write-Log ('最早过期: {0}；最晚过期: {1}' -f $r.oldest_expires, $r.newest_expires)
    }
    if ([int]$r.expired -gt 0) {
        Write-Log ('已过期的 {0} 个 Cookie 不会再被发送，不占请求头；本次会一并删除。' -f $r.expired) 'INFO'
    }

    if ($r.dry_run) {
        Write-Log ('[预演] 将删除 {0} 个，保留 {1} 个。未改动数据库。' -f $r.planned, $r.keep) 'WARN'
    } elseif ([int]$r.deleted -eq 0) {
        Write-Log '没有需要清理的 dsh-auth-* Cookie。' 'OK'
    } else {
        Write-Log ('已删除 {0} 个；剩余 dsh-auth-* {1} 个。' -f $r.deleted, $r.remaining) 'OK'
        if ($r.backup) { Write-Log ('备份: {0}' -f $r.backup) }
        if ($r.quick_check) {
            if ($r.quick_check -ne 'ok') {
                Write-Log ('数据库完整性检查异常: {0}。请用 -Restore 恢复备份。' -f $r.quick_check) 'ERROR'
            } else {
                Write-Log '数据库完整性检查: ok' 'OK'
            }
        }
    }

    if ([int]$r.header_total -ge 14000 -and -not $r.dry_run) {
        Write-Log '警告：清理前已非常接近 16 KiB 上限（含其它请求头），说明累积速度较快；建议每次启动前都运行本脚本。' 'WARN'
    }

    return [pscustomobject]@{
        Status    = 'ok'
        Db        = $r.db
        Auth      = [int]$r.auth
        Planned   = [int]$r.planned
        Deleted   = [int]$r.deleted
        Remaining = [int]$r.remaining
        Backup    = $r.backup
        Header    = [int]$r.header_total
        DryRun    = [bool]$r.dry_run
    }
}

function Invoke-CleanupDb {
    param([string]$Db)

    # Every cleanup/report shares the Restore mutex, so a report cannot read a
    # database that a restore is moving and a restore cannot swap mid-delete.
    $dataMutex = Enter-NamedMutex -Name 'Local\DshCookieCleanup.Restore'
    if (-not $dataMutex) {
        Write-Log ('跳过 {0}：另一个清理/恢复正在进行，稍后再试。' -f $Db) 'WARN'
        return [pscustomobject]@{ Status = 'skipped'; Db = $Db; Locked = $true; Reason = 'busy' }
    }
    try {
        return Invoke-CleanupDbCore -Db $Db
    } finally {
        Release-NamedMutex -Mutex $dataMutex
    }
}

function Undo-RestoreSwap {
    param(
        [string]$Target,
        [string]$Pre,
        [bool]$Swapped,
        [bool]$BackedUpMain,
        [string[]]$BackedUpSiblings
    )

    $ok = $true
    $targetDir = Split-Path -Parent $Target
    if ($Swapped) {
        if (Test-Path -LiteralPath $Target -PathType Leaf) {
            if ($BackedUpMain) {
                $saved = Join-Path $Pre 'Cookies'
                if (Test-Path -LiteralPath $saved -PathType Leaf) {
                    $rollback = Join-Path $targetDir ('Cookies.rollback-' + ([guid]::NewGuid()).ToString('N').Substring(0, 8))
                    try {
                        Copy-Item -LiteralPath $saved -Destination $rollback -Force -ErrorAction Stop
                        [System.IO.File]::Replace($rollback, $Target, [NullString]::Value, $true)
                    } catch {
                        Write-Log ('回滚失败：无法恢复原数据库 {0}: {1}' -f $Target, $_.Exception.Message) 'ERROR'
                        [void](Remove-RestoreStaging -Path $rollback)
                        $ok = $false
                    }
                } else {
                    Write-Log ('回滚失败：备份中没有 Cookies 文件: {0}' -f $saved) 'ERROR'
                    $ok = $false
                }
            } else {
                try {
                    Remove-Item -LiteralPath $Target -Force -ErrorAction Stop
                } catch {
                    Write-Log ('回滚失败：无法删除恢复后的文件 {0}: {1}' -f $Target, $_.Exception.Message) 'ERROR'
                    $ok = $false
                }
            }
        } elseif ($BackedUpMain) {
            $saved = Join-Path $Pre 'Cookies'
            if (Test-Path -LiteralPath $saved -PathType Leaf) {
                try {
                    Copy-Item -LiteralPath $saved -Destination $Target -Force -ErrorAction Stop
                } catch {
                    Write-Log ('回滚失败：无法恢复原数据库 {0}: {1}' -f $Target, $_.Exception.Message) 'ERROR'
                    $ok = $false
                }
            }
        }
    }
    foreach ($name in $BackedUpSiblings) {
        $saved = Join-Path $Pre $name
        $dest = Join-Path $targetDir $name
        if (Test-Path -LiteralPath $saved -PathType Leaf) {
            try {
                Copy-Item -LiteralPath $saved -Destination $dest -Force -ErrorAction Stop
            } catch {
                Write-Log ('回滚失败：无法恢复 {0}: {1}' -f $dest, $_.Exception.Message) 'ERROR'
                $ok = $false
            }
        }
    }
    return $ok
}

function Invoke-Restore {
    param([string]$Folder)

    if (-not $DbPath) { throw '-Restore 需要同时指定 -DbPath（要恢复到的 Cookies 文件）。' }
    $source = Join-Path $Folder 'Cookies'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "备份文件夹里没有 Cookies 文件: $Folder"
    }
    if (-not $SkipProcessCheck -and (Get-AppProcesses).Count -gt 0) {
        Write-Log 'DeepSeek Harness 正在运行，无法恢复。请先完全退出。' 'ERROR'
        return 2
    }
    $target = [System.IO.Path]::GetFullPath($DbPath)
    if (Test-Path -LiteralPath $target -PathType Container) {
        # Never move a directory: -DbPath is the Cookies file, not Network\.
        Write-Log ('恢复目标必须是 Cookies 文件，而不是目录: {0}' -f $target) 'ERROR'
        Write-Log ('请改用类似这样的路径: {0}' -f (Join-Path $target 'Cookies')) 'INFO'
        return 1
    }
    $targetDir = Split-Path -Parent $target
    Remove-StaleRestoreFiles -Directory $targetDir
    $pre = Join-Path $script:BackupRoot ('pre-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $script:RestorePrePath = $pre

    # Verify the backup before touching the live database: a truncated backup
    # must fail here, not on the next app start.
    $sourceCheck = Invoke-VerifyDb -Db $source
    if (-not $sourceCheck -or -not $sourceCheck.ok -or [string]$sourceCheck.quick_check -ne 'ok') {
        if (-not $sourceCheck) {
            $reason = '无法读取'
        } elseif ($sourceCheck.error) {
            $reason = [string]$sourceCheck.error
        } else {
            $reason = [string]$sourceCheck.quick_check
        }
        Write-Log ('备份校验失败（{0}），未执行恢复: {1}' -f $reason, $source) 'ERROR'
        $script:RestorePrePath = $null
        return 1
    }

    # Stage and validate the replacement beside the live file first.  The live
    # database is only replaced after a complete, checked replacement exists.
    $staging = Join-Path $targetDir ('Cookies.restore-' + ([guid]::NewGuid()).ToString('N').Substring(0, 8))
    try {
        Copy-Item -LiteralPath $source -Destination $staging -Force
    } catch {
        Write-Log ('无法写入临时文件 {0}: {1}' -f $staging, $_.Exception.Message) 'ERROR'
        [void](Remove-RestoreStaging -Path $staging)
        $script:RestorePrePath = $null
        return 1
    }
    $stagedCheck = Invoke-VerifyDb -Db $staging
    if (-not $stagedCheck -or -not $stagedCheck.ok -or [string]$stagedCheck.quick_check -ne 'ok') {
        [void](Remove-RestoreStaging -Path $staging)
        Write-Log '临时文件校验失败，未改动现库。' 'ERROR'
        $script:RestorePrePath = $null
        return 1
    }

    New-Item -ItemType Directory -Path $pre -Force | Out-Null
    $backedUpMain = $false
    $backedUpSiblings = @()
    $swapped = $false
    try {
        # Snapshot the current state as copies.  The live file stays in place
        # until the atomic replace below, so a crash cannot leave the profile
        # without a database.
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Copy-Item -LiteralPath $target -Destination (Join-Path $pre 'Cookies') -Force -ErrorAction Stop
            $backedUpMain = $true
        }
        foreach ($siblingName in @('Cookies-journal', 'Cookies-wal', 'Cookies-shm')) {
            $sibling = Join-Path $targetDir $siblingName
            if (Test-Path -LiteralPath $sibling -PathType Leaf) {
                Copy-Item -LiteralPath $sibling -Destination (Join-Path $pre $siblingName) -Force -ErrorAction Stop
                $backedUpSiblings += $siblingName
            }
        }
        # A restored database must not inherit the old WAL/journal.
        foreach ($siblingName in $backedUpSiblings) {
            Remove-Item -LiteralPath (Join-Path $targetDir $siblingName) -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            [System.IO.File]::Replace($staging, $target, [NullString]::Value, $true)
        } else {
            [System.IO.File]::Move($staging, $target)
        }
        $swapped = $true
    } catch {
        $reason = $_.Exception.Message
        if ($_.Exception -is [System.PlatformNotSupportedException] -or $_.Exception -is [System.NotSupportedException]) {
            $reason = '当前文件系统不支持原子替换（File.Replace）: ' + $reason
        }
        $undoOk = Undo-RestoreSwap -Target $target -Pre $pre -Swapped $swapped -BackedUpMain $backedUpMain -BackedUpSiblings $backedUpSiblings
        [void](Remove-RestoreStaging -Path $staging)
        if ($undoOk) {
            Write-Log ('恢复失败（{0}）；现库未改动。' -f $reason) 'ERROR'
        } else {
            Write-Log ('恢复失败（{0}）；回滚未完全成功，请在应用退出后手动检查 {1}，恢复前状态在: {2}' -f $reason, $target, $pre) 'ERROR'
        }
        return 1
    }

    $afterCheck = Invoke-VerifyDb -Db $target
    if (-not $afterCheck -or -not $afterCheck.ok -or [string]$afterCheck.quick_check -ne 'ok') {
        $undoOk = Undo-RestoreSwap -Target $target -Pre $pre -Swapped $swapped -BackedUpMain $backedUpMain -BackedUpSiblings $backedUpSiblings
        $restoredOk = $false
        if ($backedUpMain) {
            $verify = Invoke-VerifyDb -Db $target
            $restoredOk = ($undoOk -and $verify -and $verify.ok -and [string]$verify.quick_check -eq 'ok')
        } else {
            $restoredOk = ($undoOk -and -not (Test-Path -LiteralPath $target))
        }
        if ($restoredOk) {
            Write-Log ('恢复后校验失败，已回滚；原数据库备份在: {0}' -f $pre) 'ERROR'
        } else {
            Write-Log ('恢复后校验失败，回滚未完全成功；请手动检查 {0}，恢复前状态在: {1}' -f $target, $pre) 'ERROR'
        }
        return 1
    }

    Write-Log ('已恢复 {0} -> {1}（total={2}, auth={3}, quick_check=ok）' -f $source, $target, $afterCheck.total, $afterCheck.auth) 'OK'
    if ($backedUpMain -or $backedUpSiblings.Count -gt 0) {
        Write-Log ('恢复前状态已备份到 {0}' -f $pre)
    } else {
        Remove-Item -LiteralPath $pre -Force -ErrorAction SilentlyContinue
    }
    $script:RestorePrePath = $null
    Remove-OldBackups -Root $script:BackupRoot -KeepCookies $KeepBackups -KeepPreRestore $KeepPreRestore
    return 0
}

function Invoke-Watch {
    if ($PollSeconds -lt 1) { throw 'PollSeconds 必须 >= 1。' }
    if ($HeartbeatMinutes -lt 0) { throw 'HeartbeatMinutes 必须 >= 0（0 表示关闭心跳）。' }
    if ($HeartbeatThreshold -lt 0) { throw 'HeartbeatThreshold 必须 >= 0。' }

    if (Test-WatcherStopRequested) {
        Write-Log '收到停止请求，退出监视。'
        return 0
    }

    $deadline = $null
    if ($WatchMinutes -gt 0) { $deadline = (Get-Date).AddMinutes($WatchMinutes) }
    $heartbeatInterval = $null
    $nextHeartbeat = $null
    if ($HeartbeatMinutes -gt 0) {
        $heartbeatInterval = [TimeSpan]::FromMinutes($HeartbeatMinutes)
        $nextHeartbeat = Get-Date
    }
    Write-Log ('进入监视模式：等待 {0} 退出后自动清理（每 {1} 秒检查一次）。' -f $AppProcessName, $PollSeconds)
    if ($heartbeatInterval) {
        Write-Log ('心跳兜底：应用未运行时每 {0} 分钟检查一次，超过 {1} 个 dsh-auth-* 就清理。' -f $HeartbeatMinutes, $HeartbeatThreshold)
    }

    while ($true) {
        if (Test-WatcherStopRequested) {
            Write-Log '收到停止请求，退出监视。'
            return 0
        }
        if ($deadline -and (Get-Date) -ge $deadline) {
            Write-Log '监视时间结束。'
            return 0
        }
        if ((Get-AppProcesses).Count -eq 0) {
            if ($nextHeartbeat -and (Get-Date) -ge $nextHeartbeat) {
                Invoke-HeartbeatCheck -Threshold $HeartbeatThreshold
                $nextHeartbeat = (Get-Date).Add($heartbeatInterval)
            }
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        Write-Log ('检测到 {0} 正在运行，等待其退出……' -f $AppProcessName)
        while ((Get-AppProcesses).Count -gt 0) {
            if (Test-WatcherStopRequested) {
                Write-Log '收到停止请求，退出监视。'
                return 0
            }
            if ($deadline -and (Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 2
        }
        if ($deadline -and (Get-Date) -ge $deadline) {
            Write-Log '监视时间结束。'
            return 0
        }

        # Give Electron's child processes and SQLite a moment to flush and close.
        Start-Sleep -Seconds 4
        $attempt = 0
        while ($true) {
            $attempt++
            $dbs = Get-CookieDbPaths
            $locked = $false
            foreach ($db in $dbs) {
                $result = Invoke-CleanupDb -Db $db
                if ($result.Status -eq 'skipped') { $locked = $true }
            }
            if (-not $locked) { break }
            if ($attempt -ge 3) {
                Write-Log '清理/恢复锁仍被占用，跳过本轮；下次退出时再试。' 'WARN'
                break
            }
            Start-Sleep -Seconds 5
        }
        if (-not ($DryRun -or $ReportOnly)) {
            Remove-OldBackups -Root $script:BackupRoot -KeepCookies $KeepBackups -KeepPreRestore $KeepPreRestore
        }
        if ($heartbeatInterval) { $nextHeartbeat = (Get-Date).Add($heartbeatInterval) }
        Write-Log '本轮清理结束，继续监视下一次启动/退出。'
    }
}

try {
    $isReadOnlyRun = [bool]($DryRun -or $ReportOnly)
    if (-not ($isReadOnlyRun -and -not $LogPath)) {
        Initialize-Log -Path $LogPath
    }

    if ($KeepLatest -lt 0) { throw 'KeepLatest 必须 >= 0。' }
    if ($KeepBackups -lt 0) { throw 'KeepBackups 必须 >= 0（0 表示保留全部备份）。' }
    if ($KeepPreRestore -lt 0) { throw 'KeepPreRestore 必须 >= 0（0 表示保留全部备份）。' }

    if (-not $BackupRoot) { $BackupRoot = Join-Path $script:ScriptDir 'backups' }
    $script:BackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
    if (-not (Test-Path -LiteralPath $script:BackupRoot) -and -not $isReadOnlyRun) {
        New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    }
    if (-not $isReadOnlyRun) {
        Protect-BackupRoot -Root $script:BackupRoot
    }

    if ($Restore -and $Watch) {
        Write-Log '-Restore 与 -Watch 不能同时使用；未执行恢复。' 'ERROR'
        exit 2
    }

    if ($Restore -and ($DryRun -or $ReportOnly)) {
        Write-Log '-Restore 不能与 -DryRun/-ReportOnly 同时使用；未执行恢复。' 'ERROR'
        exit 2
    }

    $script:Python = Resolve-Python
    Assert-Python

    if ($Restore) {
        $restoreMutex = Enter-NamedMutex -Name 'Local\DshCookieCleanup.Restore'
        if (-not $restoreMutex) {
            Write-Log '另一个清理或恢复正在进行，本次恢复不再启动。' 'WARN'
            exit 3
        }
        $restoreCode = 0
        try {
            $restoreCode = Invoke-Restore -Folder $Restore
        } finally {
            Release-NamedMutex -Mutex $restoreMutex
        }
        exit $restoreCode
    }

    if ($Watch) {
        $script:WatchMutex = Enter-WatchMutex
        if (-not $script:WatchMutex) {
            Write-Log '已有另一个监视器在运行（Local\DshCookieCleanup.Watch），本次不再启动。' 'WARN'
            exit 0
        }
        Write-WatcherPidFile
        $watchCode = 0
        try {
            $watchCode = Invoke-Watch
        } finally {
            Remove-WatcherPidFile
            Exit-WatchMutex
        }
        exit $watchCode
    }

    Write-Log '=== DSH Cookie 清理 ==='
    $dbs = Get-CookieDbPaths
    if ($dbs.Count -eq 0) {
        Write-Log '找不到 DSH Desktop 的 Cookie 数据库。请确认应用至少启动过一次，或用 -UserDataDir / -DbPath 指定。' 'ERROR'
        exit 2
    }

    if (-not $SkipProcessCheck) {
        $procs = Get-AppProcesses
        if ($procs.Count -gt 0) {
            $pids = ($procs | ForEach-Object { $_.Id }) -join ', '
            if ($KillApp) {
                Write-Log ('-KillApp：强制结束 {0}（PID {1}）……' -f $AppProcessName, $pids) 'WARN'
                foreach ($proc in $procs) {
                    try {
                        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                    } catch {
                        Write-Log ('无法结束 PID {0}: {1}' -f $proc.Id, $_.Exception.Message) 'WARN'
                    }
                }
                if (-not (Wait-ForAppExit -TimeoutSeconds 20)) {
                    Write-Log '结束进程后 20 秒仍未完全退出，放弃清理。' 'ERROR'
                    exit 2
                }
                Start-Sleep -Seconds 2
                Write-Log '进程已结束，继续清理。'
            } else {
                switch ($IfRunning) {
                    'Skip' {
                        Write-Log ('跳过：{0} 正在运行（PID {1}），Cookie 数据库被独占锁定。' -f $AppProcessName, $pids) 'WARN'
                        exit 2
                    }
                    'Wait' {
                        Write-Log ('等待 {0} 退出（PID {1}）……' -f $AppProcessName, $pids)
                        if (-not (Wait-ForAppExit -TimeoutSeconds $WaitSeconds)) {
                            Write-Log '等待超时，未执行清理。' 'ERROR'
                            exit 2
                        }
                        Write-Log '应用已退出，开始清理。'
                    }
                    default {
                        Write-Log ('{0} 正在运行（PID {1}）。请先完全退出（托盘图标 → 退出），再运行本脚本。' -f $AppProcessName, $pids) 'ERROR'
                        Write-Log '也可以使用 -IfRunning Wait 让脚本等待应用退出，或用 -KillApp 强制结束。' 'INFO'
                        exit 2
                    }
                }
            }
        }
    }

    $hadError = $false
    $hadSkip = $false
    $hadBusy = $false
    foreach ($db in $dbs) {
        $result = Invoke-CleanupDb -Db $db
        if ($result.Status -eq 'error') { $hadError = $true }
        if ($result.Status -eq 'skipped') {
            if ($result.Reason -eq 'busy') { $hadBusy = $true } else { $hadSkip = $true }
        }
    }

    if (-not $isReadOnlyRun) {
        Remove-OldBackups -Root $script:BackupRoot -KeepCookies $KeepBackups -KeepPreRestore $KeepPreRestore
    }

    if ($StartApp) {
        if ((Get-AppProcesses).Count -gt 0) {
            Write-Log '应用已在运行，不再重复启动。'
        } elseif (($hadError -or $hadSkip -or $hadBusy -or $DryRun -or $ReportOnly) -and -not $ForceStart) {
            Write-Log '清理未成功或处于预演模式，已跳过启动应用（避免在 431 状态下再次启动失败）。确认要启动请加 -ForceStart。' 'ERROR'
        } else {
            $exe = Resolve-AppExe
            if (-not $exe) {
                Write-Log '找不到 DeepSeek Harness.exe，请用 -AppExe 指定。' 'ERROR'
                $hadError = $true
            } else {
                Write-Log ('启动 {0}' -f $exe)
                Start-Process -FilePath $exe
            }
        }
    }

    if ($hadError) { exit 1 }
    if ($hadBusy) { exit 3 }
    if ($hadSkip) { exit 2 }
    exit 0
} catch {
    Write-Log ('发生错误: {0}' -f $_.Exception.Message) 'ERROR'
    if ($script:RestorePrePath) {
        Write-Log ('原数据库备份在: {0}' -f $script:RestorePrePath) 'ERROR'
    }
    if ($script:LogFile) { Write-Log ('日志: {0}' -f $script:LogFile) 'INFO' }
    exit 1
}
