@echo off
setlocal
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Scripts\Setup-OkSharedVenv.ps1" %*
exit /b %ERRORLEVEL%
