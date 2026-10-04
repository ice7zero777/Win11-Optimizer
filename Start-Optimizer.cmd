@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo.
echo   Win11-Optimizer - Windows 11 diagnostic scan ^& safe cleanup
echo   ==========================================================
echo   Default: scan only. Reports to the Reports folder.
echo   It never deletes your files and never changes system settings.
echo.
echo   Cleanup is opt-in. To clean caches, run this instead:
echo       powershell -ExecutionPolicy Bypass -File Win11Optimizer.ps1 -Clean
echo   To undo a cleanup, run:
echo       powershell -ExecutionPolicy Bypass -File Win11Optimizer.ps1 -Restore
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Win11Optimizer.ps1"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo   [ERROR] The scan did not finish normally ^(exit code %RC%^).
    echo   Please send the log files in the Reports\Logs folder when reporting this.
)

echo.
pause
endlocal
