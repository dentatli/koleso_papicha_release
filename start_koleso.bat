@echo off
title Papich Wheel - Local Server
chcp 65001 >nul
cd /d "%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0assets\local_server.ps1" -Root "%~dp0assets"

if errorlevel 1 (
    echo.
    echo Server stopped with an error.
    pause
)
