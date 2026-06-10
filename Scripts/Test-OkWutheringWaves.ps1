param(
    [string]$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path,
    [string]$GameExe = "",
    [int]$TaskIndex = 1,
    [switch]$RunTask,
    [switch]$Gui,
    [switch]$ValidateOnly,
    [switch]$NoElevate,
    [switch]$Wait,
    [int]$TimeoutSeconds = 900,
    [int]$GameWindowTimeoutSeconds = 600,
    [int]$GameStartupSeconds = 5,
    [string]$GameWindowClass = "UnrealWindow",
    [int]$MinGameWindowWidth = 800,
    [int]$MinGameWindowHeight = 450,
    [switch]$StrictGamePath,
    [switch]$AllowAnyGameWindowClass,
    [switch]$SkipStartGame,
    [switch]$SkipGameWindowWait,
    [switch]$KeepGameOpen,
    [switch]$SkipPipCheck
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-FullPath {
    param([string]$Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Require-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Require-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory not found: $Path"
    }
}

function Get-FirstProcessPathByName {
    param([string]$Name)

    $processInfo = Get-CimInstance Win32_Process -Filter "Name = '$Name'" -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) } |
        Sort-Object ProcessId |
        Select-Object -First 1

    if ($processInfo) {
        return $processInfo.ExecutablePath
    }

    return ""
}

function Get-CachedWutheringGamePath {
    param([string]$ProjectDir)

    $devicesConfig = Join-Path $ProjectDir "configs\devices.json"
    if (-not (Test-Path -LiteralPath $devicesConfig -PathType Leaf)) {
        return ""
    }

    try {
        $config = Get-Content -LiteralPath $devicesConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $path = [string]$config.pc_full_path
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }
    catch {
        Write-Warning "Failed to read cached Wuthering Waves path: $devicesConfig"
    }

    return ""
}

function Resolve-WutheringGamePath {
    param(
        [string]$ProjectDir,
        [string]$ConfiguredGameExe,
        [bool]$NeedPath
    )

    if ($ConfiguredGameExe) {
        return Resolve-FullPath $ConfiguredGameExe
    }

    if (-not $NeedPath) {
        return ""
    }

    $runningPath = Get-FirstProcessPathByName "Client-Win64-Shipping.exe"
    if ($runningPath) {
        Write-Host "Using running Wuthering Waves process path: $runningPath"
        return Resolve-FullPath $runningPath
    }

    $cachedPath = Get-CachedWutheringGamePath $ProjectDir
    if ($cachedPath) {
        Write-Host "Using cached Wuthering Waves process path: $cachedPath"
        return Resolve-FullPath $cachedPath
    }

    throw "Wuthering Waves game path is not known. Open the game once and click Confirm Game in the parent GUI, or pass -GameExe <path>."
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        Write-Host "> $FilePath $($Arguments -join ' ')"
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "$FilePath $($Arguments -join ' ') exited with code $exitCode"
        }
    }
    finally {
        Pop-Location
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ProcessAndMaybeWait {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [bool]$Elevate,
        [bool]$WaitForExit,
        [int]$Timeout
    )

    $startArgs = @{
        FilePath = $FilePath
        ArgumentList = $Arguments
        WorkingDirectory = $WorkingDirectory
        PassThru = $true
    }

    if ($Elevate) {
        $startArgs.Verb = "RunAs"
    }

    Write-Host "> Start-Process $FilePath $($Arguments -join ' ')"
    $process = Start-Process @startArgs

    if (-not $WaitForExit) {
        Write-Host "Started process id: $($process.Id)"
        return
    }

    Write-Host "Waiting up to $Timeout seconds for process id $($process.Id)..."
    $exited = $process.WaitForExit($Timeout * 1000)
    if (-not $exited) {
        throw "Process did not exit within $Timeout seconds: pid $($process.Id)"
    }

    if ($null -ne $process.ExitCode -and $process.ExitCode -ne 0) {
        throw "Process exited with code $($process.ExitCode): pid $($process.Id)"
    }

    Write-Host "Process exited successfully: pid $($process.Id)"
}

function Initialize-WindowApi {
    if ("OkSharedWin32.Native" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace OkSharedWin32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static class Native
    {
        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsWindowEnabled(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    }
}
"@
}

function Get-GameProcesses {
    param(
        [string]$GamePath,
        [bool]$AllowNameFallback = $true
    )

    $resolvedGamePath = Resolve-FullPath $GamePath
    $gameName = [System.IO.Path]::GetFileName($resolvedGamePath)
    $processInfos = Get-CimInstance Win32_Process -Filter "Name = '$gameName'" -ErrorAction SilentlyContinue

    $matchedIds = @()
    $fallbackIds = @()
    foreach ($processInfo in @($processInfos)) {
        if ($processInfo.ExecutablePath -and $processInfo.ExecutablePath.Equals($resolvedGamePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchedIds += [int]$processInfo.ProcessId
        }
        elseif ($AllowNameFallback) {
            $fallbackIds += [int]$processInfo.ProcessId
        }
    }

    $ids = @($matchedIds)
    if ($ids.Count -eq 0 -and $AllowNameFallback) {
        $ids = @($fallbackIds)
    }

    if ($ids.Count -eq 0) {
        return @()
    }

    return @(Get-Process -Id $ids -ErrorAction SilentlyContinue)
}

function Get-ProcessWindows {
    param(
        [int[]]$ProcessIds,
        [string]$WindowClass = "",
        [int]$MinWidth = 0,
        [int]$MinHeight = 0
    )

    Initialize-WindowApi

    $pidSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($processId in @($ProcessIds)) {
        [void]$pidSet.Add($processId)
    }

    $windows = [System.Collections.ArrayList]::new()
    $callback = [OkSharedWin32.EnumWindowsProc]{
        param([IntPtr]$hwnd, [IntPtr]$lparam)

        $windowPid = [uint32]0
        [void][OkSharedWin32.Native]::GetWindowThreadProcessId($hwnd, [ref]$windowPid)
        if (-not $pidSet.Contains([int]$windowPid)) {
            return $true
        }

        if (-not [OkSharedWin32.Native]::IsWindowVisible($hwnd)) {
            return $true
        }

        if (-not [OkSharedWin32.Native]::IsWindowEnabled($hwnd)) {
            return $true
        }

        $classBuilder = [System.Text.StringBuilder]::new(256)
        [void][OkSharedWin32.Native]::GetClassName($hwnd, $classBuilder, $classBuilder.Capacity)
        $className = $classBuilder.ToString()
        if ($WindowClass -and $className -ne $WindowClass) {
            return $true
        }

        $rect = [OkSharedWin32.RECT]::new()
        if (-not [OkSharedWin32.Native]::GetWindowRect($hwnd, [ref]$rect)) {
            return $true
        }

        $width = [Math]::Max(0, $rect.Right - $rect.Left)
        $height = [Math]::Max(0, $rect.Bottom - $rect.Top)
        if ($width -lt $MinWidth -or $height -lt $MinHeight) {
            return $true
        }

        $titleBuilder = [System.Text.StringBuilder]::new(512)
        [void][OkSharedWin32.Native]::GetWindowText($hwnd, $titleBuilder, $titleBuilder.Capacity)

        [void]$windows.Add([PSCustomObject]@{
            Hwnd = $hwnd
            ProcessId = [int]$windowPid
            ClassName = $className
            Title = $titleBuilder.ToString()
            Width = $width
            Height = $height
        })

        return $true
    }

    [void][OkSharedWin32.Native]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows)
}

function Start-GameIfNeeded {
    param(
        [string]$GamePath,
        [bool]$AllowNameFallback = $true
    )

    $running = @(Get-GameProcesses -GamePath $GamePath -AllowNameFallback $AllowNameFallback)
    if ($running.Count -gt 0) {
        Write-Host "Game is already running: $($running.Id -join ', ')"
        return $running
    }

    $resolvedGamePath = Resolve-FullPath $GamePath
    $gameWorkingDirectory = Split-Path -Parent $resolvedGamePath

    Write-Host "> Start-Process $resolvedGamePath"
    $process = Start-Process -FilePath $resolvedGamePath -WorkingDirectory $gameWorkingDirectory -PassThru
    Write-Host "Started game process id: $($process.Id)"

    return @(Get-GameProcesses -GamePath $GamePath -AllowNameFallback $AllowNameFallback)
}

function Wait-GameWindow {
    param(
        [string]$GamePath,
        [int]$Timeout,
        [string]$WindowClass,
        [int]$MinWidth,
        [int]$MinHeight,
        [bool]$AllowNameFallback = $true,
        [bool]$AllowAnyWindowClass = $false
    )

    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastLogTime = [datetime]::MinValue

    Write-Host "Waiting up to $Timeout seconds for game window class '$WindowClass'..."
    while ((Get-Date) -lt $deadline) {
        $processes = @(Get-GameProcesses -GamePath $GamePath -AllowNameFallback $AllowNameFallback)
        if ($processes.Count -gt 0) {
            $windows = @(Get-ProcessWindows `
                    -ProcessIds @($processes.Id) `
                    -WindowClass $WindowClass `
                    -MinWidth $MinWidth `
                    -MinHeight $MinHeight)

            if ($windows.Count -gt 0) {
                $window = $windows | Sort-Object -Property Width, Height -Descending | Select-Object -First 1
                Write-Host "Game window is ready: pid=$($window.ProcessId), hwnd=$($window.Hwnd), class=$($window.ClassName), size=$($window.Width)x$($window.Height), title=$($window.Title)"
                return $window
            }

            $candidateWindows = @(Get-ProcessWindows `
                    -ProcessIds @($processes.Id) `
                    -WindowClass "" `
                    -MinWidth $MinWidth `
                    -MinHeight $MinHeight)
            if ($candidateWindows.Count -gt 0) {
                $candidate = $candidateWindows | Sort-Object -Property Width, Height -Descending | Select-Object -First 1
                if ($AllowAnyWindowClass) {
                    Write-Host "Game window is ready with non-default class: pid=$($candidate.ProcessId), hwnd=$($candidate.Hwnd), class=$($candidate.ClassName), size=$($candidate.Width)x$($candidate.Height), title=$($candidate.Title)"
                    return $candidate
                }

                Write-Host "Found game window candidate but class did not match '$WindowClass': pid=$($candidate.ProcessId), hwnd=$($candidate.Hwnd), class=$($candidate.ClassName), size=$($candidate.Width)x$($candidate.Height), title=$($candidate.Title)"
            }
        }

        if (((Get-Date) - $lastLogTime).TotalSeconds -ge 5) {
            if ($processes.Count -gt 0) {
                Write-Host "Game process exists, waiting for usable window. pid=$($processes.Id -join ', ')"
            }
            else {
                Write-Host "Waiting for game process..."
            }
            $lastLogTime = Get-Date
        }

        Start-Sleep -Seconds 1
    }

    throw "Game window was not ready within $Timeout seconds."
}

function Stop-Game {
    param(
        [string]$GamePath,
        [int]$GraceSeconds = 10,
        [bool]$AllowNameFallback = $true
    )

    $processes = @(Get-GameProcesses -GamePath $GamePath -AllowNameFallback $AllowNameFallback)
    if ($processes.Count -eq 0) {
        Write-Host "Game process is not running."
        return
    }

    Write-Host "Closing game process(es): $($processes.Id -join ', ')"
    foreach ($process in $processes) {
        try {
            if ($process.MainWindowHandle -ne 0) {
                [void]$process.CloseMainWindow()
            }
        }
        catch {
            Write-Warning "Failed to request graceful close for pid $($process.Id): $_"
        }
    }

    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while ((Get-Date) -lt $deadline) {
        $remaining = @(Get-GameProcesses -GamePath $GamePath -AllowNameFallback $AllowNameFallback)
        if ($remaining.Count -eq 0) {
            Write-Host "Game closed."
            return
        }
        Start-Sleep -Seconds 1
    }

    $remaining = @(Get-GameProcesses -GamePath $GamePath -AllowNameFallback $AllowNameFallback)
    foreach ($process in $remaining) {
        Write-Host "Force stopping game process id: $($process.Id)"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

$Root = Resolve-FullPath $Root
$ProjectDir = Join-Path $Root "src\ok-wuthering-waves"
$VenvPython = Join-Path $Root ".venv\Scripts\python.exe"
$SetupScript = Join-Path $Root "Scripts\Setup-OkSharedVenv.ps1"
$needGamePath = -not $ValidateOnly -and -not $SkipStartGame
$GameExe = Resolve-WutheringGamePath -ProjectDir $ProjectDir -ConfiguredGameExe $GameExe -NeedPath $needGamePath

Require-Directory $Root
Require-Directory $ProjectDir
Require-File (Join-Path $ProjectDir "main.py")
if ($GameExe -and -not $ValidateOnly -and -not $SkipStartGame) {
    Require-File $GameExe
}

if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    Require-File $SetupScript
    Write-Host "Shared venv was not found. Creating it first..."
    Invoke-Checked -FilePath "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SetupScript) -WorkingDirectory $Root
}

Require-File $VenvPython

Write-Host "Validating ok-wuthering-waves with shared venv..."
Invoke-Checked -FilePath $VenvPython -Arguments @("-c", "import ok, main; print('ok-wuthering-waves import ok/main OK', ok.__file__)") -WorkingDirectory $ProjectDir

if (-not $SkipPipCheck) {
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "check") -WorkingDirectory $Root
}

Write-Host "Task index 1 is DailyTask for ok-wuthering-waves."

if ($ValidateOnly) {
    Write-Host "Validation complete. Remove -ValidateOnly to run main.py -t $TaskIndex -e."
    exit 0
}

if ($RunTask) {
    Write-Host "-RunTask is now the default for this script."
}

if ($Gui) {
    Write-Host "-Gui is now the default for ok-wuthering-waves; starting without the headless flag."
}

$mainArgs = @("main.py", "-t", "$TaskIndex", "-e")

$isAdmin = Test-IsAdmin
if ($NoElevate -and -not $isAdmin) {
    throw "Current PowerShell is not running as Administrator. Remove -NoElevate or start PowerShell as Administrator."
}

$elevate = (-not $NoElevate) -and (-not $isAdmin)
if ($elevate) {
    Write-Host "Starting with UAC elevation because current PowerShell is not Administrator."
}

$shouldCloseGame = (-not $KeepGameOpen) -and -not [string]::IsNullOrWhiteSpace($GameExe)
$shouldWaitForTask = $Wait -or $shouldCloseGame
$allowNameFallback = -not $StrictGamePath

try {
    if (-not $SkipStartGame) {
        Start-GameIfNeeded -GamePath $GameExe -AllowNameFallback $allowNameFallback | Out-Null
    }
    else {
        Write-Host "Skipping game startup."
    }

    if (-not $SkipGameWindowWait) {
        Wait-GameWindow `
            -GamePath $GameExe `
            -Timeout $GameWindowTimeoutSeconds `
            -WindowClass $GameWindowClass `
            -MinWidth $MinGameWindowWidth `
            -MinHeight $MinGameWindowHeight `
            -AllowNameFallback $allowNameFallback `
            -AllowAnyWindowClass $AllowAnyGameWindowClass.IsPresent | Out-Null

        if ($GameStartupSeconds -gt 0) {
            Write-Host "Waiting $GameStartupSeconds seconds after game window became ready..."
            Start-Sleep -Seconds $GameStartupSeconds
        }
    }
    else {
        Write-Host "Skipping game window wait."
    }

    Start-ProcessAndMaybeWait `
        -FilePath $VenvPython `
        -Arguments $mainArgs `
        -WorkingDirectory $ProjectDir `
        -Elevate $elevate `
        -WaitForExit $shouldWaitForTask `
        -Timeout $TimeoutSeconds
}
finally {
    if ($shouldCloseGame) {
        Stop-Game -GamePath $GameExe -AllowNameFallback $allowNameFallback
    }
    else {
        Write-Host "Keeping game open."
    }
}
