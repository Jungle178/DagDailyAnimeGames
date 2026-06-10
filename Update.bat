@echo off
setlocal
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Scripts\Update-InstalledSubmodules.ps1" %*
exit /b %ERRORLEVEL%
