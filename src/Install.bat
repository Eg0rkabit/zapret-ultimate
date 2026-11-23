@echo off
chcp 65001 >nul
cd /d "%~dp0"

rem Repair UTF-8 BOM before PowerShell touches any .ps1 (ASCII-only helper).
if exist "%~dp0tools\fix-encoding.cmd" call "%~dp0tools\fix-encoding.cmd" >nul 2>&1

fltmc >nul 2>&1
if %errorlevel%==0 goto run
echo Requesting administrator rights...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1"
pause
