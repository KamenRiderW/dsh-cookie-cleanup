@echo off
setlocal
cd /d "%~dp0"
chcp 65001 >nul
rem Resolve an absolute interpreter path.  Do not use "where pwsh.exe":
rem it searches the current directory first, so a planted pwsh.exe would run.
set "PS=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined ProgramW6432 set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PS%" set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo PowerShell 5.1 or 7 is required.
  exit /b 1
)
rem Extra arguments are forwarded as-is.  Quote arguments containing cmd
rem metacharacters (ampersand, pipe, angle brackets, caret).
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1" -IfRunning Skip -StartApp %*
set "CODE=%ERRORLEVEL%"
if "%CODE%"=="3" (
  echo.
  echo [Busy] Another cleanup or restore is already running.
  echo        This run did not complete its cleanup.
  echo        Check the output above before starting DeepSeek Harness.
  echo        If -ForceStart was used, the app may have been started anyway.
  ping -n 7 127.0.0.1 >nul 2>nul
  exit /b 3
)
if "%CODE%"=="2" (
  echo.
  echo [Skip] Cleanup did not run. DeepSeek Harness is probably still running
  echo        ^(or its cookie database is locked by a leftover process^).
  echo        Close it completely via the tray icon, then run this file again.
  echo        If it is stuck in a 431 crash loop, run this file with -KillApp.
  echo        Check the output above before starting DeepSeek Harness.
  echo        If -ForceStart was used, the app may have been started anyway.
  ping -n 7 127.0.0.1 >nul 2>nul
  exit /b 2
)
if not "%CODE%"=="0" (
  echo.
  echo Cleanup or app start failed with exit code %CODE%.
  echo Check the output above. If -ForceStart was used, the app may have
  echo been started anyway; otherwise it was not.
  ping -n 7 127.0.0.1 >nul 2>nul
)
exit /b %CODE%
