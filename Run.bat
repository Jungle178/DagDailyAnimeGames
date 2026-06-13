@echo off
setlocal
set "ROOT=%~dp0"
set "PYTHON=%ROOT%.venv\Scripts\python.exe"

if not exist "%PYTHON%" goto setup
"%PYTHON%" -c "from PIL import Image, ImageTk" >nul 2>nul
if errorlevel 1 goto setup
goto run

:setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Scripts\Setup-OkSharedVenv.ps1"
if errorlevel 1 (
    pause
    exit /b 1
)

:run
start "" powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Scripts\Start-LocalDailyGui.ps1" -NoElevate
exit /b 0
