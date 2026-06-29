@echo off
chcp 65001 >nul
cd /d "%~dp0"

start "" powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0assets\local_server.ps1" -Root "%~dp0assets"
exit /b 0
