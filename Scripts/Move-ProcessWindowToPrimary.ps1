param(
    [Parameter(Mandatory = $true)]
    [string]$ProcessName,
    [string]$WindowClass = "",
    [int]$TimeoutSeconds = 180,
    [int]$IntervalMilliseconds = 2000,
    [switch]$KeepTrying
)

$ErrorActionPreference = "Stop"

function Initialize-WindowApi {
    if ("DagDailyWindowMover.Native" -as [type]) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace DagDailyWindowMover
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
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll")]
        public static extern bool BringWindowToTop(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
"@
}

function Get-ProcessWindows {
    param(
        [int[]]$ProcessIds,
        [string]$RequiredWindowClass
    )

    $pidSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($processId in @($ProcessIds)) {
        [void]$pidSet.Add($processId)
    }

    $windows = [System.Collections.ArrayList]::new()
    $callback = [DagDailyWindowMover.EnumWindowsProc]{
        param([IntPtr]$hwnd, [IntPtr]$lparam)

        $windowPid = [uint32]0
        [void][DagDailyWindowMover.Native]::GetWindowThreadProcessId($hwnd, [ref]$windowPid)
        if (-not $pidSet.Contains([int]$windowPid)) {
            return $true
        }

        $classBuilder = [System.Text.StringBuilder]::new(256)
        [void][DagDailyWindowMover.Native]::GetClassName($hwnd, $classBuilder, $classBuilder.Capacity)
        $className = $classBuilder.ToString()
        if ($RequiredWindowClass -and $className -ne $RequiredWindowClass) {
            return $true
        }

        $rect = [DagDailyWindowMover.RECT]::new()
        [void][DagDailyWindowMover.Native]::GetWindowRect($hwnd, [ref]$rect)
        $width = [Math]::Max(0, $rect.Right - $rect.Left)
        $height = [Math]::Max(0, $rect.Bottom - $rect.Top)

        $titleBuilder = [System.Text.StringBuilder]::new(512)
        [void][DagDailyWindowMover.Native]::GetWindowText($hwnd, $titleBuilder, $titleBuilder.Capacity)

        [void]$windows.Add([PSCustomObject]@{
            Hwnd = $hwnd
            ProcessId = [int]$windowPid
            ClassName = $className
            Title = $titleBuilder.ToString()
            Visible = [DagDailyWindowMover.Native]::IsWindowVisible($hwnd)
            X = $rect.Left
            Y = $rect.Top
            Width = $width
            Height = $height
        })

        return $true
    }

    [void][DagDailyWindowMover.Native]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows)
}

function Move-WindowToPrimary {
    param([object]$Window)

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $hwnd = [IntPtr]$Window.Hwnd

    [void][DagDailyWindowMover.Native]::ShowWindow($hwnd, 9)
    Start-Sleep -Milliseconds 150
    [void][DagDailyWindowMover.Native]::SetWindowPos(
        $hwnd,
        [IntPtr]::Zero,
        $bounds.X,
        $bounds.Y,
        $bounds.Width,
        $bounds.Height,
        0x0040
    )
    [void][DagDailyWindowMover.Native]::BringWindowToTop($hwnd)
    [void][DagDailyWindowMover.Native]::SetForegroundWindow($hwnd)

    return $bounds
}

Initialize-WindowApi

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$movedWindows = @{}
$lastLogTime = [datetime]::MinValue
$processQueryName = [System.IO.Path]::GetFileNameWithoutExtension($ProcessName)

Write-Host "Monitoring $processQueryName windows for up to $TimeoutSeconds seconds."
while ((Get-Date) -lt $deadline) {
    $processes = @(Get-Process -Name $processQueryName -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) {
        $windows = @(Get-ProcessWindows -ProcessIds @($processes.Id) -RequiredWindowClass $WindowClass)
        if ($windows.Count -gt 0) {
            $window = $windows |
                Sort-Object -Property @{ Expression = { $_.Width * $_.Height }; Descending = $true } |
                Select-Object -First 1

            $bounds = Move-WindowToPrimary -Window $window
            $key = "$($window.Hwnd)"
            if (-not $movedWindows.ContainsKey($key)) {
                $movedWindows[$key] = $true
                Write-Host "Moved window hwnd=$($window.Hwnd) pid=$($window.ProcessId) class=$($window.ClassName) visible=$($window.Visible) from=$($window.X),$($window.Y),$($window.Width)x$($window.Height) to=$($bounds.X),$($bounds.Y),$($bounds.Width)x$($bounds.Height)"
            }

            if (-not $KeepTrying) {
                exit 0
            }
        }
    }

    if (((Get-Date) - $lastLogTime).TotalSeconds -ge 10) {
        if ($processes.Count -gt 0) {
            Write-Host "Waiting for top-level window. pid=$($processes.Id -join ', ')"
        }
        else {
            Write-Host "Waiting for process $processQueryName."
        }
        $lastLogTime = Get-Date
    }

    Start-Sleep -Milliseconds $IntervalMilliseconds
}

if ($movedWindows.Count -eq 0) {
    Write-Host "No matching window was moved for process $processQueryName."
}
