@echo off
REM codeDPI - bulletproof launcher entry point.
REM
REM Strategy: ONE console window, always under bat control.
REM   - If not elevated: relaunch this bat elevated via PowerShell Start-Process.
REM     The unelevated instance exits immediately; only the elevated instance
REM     owns a visible console.
REM   - If elevated: run chooser.ps1. On any exit (clean or crash) the bat
REM     prints a status line and ALWAYS pauses so the user sees what happened.
REM
REM Pass-through:
REM   start.bat        -> chooser (default)
REM   start.bat gui    -> full WPF launcher (utils\launcher.gui.ps1)
REM   start.bat cli    -> console TUI (utils\launcher.ps1)
REM
REM IMPORTANT: Use REM (not ::) inside parenthesized IF blocks. CMD interprets
REM :: as a broken label reference inside (...) which produces the bogus
REM "The system cannot find the drive specified" error at runtime.

setlocal EnableExtensions
chcp 65001 > nul
cd /d "%~dp0"
if errorlevel 1 (
    echo ERROR: cannot cd into script folder: "%~dp0"
    echo Press any key to close...
    pause >nul
    exit /b 10
)
title codeDPI launcher

set "LAUNCHER_LOG=%~dp0launcher.log"
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] start.bat: invoked (arg1=%1)

REM ============================================================
REM Admin check via `net session` (needs admin on all modern Windows).
REM ============================================================
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 goto :NOT_ADMIN
goto :IS_ADMIN

:NOT_ADMIN
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] not admin -- relaunching elevated
echo codeDPI: requesting administrator rights via UAC...
echo.
REM Only pass -ArgumentList when we have an actual arg. Start-Process
REM rejects an empty string with ParameterArgumentValidationError.
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
)
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ====================================================================
    echo  UAC elevation failed or was cancelled.
    echo  codeDPI needs admin rights to load WinDivert and control winws.exe
    echo ====================================================================
    echo.
    echo Press any key to close...
    pause >nul
    exit /b 3
)
REM The elevated instance is running in a separate window; quit this one.
exit /b 0

:IS_ADMIN
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] elevated, cwd=%CD%

set "PS_FILE=%~dp0utils\launcher.chooser.ps1"
if /I "%~1"=="gui" set "PS_FILE=%~dp0utils\launcher.gui.ps1"
if /I "%~1"=="cli" set "PS_FILE=%~dp0utils\launcher.ps1"

>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] launching "%PS_FILE%"

if not exist "%PS_FILE%" (
    echo.
    echo ====================================================================
    echo  codeDPI: launcher script not found:
    echo    "%PS_FILE%"
    echo.
    echo  Distribute the FULL repo - utils\ must sit next to start.bat.
    echo ====================================================================
    >>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] MISSING %PS_FILE%
    echo.
    echo Press any key to close...
    pause >nul
    exit /b 2
)

echo.
echo  codeDPI launcher
echo  -----------------------------------------------
echo    script: %PS_FILE%
echo    log:    %LAUNCHER_LOG%
echo  -----------------------------------------------
echo.
echo  Starting GUI... this window stays open.
echo  Close the WPF window; then this console will pause.
echo.

REM -STA is REQUIRED for WPF.
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%PS_FILE%"
set "PS_ERR=%ERRORLEVEL%"
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] exit code %PS_ERR%

echo.
if not "%PS_ERR%"=="0" (
    echo ====================================================================
    echo  codeDPI: PowerShell exited with code %PS_ERR%.
    echo  Script:  %PS_FILE%
    echo  Log:     %LAUNCHER_LOG%
    echo.
    echo  Common causes:
    echo    - WPF loading error (corrupted .NET install)
    echo    - config file syntax error in launcher.conf
    echo    - another launcher instance is already running
    echo  Check launcher.log for a full stack trace.
    echo ====================================================================
) else (
    echo  codeDPI: PowerShell exited cleanly. Log: %LAUNCHER_LOG%
)
echo.
echo  Press any key to close this window...
pause >nul
exit /b %PS_ERR%
