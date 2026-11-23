@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem Repair UTF-8 BOM before PowerShell touches any .ps1 (ASCII-only helper).
if exist "%~dp0tools\fix-encoding.cmd" call "%~dp0tools\fix-encoding.cmd" >nul 2>&1

rem --- elevate, preserving command line arguments -------------------------
rem fltmc only needs admin rights (unlike "net session", which needs the Server service).
fltmc >nul 2>&1
if %errorlevel%==0 goto run

echo Requesting administrator rights...
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -WorkingDirectory '%~dp0' -Verb RunAs"
)
exit /b

:run
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Zapret.ps1" menu
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Zapret.ps1" %*
)

if /i "%ZAPRET_NOPAUSE%"=="1" exit /b
echo.
pause
