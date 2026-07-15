@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ai_tester_server.ps1"
if errorlevel 1 (
  echo.
  echo AI tester failed to start. See the message above.
  pause
)
endlocal
