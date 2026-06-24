@echo off
title Papich Wheel - Local Server
cd /d "%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0local_server.ps1"

if errorlevel 1 (
    echo.
    echo Server stopped with an error.
    pause
)
