#requires -Version 5.1
<#
.SYNOPSIS
  Install or remove the automatic DSH cookie cleanup.

.DESCRIPTION
  Watch (default) - start a hidden watcher at logon.  It waits for DeepSeek
  Harness to exit, deletes the stale dsh-auth-* cookies, then waits for the
  next run.  This is the only automatic mode that works regardless of how the
  app was started, because it cleans at the moment the cookie database is not
  locked by Electron.

  Daily - run once a day at the given time through Task Scheduler.  The
  cleanup skips itself while the app is running.

  Startup - force the logon watcher without touching Task Scheduler.

  If Task Scheduler is unavailable (some managed or restricted machines), the
  Watch mode automatically falls back to a hidden script in the Startup
  folder.  Both routes start the same watcher.  The fallback needs Windows
  Script Host; if WSH is also unavailable, installation fails with a clear
  error instead of leaving a broken launcher.

.PARAMETER Mode
  Watch, Daily, or Startup.  Watch and Daily use a hidden wscript/VBS launcher
  so the watcher starts with no console window; the VBS waits for the watcher
  and returns its exit code to Task Scheduler.  If Windows Script Host is
  unavailable, Watch/Daily register a direct PowerShell action instead (a
  console window may appear) and print a warning.

.PARAMETER Time
  HH:mm for Daily mode.  Default 04:00.

.PARAMETER TaskName
  Scheduled task name.  Default "DSH Cookie Cleanup".

.PARAMETER CleanupScript
  Path to cleanup.ps1 used by the installed watcher.  Default: <script>\cleanup.ps1.

.PARAMETER StartupDir
  Startup-folder directory for the logon watcher.  Default: the current user's
  Startup folder.

.PARAMETER AppProcessName
  Process name to watch.  Passed through to the watcher; quotes and newlines
  are rejected.

.PARAMETER Stop
  Stop the running watcher and disable the auto-start mechanisms: disable the
  scheduled task and remove the Startup-folder entry.  The watcher is asked to
  exit cooperatively first (up to 30 seconds) before a force-stop.  Backups and
  logs are kept; use -Uninstall to remove the task entirely.

.PARAMETER Uninstall
  Remove the scheduled task and the Startup-folder watcher.

.PARAMETER RunNow
  Start the installed watcher immediately.

.PARAMETER Status
  Show what is installed, the task launcher state (present/missing/invalid),
  WSH availability, and its last/next run times.

.PARAMETER AllProfiles
  Pass -AllProfiles to the watcher so it also cleans the partition cookie
  databases.

.PARAMETER KeepBackups
  Number of normal backup folders the watcher keeps.  Default 30.

.PARAMETER KeepPreRestore
  Number of pre-restore snapshots kept separately.  Default 5.

.PARAMETER PollSeconds
  Watcher process-poll interval.  Default 5.

.PARAMETER HeartbeatMinutes
  Watcher heartbeat interval.  Default 10; 0 disables it.

.PARAMETER HeartbeatThreshold
  Heartbeat cleans only above this many dsh-auth-* rows.  Default 5.

.EXAMPLE
  .\install-task.ps1
  .\install-task.ps1 -Mode Daily -Time 03:30
  .\install-task.ps1 -Status
  .\install-task.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Watch', 'Daily', 'Startup')]
    [string]$Mode = 'Watch',
    [string]$Time = '04:00',
    [string]$TaskName = 'DSH Cookie Cleanup',
    [string]$CleanupScript,
    [string]$StartupDir,
    [string]$AppProcessName = 'DeepSeek Harness',
    [switch]$AllProfiles,
    [int]$PollSeconds = 5,
    [int]$KeepBackups = 30,
    [int]$KeepPreRestore = 5,
    [int]$HeartbeatMinutes = 10,
    [int]$HeartbeatThreshold = 5,
    [switch]$Uninstall,
    [switch]$Stop,
    [switch]$RunNow,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
$script:InstalledKind = $null
$script:WatcherExtraArgs = ''

# Resolve before -Status/-Stop/-Uninstall so watcher matching uses the full
# script path, not a bare "cleanup.ps1" that also matches an unrelated shell.
if (-not $CleanupScript) { $CleanupScript = Join-Path $PSScriptRoot 'cleanup.ps1' }
$CleanupScript = [System.IO.Path]::GetFullPath($CleanupScript)

# The process name is embedded in both a scheduled-task argument string and a
# VBScript string literal.  Quotes and newlines would break out of one or both.
if ($AppProcessName -match '[\r\n"]') {
    throw '-AppProcessName 不能包含引号或换行。'
}

function Get-StartupFolder {
    if ($StartupDir) { return [System.IO.Path]::GetFullPath($StartupDir) }
    $folder = [Environment]::GetFolderPath('Startup')
    if (-not $folder) {
        $folder = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    }
    return $folder
}

function Get-StartupEntry {
    Join-Path (Get-StartupFolder) 'DSH Cookie Cleanup.vbs'
}

function Get-TaskInfo {
    try {
        return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-WatcherPidFile {
    $dir = $PSScriptRoot
    if ($CleanupScript) { $dir = Split-Path -Parent $CleanupScript }
    return Join-Path $dir 'state\watcher.pid'
}

function Get-WatcherProcesses {
    $result = @()

    # The watcher writes its own PID, so a manually started relative-path
    # watcher is still visible even when CIM cannot be queried.
    $pidFile = Get-WatcherPidFile
    if (Test-Path -LiteralPath $pidFile) {
        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $pidFile -ErrorAction Stop) } catch { }
        $watchPid = 0
        $watchStart = 0L
        $valid = $false
        if ($lines.Count -ge 1 -and [int]::TryParse(([string]$lines[0]).Trim(), [ref]$watchPid)) {
            if ($lines.Count -ge 2) {
                [void][long]::TryParse(([string]$lines[1]).Trim(), [ref]$watchStart)
            }
            $proc = Get-Process -Id $watchPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match '^(powershell|pwsh)$') {
                $currentStart = 0L
                try { $currentStart = $proc.StartTime.ToFileTimeUtc() } catch { }
                $startMatches = ($watchStart -le 0) -or ($currentStart -eq $watchStart)
                if ($startMatches -and $currentStart -gt 0) {
                    $result += [pscustomobject]@{ ProcessId = $watchPid; StartTimeUtc = $currentStart; Source = 'PidFile' }
                    $valid = $true
                }
            }
        }
        if (-not $valid) {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            $stateDir = Split-Path -Parent $pidFile
            if ((Test-Path -LiteralPath $stateDir) -and @(Get-ChildItem -LiteralPath $stateDir -Force).Count -eq 0) {
                Remove-Item -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $savedWhatIf = $WhatIfPreference
    # Module autoloading inside Get-CimInstance inherits -WhatIf and produces
    # "What if: ... setting alias" noise; suppress it for this query only.
    $WhatIfPreference = $false
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop
    } catch {
        $procs = @()
    } finally {
        $WhatIfPreference = $savedWhatIf
    }

    $expected = $CleanupScript.Replace('/', '\')
    $relativeFile = '(?i)-File\s+["'']?[^"''\s]*cleanup\.ps1["'']?(?=\s|$)'
    $relativeAmp = '(?i)&\s+["'']?[^"''\s]*cleanup\.ps1["'']?(?=\s|$)'
    foreach ($proc in $procs) {
        $cmd = ([string]$proc.CommandLine).Replace('/', '\')
        $usesScript = $cmd.IndexOf($expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $cmd -match $relativeFile -or
            $cmd -match $relativeAmp
        if ($usesScript -and $cmd -match '(?i)(^|\s)-Watch(?=[\s"'']|$)') {
            $processId = [int]$proc.ProcessId
            if (@($result | Where-Object { $_.ProcessId -eq $processId }).Count -eq 0) {
                $gp = Get-Process -Id $processId -ErrorAction SilentlyContinue
                $start = 0L
                if ($gp) { try { $start = $gp.StartTime.ToFileTimeUtc() } catch { } }
                if ($start -gt 0) {
                    $result += [pscustomobject]@{ ProcessId = $processId; StartTimeUtc = $start; Source = 'Cim' }
                }
            }
        }
    }
    return $result
}

function Stop-WatcherProcesses {
    $watchers = @()
    $stopped = @()
    $stopFile = Join-Path (Split-Path -Parent (Get-WatcherPidFile)) 'watcher.stop'
    $expected = $CleanupScript.Replace('/', '\')

    # Get-WatcherProcesses also matches legacy/manual watchers by a bare
    # "cleanup.ps1 -Watch" command line.  Before touching anything, keep only
    # watchers that belong to this script (PID file in this directory, or an
    # exact command-line path).  This prevents -Stop from killing a watcher
    # belonging to another checkout.
    foreach ($proc in @(Get-WatcherProcesses)) {
        if ($proc.Source -eq 'PidFile') {
            $watchers += $proc
            continue
        }
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.ProcessId)" -ErrorAction SilentlyContinue
        $cmd = if ($cim) { ([string]$cim.CommandLine).Replace('/', '\') } else { '' }
        if ($cmd.IndexOf($expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $watchers += $proc
        } elseif ($cim) {
            Write-Host "[skip-foreign-watcher] 跳过监视器 PID $($proc.ProcessId)：命令行不属于当前脚本 $CleanupScript。" -ForegroundColor Yellow
        } else {
            Write-Host "[skip-foreign-watcher] 跳过监视器 PID $($proc.ProcessId)：无法读取命令行。" -ForegroundColor Yellow
        }
    }

    if ($WhatIfPreference) {
        foreach ($proc in $watchers) {
            Write-Host "将停止监视器进程 PID $($proc.ProcessId)"
        }
    }

    # Ask the watcher(s) to exit cooperatively first.  This avoids killing a
    # PowerShell process while its Python child is in the middle of a delete.
    if (-not $WhatIfPreference -and $watchers.Count -gt 0) {
        try {
            $stateDir = Split-Path -Parent $stopFile
            if (-not (Test-Path -LiteralPath $stateDir)) {
                New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            }
            $tokens = @($watchers | ForEach-Object { '{0}:{1}' -f $_.ProcessId, $_.StartTimeUtc })
            Set-Content -LiteralPath $stopFile -Value $tokens -Encoding ASCII
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                $alive = @($watchers | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
                if ($alive.Count -eq 0) { break }
                Start-Sleep -Milliseconds 500
            }
        } catch {
            Write-Host "发送停止请求失败: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    foreach ($proc in $watchers) {
        if ($WhatIfPreference) { continue }
        # Re-check PID identity immediately before killing: a PID can be
        # reused after the CIM/PID-file snapshot was taken.
        $current = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
        if (-not $current) {
            # Exited during the cooperative wait.
            continue
        }
        $same = $false
        if ($current.ProcessName -match '^(powershell|pwsh)$') {
            try { $same = ($current.StartTime.ToFileTimeUtc() -eq [long]$proc.StartTimeUtc) } catch { $same = $false }
        }
        if (-not $same) {
            Write-Host "跳过监视器 PID $($proc.ProcessId)：进程已退出或 PID 已被复用。" -ForegroundColor Yellow
            continue
        }
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $stopped += [int]$proc.ProcessId
            $gone = $false
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                Start-Sleep -Milliseconds 100
                if (-not (Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue)) {
                    $gone = $true
                    break
                }
            }
            if ($gone) {
                Write-Host "已停止监视器进程 PID $($proc.ProcessId)"
            } else {
                Write-Host "已发送终止，监视器 PID $($proc.ProcessId) 仍在退出。" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "停止监视器 PID $($proc.ProcessId) 失败: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (-not $WhatIfPreference) {
        if (Test-Path -LiteralPath $stopFile) {
            Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        }
        $pidFile = Get-WatcherPidFile
        if (Test-Path -LiteralPath $pidFile) {
            $first = ''
            try {
                $content = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop).Trim()
                $first = ($content -split "`r?`n")[0].Trim()
            } catch { }
            $watchPid = 0
            $remove = $true
            if ([int]::TryParse($first, [ref]$watchPid)) {
                $alive = Get-Process -Id $watchPid -ErrorAction SilentlyContinue
                $remove = (-not $alive) -or ($stopped -contains $watchPid)
            }
            if ($remove) {
                Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
                $stateDir = Split-Path -Parent $pidFile
                if ((Test-Path -LiteralPath $stateDir) -and @(Get-ChildItem -LiteralPath $stateDir -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

function Get-WshStatus {
    $result = [pscustomobject]@{
        Available   = $false
        Reason      = ''
        WScriptPath = $null
    }

    foreach ($hive in @('HKLM:', 'HKCU:')) {
        $settings = $null
        try {
            $settings = Get-ItemProperty -LiteralPath "$hive\SOFTWARE\Microsoft\Windows Script Host\Settings" -Name Enabled -ErrorAction Stop
        } catch { }
        if ($settings -and [string]$settings.Enabled -eq '0') {
            $scope = if ($hive -eq 'HKLM:') { '计算机策略' } else { '用户策略' }
            $result.Reason = "$scope 禁用了 Windows Script Host：$hive\...\Enabled=0"
            return $result
        }
    }

    $systemRoot = $env:SystemRoot
    if (-not $systemRoot) { $systemRoot = $env:windir }
    if (-not $systemRoot) { $systemRoot = 'C:\Windows' }
    foreach ($candidate in @(
        (Join-Path $systemRoot 'System32\wscript.exe'),
        (Join-Path $systemRoot 'Sysnative\wscript.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $result.Available = $true
            $result.WScriptPath = $candidate
            return $result
        }
    }
    $result.Reason = '找不到 wscript.exe'
    return $result
}

function Start-StartupWatcher {
    $wsh = Get-WshStatus
    if (-not $wsh.Available) {
        throw "Windows Script Host 不可用（$($wsh.Reason)），无法启动登录启动监视器。"
    }
    Start-Process -FilePath $wsh.WScriptPath -ArgumentList ('"{0}"' -f (Get-StartupEntry))
}

function Install-StartupWatcher {
    param([string]$PsExe, [string]$Script)

    $wsh = Get-WshStatus
    if (-not $wsh.Available) {
        $message = "Windows Script Host 不可用（$($wsh.Reason)），无法安装登录启动 VBS。 [wsh-unavailable]"
        if ($WhatIfPreference) {
            Write-Host $message -ForegroundColor Yellow
            return $false
        }
        throw $message
    }

    $folder = Get-StartupFolder
    $entry = Get-StartupEntry
    $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Watch -Quiet -WatchMinutes 0 -AppProcessName "{2}"{3}' -f $PsExe, $Script, $AppProcessName, $script:WatcherExtraArgs
    $escaped = $command.Replace('"', '""')
    $vbs = @(
        'On Error Resume Next',
        'Set sh = CreateObject("WScript.Shell")',
        'If Err.Number <> 0 Then WScript.Quit 1',
        ('sh.Run "{0}", 0, False' -f $escaped),
        'If Err.Number <> 0 Then WScript.Quit 1'
    ) -join "`r`n"

    if (-not $PSCmdlet.ShouldProcess($entry, '写入登录启动监视器')) {
        if ($WhatIfPreference) {
            Write-Host "将写入登录启动项: $entry"
        } else {
            Write-Host '已取消写入登录启动项。'
        }
        return $false
    }
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    Set-Content -LiteralPath $entry -Value $vbs -Encoding Unicode
    Write-Host "已安装登录启动监视器: $entry" -ForegroundColor Green
    $script:InstalledKind = 'Startup'
    return $true
}

function Remove-StartupWatcher {
    $entry = Get-StartupEntry
    if (Test-Path -LiteralPath $entry) {
        if ($PSCmdlet.ShouldProcess($entry, '删除登录启动监视器')) {
            Remove-Item -LiteralPath $entry -Force
            Write-Host "已删除登录启动监视器: $entry"
        }
    }
}

function Get-ScheduledTaskLauncherPath {
    $dir = Split-Path -Parent $CleanupScript
    return Join-Path $dir 'state\scheduled-task.vbs'
}

function Install-ScheduledTaskLauncher {
    param([string]$PsExe, [string]$Arguments)

    $path = Get-ScheduledTaskLauncherPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # wscript is a GUI-subsystem host, so the PowerShell watcher is created
    # with SW_HIDE instead of relying on -WindowStyle Hidden after a console
    # window already exists.  Run(..., 0, True) waits and returns the child's
    # exit code, which WScript.Quit propagates to Task Scheduler.
    $command = '"{0}" {1}' -f $PsExe, $Arguments
    $escaped = $command.Replace('"', '""')
    $vbs = @(
        'On Error Resume Next',
        'Set sh = CreateObject("WScript.Shell")',
        'If Err.Number <> 0 Then WScript.Quit 1',
        ('code = sh.Run("{0}", 0, True)' -f $escaped),
        'If Err.Number <> 0 Then WScript.Quit 1',
        'WScript.Quit code'
    ) -join "`r`n"
    Set-Content -LiteralPath $path -Value $vbs -Encoding Unicode
    return $path
}

function Remove-ScheduledTaskLauncher {
    $path = Get-ScheduledTaskLauncherPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $dir = Split-Path -Parent $path
    if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) {
        Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
    }
}

function Get-TaskLauncherPath {
    param($Task)
    $action = @($Task.Actions)[0]
    if (-not $action) { return $null }
    $argText = [string]$action.Arguments
    if ($argText -match '^\s*"([^"]+\.vbs)"') { return $Matches[1] }
    if ($argText -match '^\s*([^\s]+\.vbs)') { return $Matches[1] }
    return $null
}

function Get-VbsLauncherState {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        return 'invalid'
    }
    if ($text -match 'sh\.Run' -and $text -match 'WScript\.Quit') { return 'ok' }
    return 'invalid'
}

function Install-ScheduledTask {
    param([string]$PsExe, [string]$Script, [string]$TaskMode)

    if ($TaskMode -eq 'Watch') {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Watch -Quiet -WatchMinutes 0 -AppProcessName "{1}"{2}' -f $Script, $AppProcessName, $script:WatcherExtraArgs
        $description = '等待 DeepSeek Harness 退出后清理累积的 dsh-auth-* Cookie。'
    } else {
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            throw "时间格式应为 HH:mm，例如 04:00（收到: $Time）"
        }
        $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -IfRunning Skip -Quiet -AppProcessName "{1}"{2}' -f $Script, $AppProcessName, $script:WatcherExtraArgs
        $description = '每天定时清理 DeepSeek Harness 累积的 dsh-auth-* Cookie（应用运行时自动跳过）。'
    }

    $vbsPath = Get-ScheduledTaskLauncherPath
    $wsh = Get-WshStatus
    $useWscript = [bool]$wsh.Available
    $wscript = $wsh.WScriptPath
    if (-not $useWscript) {
        Write-Host "警告: Windows Script Host 不可用（$($wsh.Reason)）；计划任务将直接启动 PowerShell，可能出现控制台窗口。 [wsh-unavailable]" -ForegroundColor Yellow
    }

    # Ask before touching Task Scheduler so -WhatIf and a declined -Confirm do
    # not fall through to the Startup watcher.
    if (-not $PSCmdlet.ShouldProcess($TaskName, "注册计划任务（$TaskMode）")) {
        if ($WhatIfPreference) {
            Write-Host "将注册任务: $TaskName（$TaskMode）"
            if ($useWscript) {
                Write-Host "  隐藏启动器: $vbsPath"
                Write-Host "  程序: $wscript"
                Write-Host "  参数: `"$vbsPath`""
            } else {
                Write-Host "  程序: $PsExe"
                Write-Host "  参数: $arguments"
                Write-Host '  启动器: 直接 PowerShell（WSH 不可用） [launcher-direct]'
            }
            Write-Host "  watcher: $PsExe $arguments"
        } else {
            Write-Host '已取消注册计划任务。'
        }
        return 'Declined'
    }

    try {
        if ($TaskMode -eq 'Watch') {
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            $settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 5) `
                -Hidden
        } else {
            $trigger = New-ScheduledTaskTrigger -Daily -At $parsed
            $settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
                -Hidden
        }
        if ($useWscript) {
            [void](Install-ScheduledTaskLauncher -PsExe $PsExe -Arguments $arguments)
            $action = New-ScheduledTaskAction -Execute $wscript -Argument ('"{0}"' -f $vbsPath)
        } else {
            $action = New-ScheduledTaskAction -Execute $PsExe -Argument $arguments
        }
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $description -Force | Out-Null
    } catch {
        # A previous task may still point at the launcher.  Leave it in place;
        # -Uninstall removes it once the task is gone.
        Write-Host "注册计划任务失败: $($_.Exception.Message)" -ForegroundColor Yellow
        return 'Failed'
    }

    Write-Host "已注册计划任务: $TaskName（$TaskMode）" -ForegroundColor Green
    $script:InstalledKind = 'Task'
    return 'Installed'
}

if ($Status) {
    $task = Get-TaskInfo
    $taskUsesWscript = $false
    if ($task) {
        Write-Host "计划任务: $TaskName" -ForegroundColor Cyan
        $task | Select-Object TaskName, State | Format-List
        try {
            Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns | Format-List
        } catch { }
        $action = @($task.Actions)[0]
        if ($action -and [string]$action.Execute -match '(?i)(^|\\)wscript(\.exe)?$') {
            $taskUsesWscript = $true
            $launcherPath = Get-TaskLauncherPath $task
            if (-not $launcherPath) { $launcherPath = Get-ScheduledTaskLauncherPath }
            $launcherState = Get-VbsLauncherState $launcherPath
            switch ($launcherState) {
                'ok' {
                    Write-Host "启动器: $launcherPath [launcher-ok]" -ForegroundColor Cyan
                }
                'missing' {
                    Write-Host "启动器: 缺失 $launcherPath [launcher-missing]（任务启动会失败；重新运行安装，不要删除 state\）" -ForegroundColor Yellow
                }
                default {
                    Write-Host "启动器: 内容异常 $launcherPath [launcher-invalid]（重新运行安装）" -ForegroundColor Yellow
                }
            }
        } elseif ($action) {
            Write-Host '启动器: 直接 PowerShell，不使用 VBS [launcher-direct]' -ForegroundColor Cyan
            $orphanPath = Get-ScheduledTaskLauncherPath
            if (Test-Path -LiteralPath $orphanPath -PathType Leaf) {
                Write-Host "残留启动器: $orphanPath [launcher-orphan]（当前任务不使用；-Uninstall 会清理）" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host '计划任务: 未安装（或 Task Scheduler 不可用）'
    }
    $entry = Get-StartupEntry
    if (Test-Path -LiteralPath $entry) {
        Write-Host "登录启动监视器: $entry" -ForegroundColor Cyan
    } else {
        Write-Host '登录启动监视器: 未安装'
    }
    $watchers = @(Get-WatcherProcesses)
    if ($watchers.Count -gt 0) {
        Write-Host ('监视器进程: ' + (($watchers | ForEach-Object { $_.ProcessId }) -join ', ')) -ForegroundColor Cyan
    } else {
        Write-Host '监视器进程: 未检测到（未运行，或 CIM 查询不可用）'
    }
    if ($task -or (Test-Path -LiteralPath $entry)) {
        $wsh = Get-WshStatus
        if ($wsh.Available) {
            Write-Host 'WSH: 可用 [wsh-ok]' -ForegroundColor DarkGray
        } else {
            $wshNote = '（当前任务直接启动 PowerShell，不受影响）'
            if ($taskUsesWscript -or (Test-Path -LiteralPath $entry)) {
                $wshNote = '（VBS 启动会失败）'
            }
            Write-Host "WSH: 不可用（$($wsh.Reason)） [wsh-unavailable] $wshNote" -ForegroundColor Yellow
        }
    }
    exit 0
}

if ($PollSeconds -lt 1) { throw 'PollSeconds 必须 >= 1。' }
if ($KeepBackups -lt 0) { throw 'KeepBackups 必须 >= 0。' }
if ($KeepPreRestore -lt 0) { throw 'KeepPreRestore 必须 >= 0。' }
if ($HeartbeatMinutes -lt 0) { throw 'HeartbeatMinutes 必须 >= 0（0 表示关闭心跳）。' }
if ($HeartbeatThreshold -lt 0) { throw 'HeartbeatThreshold 必须 >= 0。' }

$extra = ''
if ($AllProfiles) { $extra += ' -AllProfiles' }
if ($PollSeconds -ne 5) { $extra += ' -PollSeconds ' + $PollSeconds }
if ($KeepBackups -ne 30) { $extra += ' -KeepBackups ' + $KeepBackups }
if ($KeepPreRestore -ne 5) { $extra += ' -KeepPreRestore ' + $KeepPreRestore }
if ($HeartbeatMinutes -ne 10) { $extra += ' -HeartbeatMinutes ' + $HeartbeatMinutes }
if ($HeartbeatThreshold -ne 5) { $extra += ' -HeartbeatThreshold ' + $HeartbeatThreshold }
$script:WatcherExtraArgs = $extra

# Prefer the real host executable from $PSHOME.  (Get-Process -Id $PID).Path
# is powershell_ise.exe when installed from the ISE, which would make the
# scheduled task open an ISE window instead of running hidden.
$psExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
    $psExe = Join-Path $PSHOME 'pwsh.exe'
}
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
    $psExe = (Get-Process -Id $PID).Path
}
if (-not $psExe -or -not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
    $psExe = Join-Path $PSHOME 'powershell.exe'
}

if ($Stop) {
    # Disable the auto-start mechanisms first, so a task restart or the next
    # logon cannot launch a new watcher between stopping and disabling.
    $task = Get-TaskInfo
    if ($task) {
        if ($task.State -ne 'Disabled') {
            if ($PSCmdlet.ShouldProcess($TaskName, '禁用计划任务')) {
                try {
                    Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
                    Write-Host "已禁用计划任务: $TaskName（不会再自动启动；用 -Uninstall 可彻底删除）"
                } catch {
                    Write-Host "禁用计划任务失败: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host '自动清理可能在下次登录时再次启动；可改用 -Uninstall 删除。' -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "计划任务已处于禁用状态: $TaskName"
        }
    }

    $entry = Get-StartupEntry
    if (Test-Path -LiteralPath $entry) {
        if ($PSCmdlet.ShouldProcess($entry, '删除登录启动监视器')) {
            try {
                Remove-Item -LiteralPath $entry -Force -ErrorAction Stop
                Write-Host "已删除登录启动监视器: $entry"
            } catch {
                Write-Host "删除登录启动监视器失败: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host '它可能在下次登录时再次启动监视器；可改用 -Uninstall 删除。' -ForegroundColor Yellow
            }
        }
    }

    Stop-WatcherProcesses
    exit 0
}

if ($Uninstall) {
    Stop-WatcherProcesses
    Remove-StartupWatcher
    $task = Get-TaskInfo
    $removedTask = $false
    if ($task) {
        if ($PSCmdlet.ShouldProcess($TaskName, '删除计划任务')) {
            try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
            try {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
                Write-Host "已删除计划任务: $TaskName"
                $removedTask = $true
            } catch {
                Write-Host "删除计划任务失败: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    if ($removedTask -or (-not $task -and -not $WhatIfPreference)) {
        Remove-ScheduledTaskLauncher
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $CleanupScript)) {
    throw "找不到 cleanup.ps1: $CleanupScript"
}

if ($Mode -eq 'Startup') {
    try {
        $ok = Install-StartupWatcher -PsExe $psExe -Script $CleanupScript
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
    if ($RunNow -and $ok) {
        try {
            Start-StartupWatcher
            Write-Host '已启动登录启动监视器。'
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
        }
    }
    exit 0
}

$taskStatus = 'Failed'
try {
    $taskStatus = Install-ScheduledTask -PsExe $psExe -Script $CleanupScript -TaskMode $Mode
} catch {
    Write-Host "计划任务安装失败: $($_.Exception.Message)" -ForegroundColor Yellow
    $taskStatus = 'Failed'
}

if ($taskStatus -eq 'Declined') {
    exit 0
}

if ($taskStatus -ne 'Installed') {
    if ($Mode -eq 'Watch') {
        Write-Host '改用登录启动监视器（不依赖 Task Scheduler）……' -ForegroundColor Yellow
        try {
            [void](Install-StartupWatcher -PsExe $psExe -Script $CleanupScript)
        } catch {
            Write-Host "无法安装登录启动监视器: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host 'Daily 模式需要 Task Scheduler。请改用 -Mode Watch 或 -Mode Startup。' -ForegroundColor Red
        exit 1
    }
}

if ($RunNow) {
    if ($script:InstalledKind -eq 'Task') {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "已启动任务: $TaskName"
    } elseif ($script:InstalledKind -eq 'Startup') {
        try {
            Start-StartupWatcher
            Write-Host '已启动登录启动监视器。'
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host ''
Write-Host '查看状态: .\install-task.ps1 -Status' -ForegroundColor Cyan
Write-Host '删除任务: .\install-task.ps1 -Uninstall' -ForegroundColor Cyan
