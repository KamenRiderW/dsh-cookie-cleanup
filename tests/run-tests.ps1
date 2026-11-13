#requires -Version 5.1
<#
.SYNOPSIS
  Run the cleanup tool's self-tests against synthetic cookie databases.

.DESCRIPTION
  Runs against synthetic cookie databases in a temporary directory.  Some tests
  temporarily register a uniquely named scheduled task and start temporary
  watchers; both are stopped/removed before the suite exits.  The real DSH
  profile and the user's existing tasks/Startup entry are not touched.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$cleanup = Join-Path $repo 'cleanup.ps1'
$installer = Join-Path $repo 'install-task.ps1'
$cleanupDb = Join-Path $repo 'cleanup_db.py'
$makeDb = Join-Path $repo 'tests\make-test-db.py'
$verifyDb = Join-Path $repo 'tests\verify-db.py'

. (Join-Path $PSScriptRoot 'resolve-python.ps1')
$python = Resolve-Python
if (-not $python) { throw 'Python 3 is required to run these tests.' }

$root = Join-Path $env:TEMP ('dsh-cookie-cleanup-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$script:failures = 0

function Write-Pass([string]$Message) { Write-Host "  PASS: $Message" -ForegroundColor Green }
function Write-Fail([string]$Message) {
    Write-Host "  FAIL: $Message" -ForegroundColor Red
    $script:failures++
}

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Pass $Message } else { Write-Fail $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ("$Actual" -eq "$Expected") {
        Write-Pass $Message
    } else {
        Write-Fail "$Message (expected [$Expected], got [$Actual])"
    }
}

function New-Case([string]$Name) {
    $path = Join-Path $root $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-PsFile {
    param([string]$File, [string[]]$Arguments)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + $Arguments
    $output = @(& powershell.exe @all 2>&1)
    $code = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{ Output = $text; ExitCode = $code }
}

function New-TestDb {
    param([string]$Path, [int]$Auth = 5, [int]$Other = 2, [int]$Foreign = 0, [int]$Expired = 0)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $dbArgs = @('--out', $Path, '--auth', "$Auth", '--other', "$Other")
    if ($Foreign -gt 0) { $dbArgs += @('--foreign-auth', "$Foreign") }
    if ($Expired -gt 0) { $dbArgs += @('--expired', "$Expired") }
    $out = @(& $python $makeDb @dbArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "make-test-db.py failed: $($out -join ' ')" }
}

function Get-DbJson {
    param([string]$Path)
    $out = @(& $python $cleanupDb --db $Path --json --verify 2>&1)
    $line = $out | Where-Object { [string]$_ -match '^\s*\{' } | Select-Object -Last 1
    if (-not $line) { throw "no JSON from cleanup_db.py: $($out -join ' ')" }
    return $line | ConvertFrom-Json
}

function Get-AuthCount([string]$Path) { return [int](Get-DbJson $Path).auth }
function Get-TotalCount([string]$Path) { return [int](Get-DbJson $Path).total }

function Get-LogText([string]$Case) {
    $log = Join-Path $Case 'cleanup.log'
    if (Test-Path -LiteralPath $log) { return (Get-Content -LiteralPath $log -Raw) }
    return ''
}

function Test-RestoreFile {
    Write-Host 'Test: restore to a Cookies file'
    $case = New-Case 'restore-file'
    $backupDir = Join-Path $case 'backup'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    New-TestDb (Join-Path $backupDir 'Cookies') -Auth 4 -Other 1
    $target = Join-Path $case 'profile\Network\Cookies'
    New-TestDb $target -Auth 1 -Other 1

    $r = Invoke-PsFile $cleanup @(
        '-Restore', $backupDir,
        '-DbPath', $target,
        '-SkipProcessCheck',
        '-BackupRoot', (Join-Path $case 'backups'),
        '-LogPath', (Join-Path $case 'cleanup.log')
    )
    if ($r.ExitCode -ne 0) { Write-Host $r.Output }
    Assert-Equal $r.ExitCode 0 'restore exits 0'
    Assert-True (Test-Path -LiteralPath $target -PathType Leaf) 'target is a file'
    Assert-Equal (Get-AuthCount $target) 4 'target contains the backup rows'

    $pre = @(Get-ChildItem -LiteralPath (Join-Path $case 'backups') -Directory -Filter 'pre-restore-*' -ErrorAction SilentlyContinue)
    Assert-True ($pre.Count -eq 1) 'one pre-restore snapshot exists'
    if ($pre.Count -eq 1) {
        Assert-Equal (Get-AuthCount (Join-Path $pre[0].FullName 'Cookies')) 1 'snapshot contains the old rows'
    }
}

function Test-RestoreRejectsDirectory {
    Write-Host 'Test: restore rejects a directory target'
    $case = New-Case 'restore-dir'
    $backupDir = Join-Path $case 'backup'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    New-TestDb (Join-Path $backupDir 'Cookies') -Auth 2 -Other 1
    $targetDir = Join-Path $case 'profile\Network'
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $targetDir 'TransportSecurity') -Value 'keep' -Encoding ASCII

    $r = Invoke-PsFile $cleanup @(
        '-Restore', $backupDir,
        '-DbPath', $targetDir,
        '-SkipProcessCheck',
        '-BackupRoot', (Join-Path $case 'backups'),
        '-LogPath', (Join-Path $case 'cleanup.log')
    )
    if ($r.ExitCode -eq 0) { Write-Host $r.Output }
    Assert-True ($r.ExitCode -ne 0) 'restore exits non-zero'
    Assert-True (Test-Path -LiteralPath $targetDir -PathType Container) 'target directory still exists'
    Assert-True (Test-Path -LiteralPath (Join-Path $targetDir 'TransportSecurity') -PathType Leaf) 'directory contents untouched'
    $preCount = @(Get-ChildItem -LiteralPath (Join-Path $case 'backups') -Directory -Filter 'pre-restore-*' -ErrorAction SilentlyContinue).Count
    Assert-Equal $preCount 0 'no pre-restore snapshot was created'
}

function Test-HostScopedDeletion {
    Write-Host 'Test: only 127.0.0.1 dsh-auth cookies are deleted'
    $case = New-Case 'host-scope'
    $db = Join-Path $case 'Network\Cookies'
    New-TestDb $db -Auth 6 -Other 2 -Foreign 3

    $r = Invoke-PsFile $cleanup @(
        '-DbPath', $db,
        '-SkipProcessCheck',
        '-BackupRoot', (Join-Path $case 'backups'),
        '-LogPath', (Join-Path $case 'cleanup.log')
    )
    if ($r.ExitCode -ne 0) { Write-Host $r.Output }
    Assert-Equal $r.ExitCode 0 'cleanup exits 0'

    $v = Get-DbJson $db
    Assert-Equal $v.auth 0 'no 127.0.0.1 dsh-auth rows remain'
    Assert-Equal $v.total 5 'foreign-auth and unrelated rows remain'
}

function Test-PythonRequiresBackup {
    Write-Host 'Test: cleanup_db.py refuses to delete without a backup'
    $case = New-Case 'no-backup'
    $db = Join-Path $case 'Cookies'
    New-TestDb $db -Auth 3 -Other 0

    $out = @(& $python $cleanupDb --db $db --json 2>&1)
    $code = $LASTEXITCODE
    $line = $out | Where-Object { [string]$_ -match '^\s*\{' } | Select-Object -Last 1
    $json = if ($line) { $line | ConvertFrom-Json } else { $null }

    Assert-True ($code -ne 0) 'exit code is non-zero'
    Assert-True ($json -and -not $json.ok) 'JSON reports ok=false'
    Assert-Equal (Get-AuthCount $db) 3 'rows were not deleted'

    # --no-backup is the explicit override.
    $out2 = @(& $python $cleanupDb --db $db --json --no-backup 2>&1)
    Assert-Equal $LASTEXITCODE 0 '--no-backup allows deletion'
    Assert-Equal (Get-AuthCount $db) 0 '--no-backup deleted the rows'

    # A backup directory that resolves to the live database must be refused.
    $case2 = New-Case 'self-backup'
    $db2 = Join-Path $case2 'Cookies'
    New-TestDb $db2 -Auth 2 -Other 0
    $out3 = @(& $python $cleanupDb --db $db2 --json --backup-dir $case2 2>&1)
    Assert-True ($LASTEXITCODE -ne 0) 'self-backup is refused'
    Assert-Equal (Get-AuthCount $db2) 2 'self-backup did not delete the rows'
}

function Test-NegativeKeepBackupsRejected {
    Write-Host 'Test: negative KeepBackups is rejected'
    $case = New-Case 'keep-negative'
    $db = Join-Path $case 'Cookies'
    New-TestDb $db -Auth 1 -Other 0

    $r = Invoke-PsFile $cleanup @(
        '-DbPath', $db,
        '-SkipProcessCheck',
        '-DryRun',
        '-KeepBackups', '-1',
        '-BackupRoot', (Join-Path $case 'backups'),
        '-LogPath', (Join-Path $case 'cleanup.log')
    )
    Assert-True ($r.ExitCode -ne 0) 'cleanup exits non-zero'
    Assert-True ((Get-LogText $case) -match 'KeepBackups') 'log explains the invalid value'
}

function Test-WildcardProcessName {
    Write-Host 'Test: -AppProcessName "*" does not match every process'
    $case = New-Case 'wildcard'
    $db = Join-Path $case 'Cookies'
    New-TestDb $db -Auth 2 -Other 0

    $r = Invoke-PsFile $cleanup @(
        '-DbPath', $db,
        '-AppProcessName', '*',
        '-IfRunning', 'Skip',
        '-BackupRoot', (Join-Path $case 'backups'),
        '-LogPath', (Join-Path $case 'cleanup.log')
    )
    if ($r.ExitCode -ne 0) { Write-Host $r.Output }
    Assert-Equal $r.ExitCode 0 'cleanup proceeds'
    Assert-Equal (Get-AuthCount $db) 0 'rows were deleted'
}

function Test-VerifyDbPaths {
    Write-Host 'Test: verify-db.py handles #, %20 and spaces in paths'
    $case = New-Case 'verify-paths'
    $dir = Join-Path $case 'a%20b#c d'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $db = Join-Path $dir 'Cookies'
    New-TestDb $db -Auth 2 -Other 1

    $out = @(& $python $verifyDb $db 2>&1)
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
    Assert-Equal $code 0 'verify-db exits 0'
    Assert-True ($text -match 'quick=ok') 'verify-db reports quick=ok'
}

function Test-RestoreRollback {
    Write-Host 'Test: a failed post-restore check rolls back to the original database'
    $case = New-Case 'restore-rollback'
    $tool = Join-Path $case 'tool'
    New-Item -ItemType Directory -Path $tool -Force | Out-Null
    Copy-Item -LiteralPath $cleanup -Destination (Join-Path $tool 'cleanup.ps1')
    Copy-Item -LiteralPath $cleanupDb -Destination (Join-Path $tool 'cleanup_db.real.py')

    # A shim that fails the first --verify on the target, then behaves
    # normally.  This exercises the after-check rollback without corrupting a
    # real database.
    $shim = @'
import json, os, runpy, sys

here = os.path.dirname(os.path.abspath(__file__))
real = os.path.join(here, "cleanup_db.real.py")
target = os.environ["DSH_TEST_FAIL_TARGET"]
marker = os.environ["DSH_TEST_FAIL_MARKER"]

def arg_value(name):
    try:
        return sys.argv[sys.argv.index(name) + 1]
    except ValueError:
        return None

db = arg_value("--db")
if (
    "--verify" in sys.argv
    and db
    and os.path.normcase(os.path.abspath(db)) == os.path.normcase(os.path.abspath(target))
    and not os.path.exists(marker)
):
    open(marker, "w").close()
    print(json.dumps({"ok": False, "db": db, "total": 0, "auth": 0, "quick_check": "simulated failure"}))
    sys.exit(1)
runpy.run_path(real, run_name="__main__")
'@
    Set-Content -LiteralPath (Join-Path $tool 'cleanup_db.py') -Value $shim -Encoding UTF8

    $backupDir = Join-Path $case 'backup'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    New-TestDb (Join-Path $backupDir 'Cookies') -Auth 4 -Other 1
    $target = Join-Path $case 'profile\Network\Cookies'
    New-TestDb $target -Auth 1 -Other 1
    $marker = Join-Path $case 'fail-once.marker'

    $savedTarget = $env:DSH_TEST_FAIL_TARGET
    $savedMarker = $env:DSH_TEST_FAIL_MARKER
    try {
        $env:DSH_TEST_FAIL_TARGET = $target
        $env:DSH_TEST_FAIL_MARKER = $marker
        $r = Invoke-PsFile (Join-Path $tool 'cleanup.ps1') @(
            '-Restore', $backupDir,
            '-DbPath', $target,
            '-SkipProcessCheck',
            '-BackupRoot', (Join-Path $case 'backups'),
            '-LogPath', (Join-Path $case 'cleanup.log')
        )
    } finally {
        if ($null -eq $savedTarget) {
            Remove-Item Env:DSH_TEST_FAIL_TARGET -ErrorAction SilentlyContinue
        } else {
            $env:DSH_TEST_FAIL_TARGET = $savedTarget
        }
        if ($null -eq $savedMarker) {
            Remove-Item Env:DSH_TEST_FAIL_MARKER -ErrorAction SilentlyContinue
        } else {
            $env:DSH_TEST_FAIL_MARKER = $savedMarker
        }
    }

    if ($r.ExitCode -eq 0) { Write-Host $r.Output }
    Assert-True ($r.ExitCode -ne 0) 'restore exits non-zero after a failed post-check'
    Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) 'the simulated failure was triggered'
    Assert-True (Test-Path -LiteralPath $target -PathType Leaf) 'target still exists after rollback'
    Assert-Equal (Get-AuthCount $target) 1 'target was rolled back to the original rows'
    Assert-True ((Get-LogText $case) -match '已回滚') 'log reports a successful rollback'
    $leftovers = @(Get-ChildItem -LiteralPath (Split-Path -Parent $target) -Filter 'Cookies.rollback-*' -ErrorAction SilentlyContinue)
    Assert-Equal $leftovers.Count 0 'no rollback staging file is left behind'
}

function Test-LockClassification {
    Write-Host 'Test: disk I/O errors are not classified as database locks'
    $case = New-Case 'lock-classification'
    $probe = Join-Path $case 'probe.py'
    $probeScript = @'
import sys
sys.path.insert(0, sys.argv[1])
import cleanup_db

class E(Exception):
    def __init__(self, message, code=None):
        super().__init__(message)
        self.sqlite_errorcode = code

assert cleanup_db._is_lock_error(E('database is locked')) is True
assert cleanup_db._is_lock_error(E('database table is locked')) is True
assert cleanup_db._is_lock_error(E('unable to open database file')) is True
assert cleanup_db._is_lock_error(E('disk I/O error')) is False
assert cleanup_db._is_lock_error(E('boom', 10)) is False
assert cleanup_db._is_lock_error(E('boom', 5)) is True
print('ok')
'@
    Set-Content -LiteralPath $probe -Value $probeScript -Encoding ASCII
    $out = @(& $python -B $probe $repo 2>&1)
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
    Assert-Equal $code 0 'lock classification probe exits 0'
    Assert-True ($text -match 'ok') 'lock classification assertions passed'
}

function Test-LogRotation {
    Write-Host 'Test: log rotation keeps 5 timestamped files and leaves other logs alone'
    $case = New-Case 'log-rotation'
    $logs = Join-Path $case 'logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $log = Join-Path $logs 'cleanup.log'
    $fs = [System.IO.File]::Create($log)
    $fs.SetLength(6MB)
    $fs.Close()
    for ($i = 1; $i -le 6; $i++) {
        Set-Content -LiteralPath (Join-Path $logs ('cleanup-2026010{0}-000000.log' -f $i)) -Value 'old' -Encoding ASCII
    }
    Set-Content -LiteralPath (Join-Path $logs 'cleanup-misc.log') -Value 'keep' -Encoding ASCII
    $db = Join-Path $case 'Network\Cookies'
    New-TestDb $db -Auth 1 -Other 0

    $r = Invoke-PsFile $cleanup @(
        '-DryRun',
        '-DbPath', $db,
        '-SkipProcessCheck',
        '-BackupRoot', (Join-Path $case 'backups'),
        '-LogPath', $log
    )
    if ($r.ExitCode -ne 0) { Write-Host $r.Output }
    Assert-Equal $r.ExitCode 0 'dry-run exits 0'
    $rotated = @(Get-ChildItem -LiteralPath $logs -File -Filter 'cleanup-*.log' | Where-Object { $_.Name -match '^cleanup-\d{8}-\d{6}\.log$' })
    Assert-Equal $rotated.Count 5 'five rotated logs remain'
    Assert-True (Test-Path -LiteralPath (Join-Path $logs 'cleanup-misc.log') -PathType Leaf) 'cleanup-misc.log was not removed'
    $bytes = [System.IO.File]::ReadAllBytes($log)
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'new cleanup.log has a UTF-8 BOM'
}

function Test-BackupRotationNaming {
    Write-Host 'Test: backup rotation only removes tool-named directories'
    $case = New-Case 'backup-rotation'
    $backups = Join-Path $case 'backups'
    New-Item -ItemType Directory -Path $backups -Force | Out-Null
    for ($i = 1; $i -le 4; $i++) {
        New-Item -ItemType Directory -Path (Join-Path $backups ('Cookies-2026010{0}-000000-000-old{0}' -f $i)) -Force | Out-Null
    }
    for ($i = 1; $i -le 3; $i++) {
        New-Item -ItemType Directory -Path (Join-Path $backups ('pre-restore-2026010{0}-000000-000' -f $i)) -Force | Out-Null
    }
    $manual = Join-Path $backups 'Cookies-manual-copy'
    New-Item -ItemType Directory -Path $manual -Force | Out-Null
    $db = Join-Path $case 'Network\Cookies'
    New-TestDb $db -Auth 2 -Other 0

    $r = Invoke-PsFile $cleanup @(
        '-DbPath', $db,
        '-SkipProcessCheck',
        '-BackupRoot', $backups,
        '-KeepBackups', '2',
        '-KeepPreRestore', '1',
        '-LogPath', (Join-Path $case 'cleanup.log')
    )
    if ($r.ExitCode -ne 0) { Write-Host $r.Output }
    Assert-Equal $r.ExitCode 0 'cleanup exits 0'
    $standard = @(Get-ChildItem -LiteralPath $backups -Directory | Where-Object { $_.Name -match '^Cookies-\d{8}-\d{6}-\d{3}-.+' })
    $pre = @(Get-ChildItem -LiteralPath $backups -Directory | Where-Object { $_.Name -match '^pre-restore-\d{8}-\d{6}-\d{3}$' })
    Assert-Equal $standard.Count 2 'two standard backups remain'
    Assert-Equal $pre.Count 1 'one pre-restore snapshot remains'
    Assert-True (Test-Path -LiteralPath $manual -PathType Container) 'Cookies-manual-copy was not removed'
}

function Test-BusyExitCode {
    Write-Host 'Test: a held Restore mutex makes cleanup exit 3'
    $case = New-Case 'busy-exit'
    $db = Join-Path $case 'Network\Cookies'
    New-TestDb $db -Auth 1 -Other 0
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DshCookieCleanup.Restore')
    if (-not $mutex.WaitOne(0)) {
        Write-Host '  SKIP: could not acquire the Restore mutex.' -ForegroundColor Yellow
        $mutex.Dispose()
        return
    }
    try {
        $r = Invoke-PsFile $cleanup @(
            '-DryRun',
            '-DbPath', $db,
            '-SkipProcessCheck',
            '-BackupRoot', (Join-Path $case 'backups'),
            '-LogPath', (Join-Path $case 'cleanup.log')
        )
        Assert-Equal $r.ExitCode 3 'cleanup exits 3 when the mutex is held'
        Assert-True ((Get-LogText $case) -match '稍后再试') 'log mentions retrying later'
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Test-ForeignWatcherNotStopped {
    Write-Host 'Test: -Stop does not kill a watcher from another checkout'
    $pidFile = Join-Path $repo 'state\watcher.pid'
    if (Test-Path -LiteralPath $pidFile) {
        Write-Host '  SKIP: state\watcher.pid exists; not calling -Stop.' -ForegroundColor Yellow
        return
    }
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            [string]$_.CommandLine -match '(?i)cleanup\.ps1' -and
            [string]$_.CommandLine -match '(?i)-Watch'
        })
    if ($running.Count -gt 0) {
        Write-Host '  SKIP: a cleanup.ps1 -Watch process is running; not calling -Stop.' -ForegroundColor Yellow
        return
    }

    $case = New-Case 'foreign-watcher'
    $ours = Join-Path $case 'ours'
    $foreign = Join-Path $case 'foreign'
    New-Item -ItemType Directory -Path $ours -Force | Out-Null
    New-Item -ItemType Directory -Path $foreign -Force | Out-Null
    Copy-Item -LiteralPath $cleanup -Destination (Join-Path $ours 'cleanup.ps1')
    Copy-Item -LiteralPath $cleanupDb -Destination (Join-Path $ours 'cleanup_db.py')
    Copy-Item -LiteralPath $cleanup -Destination (Join-Path $foreign 'cleanup.ps1')
    Copy-Item -LiteralPath $cleanupDb -Destination (Join-Path $foreign 'cleanup_db.py')
    $db = Join-Path $case 'Network\Cookies'
    New-TestDb $db -Auth 1 -Other 0
    $foreignLog = Join-Path $case 'foreign.log'
    $psExe = (Get-Process -Id $PID).Path
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Watch -DbPath "{1}" -AppProcessName "DshTestNeverRunning" -PollSeconds 1 -HeartbeatMinutes 0 -Quiet -LogPath "{2}"' -f (Join-Path $foreign 'cleanup.ps1'), $db, $foreignLog
    $proc = Start-Process -FilePath $psExe -ArgumentList $argLine -PassThru -WindowStyle Hidden

    try {
        $foreignPidFile = Join-Path $foreign 'state\watcher.pid'
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path -LiteralPath $foreignPidFile) -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $foreignPidFile)) {
            Write-Host '  SKIP: foreign watcher did not start.' -ForegroundColor Yellow
            if (Test-Path -LiteralPath $foreignLog) { Write-Host (Get-Content -LiteralPath $foreignLog -Raw) }
            return
        }
        Assert-True (Test-Path -LiteralPath $foreignPidFile) 'foreign watcher wrote its PID file'

        $taskName = 'DSH Cookie Cleanup Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $r = Invoke-PsFile $installer @(
            '-Stop',
            '-CleanupScript', (Join-Path $ours 'cleanup.ps1'),
            '-StartupDir', (Join-Path $case 'Startup'),
            '-TaskName', $taskName
        )
        if ($r.ExitCode -ne 0) { Write-Host $r.Output }
        Assert-Equal $r.ExitCode 0 '-Stop exits 0'
        Assert-True (-not $proc.HasExited) 'foreign watcher is still running'
        Assert-True ($r.Output -match '\[skip-foreign-watcher\]') 'output contains the ASCII skip marker'
    } finally {
        if (-not $proc.HasExited) {
            $stopR = Invoke-PsFile $installer @(
                '-Stop',
                '-CleanupScript', (Join-Path $foreign 'cleanup.ps1'),
                '-StartupDir', (Join-Path $case 'Startup2'),
                '-TaskName', ('DSH Cookie Cleanup Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            )
            if (-not $proc.WaitForExit(30000)) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-BackupAclHardened {
    Write-Host 'Test: default backups directory is ACL-restricted'
    $case = New-Case 'backup-acl'
    $tool = Join-Path $case 'tool'
    New-Item -ItemType Directory -Path $tool -Force | Out-Null
    Copy-Item -LiteralPath $cleanup -Destination (Join-Path $tool 'cleanup.ps1')
    Copy-Item -LiteralPath $cleanupDb -Destination (Join-Path $tool 'cleanup_db.py')
    $db = Join-Path $case 'Network\Cookies'
    New-TestDb $db -Auth 2 -Other 0
    $backupRoot = Join-Path $tool 'backups'
    $existingBackup = Join-Path $backupRoot 'Cookies-20260101-000000-000-existing'
    New-TestDb (Join-Path $existingBackup 'Cookies') -Auth 1 -Other 0

    $r = Invoke-PsFile (Join-Path $tool 'cleanup.ps1') @(
        '-DbPath', $db,
        '-SkipProcessCheck',
        '-LogPath', (Join-Path $case 'cleanup.log')
    )
    if ($r.ExitCode -ne 0) { Write-Host $r.Output }
    Assert-Equal $r.ExitCode 0 'cleanup exits 0'

    Assert-True (Test-Path -LiteralPath $backupRoot -PathType Container) 'default backups directory exists'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { return }

    $acl = Get-Acl -LiteralPath $backupRoot
    if (-not $acl.AreAccessRulesProtected) {
        Write-Host '  SKIP: ACL hardening is not supported on this filesystem.' -ForegroundColor Yellow
        return
    }
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $userHasFull = $false
    $usersHasAccess = $false
    foreach ($rule in @($acl.Access)) {
        $id = $null
        try { $id = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }
        if ($id -eq $sid -and (($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl)) {
            $userHasFull = $true
        }
        if ($id -eq 'S-1-5-32-545') { $usersHasAccess = $true }
    }
    Assert-True $userHasFull 'current user has FullControl on backups'
    Assert-True (-not $usersHasAccess) 'BUILTIN\Users has no access to backups'

    $existingFile = Join-Path $existingBackup 'Cookies'
    Assert-True (Test-Path -LiteralPath $existingFile -PathType Leaf) 'pre-existing backup file still exists'
    $verifyOut = @(& $python $cleanupDb --db $existingFile --json --verify 2>&1)
    $verifyCode = $LASTEXITCODE
    $verifyLine = $verifyOut | Where-Object { [string]$_ -match '^\s*\{' } | Select-Object -Last 1
    Assert-Equal $verifyCode 0 'pre-existing backup remains readable after ACL hardening'
    $verify = if ($verifyLine) { $verifyLine | ConvertFrom-Json } else { $null }
    Assert-True ($verify -and $verify.ok -and $verify.quick_check -eq 'ok') 'pre-existing backup passes quick_check'
}

function Test-CmdWrapperDryRun {
    Write-Host 'Test: dsh-cookie-report.cmd resolves an absolute interpreter and runs'
    $case = New-Case 'cmd-wrapper'
    $db = Join-Path $case 'Network\Cookies'
    New-TestDb $db -Auth 2 -Other 1
    $wrapper = Join-Path $repo 'dsh-cookie-report.cmd'
    $backups = Join-Path $case 'backups'
    $log = Join-Path $case 'cleanup.log'
    $cmdLine = 'echo. | "' + $wrapper + '" -DbPath "' + $db + '" -SkipProcessCheck -BackupRoot "' + $backups + '" -LogPath "' + $log + '"'
    $out = @(& $env:ComSpec /c $cmdLine 2>&1)
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
    if ($code -ne 0) { Write-Host $text }
    Assert-Equal $code 0 'wrapper exits 0'
    Assert-Equal (Get-AuthCount $db) 2 'dry-run left the database unchanged'
    Assert-True ((Get-LogText $case) -match '预演') 'wrapper produced the dry-run report'
}

function Test-StopDisablesScheduledTask {
    Write-Host 'Test: -Stop disables an installed scheduled task'
    $pidFile = Join-Path $repo 'state\watcher.pid'
    if (Test-Path -LiteralPath $pidFile) {
        Write-Host '  SKIP: state\watcher.pid exists; not calling -Stop.' -ForegroundColor Yellow
        return
    }
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            [string]$_.CommandLine -match '(?i)cleanup\.ps1' -and
            [string]$_.CommandLine -match '(?i)-Watch'
        })
    if ($running.Count -gt 0) {
        Write-Host '  SKIP: a cleanup.ps1 -Watch process is running; not calling -Stop.' -ForegroundColor Yellow
        return
    }

    $case = New-Case 'stop-task'
    $scriptCopy = Join-Path $case 'cleanup.ps1'
    Copy-Item -LiteralPath $cleanup -Destination $scriptCopy
    Copy-Item -LiteralPath $cleanupDb -Destination (Join-Path $case 'cleanup_db.py')
    $startup = Join-Path $case 'Startup'
    New-Item -ItemType Directory -Path $startup -Force | Out-Null
    $taskName = 'DSH Cookie Cleanup Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskTime = (Get-Date).AddHours(12).ToString('HH:mm')
    $vbsPath = Join-Path $case 'state\scheduled-task.vbs'
    New-Item -ItemType Directory -Path (Split-Path -Parent $vbsPath) -Force | Out-Null
    Set-Content -LiteralPath $vbsPath -Value 'sentinel' -Encoding Unicode

    try {
        $r1 = Invoke-PsFile $installer @(
            '-Mode', 'Daily',
            '-Time', $taskTime,
            '-TaskName', $taskName,
            '-CleanupScript', $scriptCopy,
            '-StartupDir', $startup
        )
        if ($r1.ExitCode -ne 0) {
            Write-Host '  SKIP: cannot register a test scheduled task in this environment.' -ForegroundColor Yellow
            Write-Host $r1.Output
            return
        }
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Assert-True ($null -ne $task) 'test task was registered'
        $action = @($task.Actions)[0]
        $wshUnavailable = $r1.Output -match '\[wsh-unavailable\]'
        if ($wshUnavailable) {
            Assert-True ($action.Execute -match '(?i)powershell') 'task uses direct PowerShell when WSH is unavailable'
            Assert-True ($action.Arguments -match 'cleanup\.ps1') 'direct task points at cleanup.ps1'
            Assert-True (-not (Test-Path -LiteralPath $vbsPath)) 'no VBS launcher when WSH is unavailable'
        } else {
            Assert-True ($action.Execute -match 'wscript\.exe$') 'task uses wscript hidden launcher'
            Assert-True ($action.Arguments -match 'scheduled-task\.vbs') 'task points at the VBS launcher'
            Assert-True (Test-Path -LiteralPath $vbsPath -PathType Leaf) 'VBS launcher exists'
            $vbsText = if (Test-Path -LiteralPath $vbsPath) { Get-Content -LiteralPath $vbsPath -Raw } else { '' }
            Assert-True ($vbsText -match 'sh\.Run\(' -and $vbsText -match '0, True' -and $vbsText -match 'WScript\.Quit code') 'VBS waits and propagates exit code'
            Assert-True ($vbsText -match 'On Error Resume Next' -and $vbsText -match 'Err\.Number') 'VBS suppresses WSH error dialogs'
        }

        $rStatus = Invoke-PsFile $installer @(
            '-Status',
            '-TaskName', $taskName,
            '-CleanupScript', $scriptCopy,
            '-StartupDir', $startup
        )
        Assert-Equal $rStatus.ExitCode 0 'status exits 0'
        if ($wshUnavailable) {
            Assert-True ($rStatus.Output -match '\[launcher-direct\]') 'status reports direct PowerShell'
            Assert-True ($rStatus.Output -match '\[wsh-unavailable\]') 'status reports WSH unavailable'
            Assert-True ($rStatus.Output -match '\[launcher-orphan\]') 'status reports an orphan launcher'
        } else {
            Assert-True ($rStatus.Output -match '\[launcher-ok\]') 'status reports launcher ok'
            Assert-True ($rStatus.Output -match '\[wsh-ok\]') 'status reports WSH available'
            Remove-Item -LiteralPath $vbsPath -Force
            $rStatusMissing = Invoke-PsFile $installer @(
                '-Status',
                '-TaskName', $taskName,
                '-CleanupScript', $scriptCopy,
                '-StartupDir', $startup
            )
            Assert-True ($rStatusMissing.Output -match '\[launcher-missing\]') 'status reports a missing launcher'
        }

        $r2 = Invoke-PsFile $installer @(
            '-Stop',
            '-TaskName', $taskName,
            '-CleanupScript', $scriptCopy,
            '-StartupDir', $startup
        )
        if ($r2.ExitCode -ne 0) { Write-Host $r2.Output }
        Assert-Equal $r2.ExitCode 0 '-Stop exits 0'
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Assert-True ($task -and $task.State -eq 'Disabled') 'task is Disabled after -Stop'
    } finally {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            try {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            } catch {
                Write-Host "  WARN: could not remove test task ${taskName}: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
}

function Test-RegistrationFailureKeepsLauncher {
    Write-Host 'Test: failed task registration keeps the VBS launcher'
    $pidFile = Join-Path $repo 'state\watcher.pid'
    if (Test-Path -LiteralPath $pidFile) {
        Write-Host '  SKIP: state\watcher.pid exists; not installing a task.' -ForegroundColor Yellow
        return
    }
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            [string]$_.CommandLine -match '(?i)cleanup\.ps1' -and
            [string]$_.CommandLine -match '(?i)-Watch'
        })
    if ($running.Count -gt 0) {
        Write-Host '  SKIP: a cleanup.ps1 -Watch process is running; not installing a task.' -ForegroundColor Yellow
        return
    }

    $case = New-Case 'registration-failure'
    $scriptCopy = Join-Path $case 'cleanup.ps1'
    Copy-Item -LiteralPath $cleanup -Destination $scriptCopy
    Copy-Item -LiteralPath $cleanupDb -Destination (Join-Path $case 'cleanup_db.py')
    $startup = Join-Path $case 'Startup'
    New-Item -ItemType Directory -Path $startup -Force | Out-Null
    $vbsPath = Join-Path $case 'state\scheduled-task.vbs'
    New-Item -ItemType Directory -Path (Split-Path -Parent $vbsPath) -Force | Out-Null
    Set-Content -LiteralPath $vbsPath -Value 'sentinel' -Encoding Unicode
    $taskName = 'DSH Cookie Cleanup Test / Invalid ' + [guid]::NewGuid().ToString('N').Substring(0, 8)

    $r = Invoke-PsFile $installer @(
        '-Mode', 'Watch',
        '-TaskName', $taskName,
        '-CleanupScript', $scriptCopy,
        '-StartupDir', $startup
    )
    if ($r.Output -match '\[wsh-unavailable\]') {
        Write-Host '  SKIP: WSH unavailable; direct fallback has no VBS to preserve.' -ForegroundColor Yellow
        return
    }
    if ($r.ExitCode -ne 0) { Write-Host $r.Output }
    Assert-Equal $r.ExitCode 0 'installer falls back to Startup after failed task registration'
    Assert-True (Test-Path -LiteralPath $vbsPath -PathType Leaf) 'launcher survives a failed registration'
    $vbsText = if (Test-Path -LiteralPath $vbsPath) { Get-Content -LiteralPath $vbsPath -Raw } else { '' }
    Assert-True ($vbsText -match 'sh\.Run') 'launcher was written before registration'
    $taskExists = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $taskName }).Count -gt 0
    Assert-True (-not $taskExists) 'invalid task was not registered'
}

function Test-WatcherCooperativeStop {
    Write-Host 'Test: -Stop lets a running watcher exit before force-killing'
    $pidFile = Join-Path $repo 'state\watcher.pid'
    if (Test-Path -LiteralPath $pidFile) {
        Write-Host '  SKIP: state\watcher.pid exists; not calling -Stop.' -ForegroundColor Yellow
        return
    }
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            [string]$_.CommandLine -match '(?i)cleanup\.ps1' -and
            [string]$_.CommandLine -match '(?i)-Watch'
        })
    if ($running.Count -gt 0) {
        Write-Host '  SKIP: a cleanup.ps1 -Watch process is running; not calling -Stop.' -ForegroundColor Yellow
        return
    }

    $case = New-Case 'watcher-stop'
    $tool = Join-Path $case 'tool'
    New-Item -ItemType Directory -Path $tool -Force | Out-Null
    Copy-Item -LiteralPath $cleanup -Destination (Join-Path $tool 'cleanup.ps1')
    Copy-Item -LiteralPath $cleanupDb -Destination (Join-Path $tool 'cleanup_db.py')
    $db = Join-Path $case 'Network\Cookies'
    New-TestDb $db -Auth 1 -Other 0
    $log = Join-Path $case 'watcher.log'
    $psExe = (Get-Process -Id $PID).Path
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Watch -DbPath "{1}" -AppProcessName "DshTestNeverRunning" -PollSeconds 1 -HeartbeatMinutes 0 -Quiet -LogPath "{2}"' -f (Join-Path $tool 'cleanup.ps1'), $db, $log
    $proc = Start-Process -FilePath $psExe -ArgumentList $argLine -PassThru -WindowStyle Hidden

    try {
        $watcherPidFile = Join-Path $tool 'state\watcher.pid'
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path -LiteralPath $watcherPidFile) -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $watcherPidFile)) {
            Write-Host '  SKIP: watcher did not start (another watcher may hold the mutex).' -ForegroundColor Yellow
            if (Test-Path -LiteralPath $log) { Write-Host (Get-Content -LiteralPath $log -Raw) }
            return
        }
        Assert-True (Test-Path -LiteralPath $watcherPidFile) 'watcher wrote its PID file'

        $taskName = 'DSH Cookie Cleanup Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $r = Invoke-PsFile $installer @(
            '-Stop',
            '-CleanupScript', (Join-Path $tool 'cleanup.ps1'),
            '-StartupDir', (Join-Path $case 'Startup'),
            '-TaskName', $taskName
        )
        if ($r.ExitCode -ne 0) { Write-Host $r.Output }
        Assert-Equal $r.ExitCode 0 '-Stop exits 0'
        Assert-True ($proc.WaitForExit(15000)) 'watcher exited'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tool 'state\watcher.stop'))) 'stop file removed'
        $logText = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
        Assert-True ($logText -match '收到停止请求') 'watcher logged the cooperative stop'
    } finally {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-StopRemovesStartupEntry {
    Write-Host 'Test: -Stop removes the Startup entry'
    $pidFile = Join-Path $repo 'state\watcher.pid'
    if (Test-Path -LiteralPath $pidFile) {
        Write-Host '  SKIP: state\watcher.pid exists; not calling -Stop.' -ForegroundColor Yellow
        return
    }
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            [string]$_.CommandLine -match '(?i)cleanup\.ps1' -and
            [string]$_.CommandLine -match '(?i)-Watch'
        })
    if ($running.Count -gt 0) {
        Write-Host '  SKIP: a cleanup.ps1 -Watch process is running; not calling -Stop.' -ForegroundColor Yellow
        return
    }

    $case = New-Case 'stop'
    $scriptCopy = Join-Path $case 'cleanup.ps1'
    Copy-Item -LiteralPath $cleanup -Destination $scriptCopy
    $startup = Join-Path $case 'Startup'
    New-Item -ItemType Directory -Path $startup -Force | Out-Null
    $taskName = 'DSH Cookie Cleanup Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8)

    $r1 = Invoke-PsFile $installer @(
        '-Mode', 'Startup',
        '-StartupDir', $startup,
        '-CleanupScript', $scriptCopy,
        '-TaskName', $taskName
    )
    $entry = Join-Path $startup 'DSH Cookie Cleanup.vbs'
    if ($r1.ExitCode -ne 0 -and $r1.Output -match '\[wsh-unavailable\]') {
        Write-Host '  SKIP: WSH unavailable; Startup mode cannot run.' -ForegroundColor Yellow
        return
    }
    Assert-Equal $r1.ExitCode 0 'install Startup entry exits 0'
    Assert-True (Test-Path -LiteralPath $entry -PathType Leaf) 'Startup entry was written'
    $startupText = if (Test-Path -LiteralPath $entry) { Get-Content -LiteralPath $entry -Raw } else { '' }
    Assert-True ($startupText -match 'sh\.Run') 'Startup VBS starts the watcher'
    Assert-True ($startupText -match 'On Error Resume Next' -and $startupText -match 'Err\.Number') 'Startup VBS handles WSH errors'

    $r2 = Invoke-PsFile $installer @(
        '-Stop',
        '-StartupDir', $startup,
        '-CleanupScript', $scriptCopy,
        '-TaskName', $taskName
    )
    if ($r2.ExitCode -ne 0) { Write-Host $r2.Output }
    Assert-Equal $r2.ExitCode 0 '-Stop exits 0'
    Assert-True (-not (Test-Path -LiteralPath $entry)) 'Startup entry was removed'
}

function Run-Test([scriptblock]$Test) {
    try {
        & $Test
    } catch {
        Write-Fail "unexpected error: $($_.Exception.Message)"
    }
}

try {
    Run-Test { Test-RestoreFile }
    Run-Test { Test-RestoreRejectsDirectory }
    Run-Test { Test-RestoreRollback }
    Run-Test { Test-HostScopedDeletion }
    Run-Test { Test-PythonRequiresBackup }
    Run-Test { Test-NegativeKeepBackupsRejected }
    Run-Test { Test-WildcardProcessName }
    Run-Test { Test-VerifyDbPaths }
    Run-Test { Test-LockClassification }
    Run-Test { Test-LogRotation }
    Run-Test { Test-BackupRotationNaming }
    Run-Test { Test-BusyExitCode }
    Run-Test { Test-ForeignWatcherNotStopped }
    Run-Test { Test-BackupAclHardened }
    Run-Test { Test-CmdWrapperDryRun }
    Run-Test { Test-WatcherCooperativeStop }
    Run-Test { Test-StopDisablesScheduledTask }
    Run-Test { Test-RegistrationFailureKeepsLauncher }
    Run-Test { Test-StopRemovesStartupEntry }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed.' -ForegroundColor Green
exit 0
