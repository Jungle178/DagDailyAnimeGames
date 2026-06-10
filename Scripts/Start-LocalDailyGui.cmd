@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
start "" powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Start-LocalDailyGui.ps1"
endlocal
