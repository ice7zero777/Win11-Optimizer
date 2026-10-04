@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

rem 支持 /gui 直接进图形界面，跳过菜单（方便固定快捷方式，也便于自动化验证）
if /i "%~1"=="/gui" goto gui
if /i "%~1"=="-gui" goto gui
if /i "%~1"=="gui" goto gui

:menu
cls
echo.
echo   ============================================================
echo     Win11-Optimizer  -  Windows 11 诊断与安全清理
echo   ============================================================
echo.
echo     这个工具不会删除你的文件。
echo     清理 = 把缓存文件移动到隔离区，随时可以一键还原。
echo.
echo     [1] 图形界面      推荐，点按钮操作，不用看命令行
echo     [2] 只读诊断      命令行版，只扫描出报告，不动任何东西
echo     [3] 清理缓存      命令行版，先勾选再确认，才动文件
echo     [4] 一键还原      把隔离区里的文件放回原位
echo     [0] 退出
echo.
set "CHOICE="
set /p "CHOICE=   请输入数字后回车："

if "%CHOICE%"=="1" goto gui
if "%CHOICE%"=="2" goto scanonly
if "%CHOICE%"=="3" goto clean
if "%CHOICE%"=="4" goto restore
if "%CHOICE%"=="0" goto end
echo.
echo   输入无效，请重新选择。
timeout /t 2 >nul
goto menu

:gui
"%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Win11Optimizer.Gui.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo   [ERROR] 图形界面启动失败 ^(exit code %RC%^)。
    echo   请把日志附在 Issue 里：%~dp0Reports\Logs
    pause
)
goto end

:scanonly
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Win11Optimizer.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo   [ERROR] 扫描没有正常结束 ^(exit code %RC%^)。
    echo   请把日志附在 Issue 里：%~dp0Reports\Logs
)
echo.
pause
goto menu

:clean
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Win11Optimizer.ps1" -Clean
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo   [ERROR] 清理没有正常结束 ^(exit code %RC%^)。
    echo   请把日志附在 Issue 里：%~dp0Reports\Logs
)
echo.
pause
goto menu

:restore
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Win11Optimizer.ps1" -Restore
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo   [ERROR] 还原没有正常结束 ^(exit code %RC%^)。
    echo   请把日志附在 Issue 里：%~dp0Reports\Logs
)
echo.
pause
goto menu

:end
endlocal