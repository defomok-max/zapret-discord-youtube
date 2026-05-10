@echo off
:: codeDPI - minimal one-screen launcher.
:: Bat is intentionally MINIMAL: any failure is captured by the PS chooser
:: itself. Admin detection / UAC self-elevation now lives inside chooser.ps1.
::
:: Pass-through (rare):
::   start.bat        -> chooser (default)
::   start.bat gui    -> full WPF launcher (utils\launcher.gui.ps1)
::   start.bat cli    -> console TUI (utils\launcher.ps1)

setlocal EnableExtensions
chcp 65001 > nul
cd /d "%~dp0"
title codeDPI launcher

set "PS_FILE=%~dp0utils\launcher.chooser.ps1"
if /I "%~1"=="gui" set "PS_FILE=%~dp0utils\launcher.gui.ps1"
if /I "%~1"=="cli" set "PS_FILE=%~dp0utils\launcher.ps1"

set "LAUNCHER_LOG=%~dp0launcher.log"
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] start.bat: launching "%PS_FILE%"

if not exist "%PS_FILE%" (
    echo.
    echo codeDPI: launcher script not found:
    echo   "%PS_FILE%"
    echo.
    echo Distribute the FULL repo (the utils\ folder must sit next to start.bat).
    >>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] MISSING %PS_FILE%
    echo.
    pause
    exit /b 2
)

echo codeDPI launcher: starting %PS_FILE%
echo (this cmd window stays open; close it after the GUI window exits)
echo.

:: -STA is REQUIRED for WPF. Self-elevation (UAC prompt) is handled INSIDE
:: chooser.ps1 so any error is visible right here in this cmd window.
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%PS_FILE%"
set "PS_ERR=%ERRORLEVEL%"
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] exit code %PS_ERR%

echo.
if not "%PS_ERR%"=="0" (
    echo =====================================================================
    echo  codeDPI: PowerShell exited with code %PS_ERR%.
    echo  Script:  %PS_FILE%
    echo  Log:     %LAUNCHER_LOG%
    echo =====================================================================
) else (
    echo codeDPI: PowerShell exited cleanly. Log: %LAUNCHER_LOG%
)
echo.
echo Press any key to close this window...
pause >nul
exit /b %PS_ERR%
