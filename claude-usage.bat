@echo off
setlocal
title Claude Code Usage Monitor
rem ---------------------------------------------------------------
rem  Claude Code usage monitor (live, in-place refresh)
rem  Usage:
rem    claude-usage.bat                refresh every 30s (or whatever config says)
rem    claude-usage.bat 5              override interval to 5s
rem    claude-usage.bat noconfig       launch with default settings, ignore config
rem    claude-usage.bat 5 noconfig     both
rem ---------------------------------------------------------------

rem Set a compact window before any output (cols x rows).
mode con: cols=36 lines=24 >nul 2>&1

echo  Claude Code Usage Monitor
echo  ----------------------------
echo  Starting up...

where ccusage >nul 2>&1
if errorlevel 1 (
    echo.
    echo [ERROR] ccusage not found on PATH.
    echo Install with:  npm i -g ccusage
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0claude-usage.ps1" (
    echo.
    echo [ERROR] claude-usage.ps1 not found next to this bat.
    echo Expected: %~dp0claude-usage.ps1
    echo.
    pause
    exit /b 1
)

set "INTERVAL="
set "NOCFG="

if /I "%~1"=="noconfig" (
    set "NOCFG=-NoConfig"
) else if not "%~1"=="" (
    set "INTERVAL=-Interval %~1"
)

if /I "%~2"=="noconfig" (
    set "NOCFG=-NoConfig"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-usage.ps1" %INTERVAL% %NOCFG%
set "PSEXIT=%ERRORLEVEL%"

echo.
echo ----------------------------------------------------------------
echo Monitor exited (PowerShell exit code: %PSEXIT%).
echo Press any key to close...
pause >nul
endlocal
