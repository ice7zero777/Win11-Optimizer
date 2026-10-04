@echo off
rem Win11-Optimizer 图形界面启动器（纯 ASCII 文件名，见铁律 L5）
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

rem -WindowStyle Hidden：只显示 WPF 窗口，不弹出黑色控制台窗口
"%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Win11Optimizer.Gui.ps1"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo   [ERROR] 图形界面启动失败 ^(exit code %RC%^)。
    echo   请把下面这个目录里的日志附在 Issue 里：%~dp0Reports\Logs
    echo.
    pause
)

endlocal
