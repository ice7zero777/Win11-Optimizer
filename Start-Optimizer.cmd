@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo.
echo   Win11-Optimizer - Windows 11 read-only diagnostic scan
echo   =====================================================
echo   This version only scans and reports.
echo   It does NOT delete files or change system settings.
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Win11Optimizer.ps1"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo   [ERROR] The scan did not finish normally ^(exit code %RC%^).
    echo   Please send the log files in the Logs folder when reporting this.
)

echo.
pause
endlocal
