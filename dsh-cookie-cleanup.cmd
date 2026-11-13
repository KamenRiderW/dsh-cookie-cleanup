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
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1" %*
set "CODE=%ERRORLEVEL%"
echo.
if "%CODE%"=="0" (
  echo Cleanup finished.
) else if "%CODE%"=="2" (
  echo Nothing was changed. See the message above.
) else (
  echo Cleanup failed with exit code %CODE%.
)
pause
exit /b %CODE%
