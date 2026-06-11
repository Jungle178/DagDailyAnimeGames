param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("wuthering", "endfield", "nte")]
    [string]$AppId,
    [string]$Root = "",
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class LocalDailyWindowApi
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder title, int maxCount);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@

$script:SW_RESTORE = 9

function Resolve-FullPath {
    param([string]$Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-JsonObject {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [PSCustomObject]@{}
    }

    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [PSCustomObject]@{}
        }
        return $text | ConvertFrom-Json
    }
    catch {
        Write-Warning "Ignoring invalid json file: $Path"
        return [PSCustomObject]@{}
    }
}

function Set-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Save-JsonObject {
    param(
        [string]$Path,
        [object]$Object
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-OrCreateJsonObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if (-not ($Object.PSObject.Properties.Name -contains $Name) -or $null -eq $Object.$Name) {
        Set-JsonProperty $Object $Name ([PSCustomObject]@{})
    }

    $Object.$Name
}

function Get-RunningProcessInfo {
    param(
        [string]$Name,
        [int]$Timeout
    )

    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $Timeout))
    while ($true) {
        $items = @(
            Get-CimInstance Win32_Process -Filter "Name = '$Name'" -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) } |
                Sort-Object ProcessId
        )

        if ($items.Count -gt 0) {
            return $items[0]
        }

        if ($Timeout -le 0 -or (Get-Date) -ge $deadline) {
            return $null
        }

        Start-Sleep -Seconds 1
    }
}

function Get-WindowClassName {
    param([IntPtr]$Hwnd)

    $builder = [System.Text.StringBuilder]::new(256)
    [void][LocalDailyWindowApi]::GetClassName($Hwnd, $builder, $builder.Capacity)
    $builder.ToString()
}

function Get-WindowTitle {
    param([IntPtr]$Hwnd)

    $builder = [System.Text.StringBuilder]::new(512)
    [void][LocalDailyWindowApi]::GetWindowText($Hwnd, $builder, $builder.Capacity)
    $builder.ToString()
}

function Get-WindowSize {
    param([IntPtr]$Hwnd)

    $rect = [LocalDailyWindowApi+RECT]::new()
    if (-not [LocalDailyWindowApi]::GetWindowRect($Hwnd, [ref]$rect)) {
        return [PSCustomObject]@{ Width = 0; Height = 0 }
    }

    [PSCustomObject]@{
        Width = [Math]::Max(0, $rect.Right - $rect.Left)
        Height = [Math]::Max(0, $rect.Bottom - $rect.Top)
    }
}

function Find-WindowForProcess {
    param(
        [int]$ProcessId,
        [string]$HwndClass = ""
    )

    $matches = [System.Collections.Generic.List[object]]::new()
    $callback = [LocalDailyWindowApi+EnumWindowsProc]{
        param([IntPtr]$hwnd, [IntPtr]$lparam)

        if (-not [LocalDailyWindowApi]::IsWindow($hwnd) -or -not [LocalDailyWindowApi]::IsWindowEnabled($hwnd)) {
            return $true
        }

        $windowProcessId = [uint32]0
        [void][LocalDailyWindowApi]::GetWindowThreadProcessId($hwnd, [ref]$windowProcessId)
        if ([int]$windowProcessId -ne $ProcessId) {
            return $true
        }

        $className = Get-WindowClassName $hwnd
        if ($HwndClass -and $className -ne $HwndClass) {
            return $true
        }

        $size = Get-WindowSize $hwnd
        [void]$matches.Add([PSCustomObject]@{
            Hwnd = $hwnd
            HwndValue = $hwnd.ToInt64()
            ClassName = $className
            Title = Get-WindowTitle $hwnd
            Width = $size.Width
            Height = $size.Height
            Visible = [LocalDailyWindowApi]::IsWindowVisible($hwnd)
            Minimized = [LocalDailyWindowApi]::IsIconic($hwnd)
        })
        return $true
    }

    [void][LocalDailyWindowApi]::EnumWindows($callback, [IntPtr]::Zero)
    if ($matches.Count -eq 0) {
        return $null
    }

    $usable = @($matches | Where-Object { $_.Width -gt 200 -and $_.Height -gt 200 })
    $visible = @($usable | Where-Object { $_.Visible })
    if ($visible.Count -gt 0) {
        return $visible[0]
    }
    if ($usable.Count -gt 0) {
        return $usable[0]
    }
    return $matches[0]
}

function Get-RunningProcessWindowInfo {
    param(
        [string]$Name,
        [int]$Timeout,
        [string]$HwndClass = ""
    )

    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $Timeout))
    $lastLogSecond = -1
    $start = Get-Date
    while ($true) {
        $items = @(
            Get-CimInstance Win32_Process -Filter "Name = '$Name'" -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) } |
                Sort-Object ProcessId
        )

        foreach ($item in $items) {
            $window = Find-WindowForProcess -ProcessId ([int]$item.ProcessId) -HwndClass $HwndClass
            if ($window) {
                if ($window.Minimized) {
                    [void][LocalDailyWindowApi]::ShowWindow($window.Hwnd, $script:SW_RESTORE)
                }
                return [PSCustomObject]@{
                    Process = $item
                    Window = $window
                }
            }
        }

        if ($Timeout -le 0 -or (Get-Date) -ge $deadline) {
            return $null
        }

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($elapsed -gt 0 -and $elapsed % 10 -eq 0 -and $elapsed -ne $lastLogSecond) {
            if ($items.Count -gt 0) {
                Write-Host "Process $Name exists, waiting for usable window; elapsed=${elapsed}s"
            }
            else {
                Write-Host "Still waiting for $Name; elapsed=${elapsed}s"
            }
            $lastLogSecond = $elapsed
        }

        Start-Sleep -Seconds 1
    }
}

function Update-DevicesConfig {
    param(
        [string]$ProjectPath,
        [string]$ProcessName,
        [string]$ProcessPath,
        [object]$WindowInfo
    )

    $configPath = Join-Path $ProjectPath "configs\devices.json"
    $config = Read-JsonObject $configPath
    Set-JsonProperty $config "preferred" "pc"
    Set-JsonProperty $config "pc_full_path" $ProcessPath
    Set-JsonProperty $config "capture" "windows"
    Set-JsonProperty $config "selected_exe" $ProcessName
    Set-JsonProperty $config "selected_hwnd" $WindowInfo.HwndValue
    if (-not ($config.PSObject.Properties.Name -contains "interaction")) {
        Set-JsonProperty $config "interaction" ""
    }
    Save-JsonObject $configPath $config
    Write-Host "Updated devices config: $configPath"
}

function Update-RootSettings {
    param(
        [string]$RootPath,
        [string]$AppId,
        [string]$ProcessPath,
        [object]$WindowInfo
    )

    $settingsPath = Join-Path $RootPath "Setting.json"
    $settings = Read-JsonObject $settingsPath
    Set-JsonProperty $settings "settings_version" 6

    $apps = Get-OrCreateJsonObjectProperty -Object $settings -Name "apps"
    if (-not ($apps.PSObject.Properties.Name -contains $AppId) -or $null -eq $apps.$AppId) {
        Set-JsonProperty $apps $AppId ([PSCustomObject]@{})
    }

    $appSettings = $apps.$AppId
    Set-JsonProperty $appSettings "game_path" $ProcessPath
    Set-JsonProperty $appSettings "game_dir" (Split-Path -Parent $ProcessPath)
    Set-JsonProperty $appSettings "game_hwnd" $WindowInfo.HwndValue
    Set-JsonProperty $appSettings "game_hwnd_class" $WindowInfo.ClassName
    Set-JsonProperty $appSettings "game_verified" $true
    Set-JsonProperty $appSettings "game_verified_at" (Get-Date).ToString("s")
    if (-not ($appSettings.PSObject.Properties.Name -contains "enabled")) {
        Set-JsonProperty $appSettings "enabled" $false
    }
    if (-not ($appSettings.PSObject.Properties.Name -contains "times")) {
        Set-JsonProperty $appSettings "times" @()
    }

    if (-not ($settings.PSObject.Properties.Name -contains "last_runs")) {
        Set-JsonProperty $settings "last_runs" ([PSCustomObject]@{})
    }
    if (-not ($settings.PSObject.Properties.Name -contains "log_archives")) {
        Set-JsonProperty $settings "log_archives" ([PSCustomObject]@{})
    }

    Save-JsonObject $settingsPath $settings
    Write-Host "Updated root settings: $settingsPath"
}

function Get-NteLauncherPath {
    param([string]$GamePath)

    $launcherProc = Get-RunningProcessInfo -Name "NTEGame.exe" -Timeout 0
    if ($launcherProc) {
        return $launcherProc.ExecutablePath
    }

    $fullPath = [System.IO.Path]::GetFullPath($GamePath)
    $marker = "\Client\"
    $index = $fullPath.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
    if ($index -lt 0) {
        return ""
    }

    $installRoot = $fullPath.Substring(0, $index)
    $candidate = Join-Path $installRoot "NTELauncher\NTEGame.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    return ""
}

function Update-NteLauncherConfig {
    param(
        [string]$ProjectPath,
        [string]$GamePath
    )

    $launcherPath = Get-NteLauncherPath $GamePath
    if (-not $launcherPath) {
        Write-Warning "NTE launcher path was not derived; LauncherTask can still try registry lookup."
        return
    }

    $configPath = Join-Path $ProjectPath "configs\LauncherTask.json"
    $config = Read-JsonObject $configPath
    Set-JsonProperty $config "Launcher Path" $launcherPath
    Save-JsonObject $configPath $config
    Write-Host "Updated NTE launcher config: $launcherPath"
}

if (-not $Root) {
    $Root = Join-Path $PSScriptRoot ".."
}
$Root = Resolve-FullPath $Root

$apps = @{
    wuthering = @{
        Path = "src\ok-wuthering-waves"
        ProcessName = "Client-Win64-Shipping.exe"
        HwndClass = "UnrealWindow"
        DisplayName = "ok-wuthering-waves"
    }
    endfield = @{
        Path = "src\ok-end-field"
        ProcessName = "Endfield.exe"
        HwndClass = ""
        DisplayName = "ok-end-field"
    }
    nte = @{
        Path = "src\ok-nte"
        ProcessName = "HTGame.exe"
        HwndClass = "UnrealWindow"
        DisplayName = "ok-nte"
    }
}

$app = $apps[$AppId]
$projectPath = Join-Path $Root $app.Path
if (-not (Test-Path -LiteralPath (Join-Path $projectPath "main.py") -PathType Leaf)) {
    throw "Project is not installed: $projectPath"
}

$processName = $app.ProcessName
$hwndClass = $app.HwndClass
$classText = if ($hwndClass) { " with window class $hwndClass" } else { "" }
Write-Host "Looking for $($app.DisplayName) game process and usable window: $processName$classText"
$processWindowInfo = Get-RunningProcessWindowInfo -Name $processName -Timeout $TimeoutSeconds -HwndClass $hwndClass
if (-not $processWindowInfo) {
    Write-Host "Game process/window was not found. Open the game, wait for its window, then try verification again."
    exit 2
}

$processInfo = $processWindowInfo.Process
$windowInfo = $processWindowInfo.Window
$processPath = $processInfo.ExecutablePath
if (-not (Test-Path -LiteralPath $processPath -PathType Leaf)) {
    throw "Detected process path does not exist: $processPath"
}

Write-Host "Found game process: pid=$($processInfo.ProcessId), path=$processPath"
Write-Host "Found game window: hwnd=$($windowInfo.HwndValue), class=$($windowInfo.ClassName), size=$($windowInfo.Width)x$($windowInfo.Height), visible=$($windowInfo.Visible)"
Update-DevicesConfig -ProjectPath $projectPath -ProcessName $processName -ProcessPath $processPath -WindowInfo $windowInfo
Update-RootSettings -RootPath $Root -AppId $AppId -ProcessPath $processPath -WindowInfo $windowInfo

if ($AppId -eq "nte") {
    Update-NteLauncherConfig -ProjectPath $projectPath -GamePath $processPath
}

Write-Host "Game verification completed."
