param(
    [string]$Root = "",
    [int]$TimeoutSeconds = 10
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

    if (Test-JsonProperty -Object $Object -Name $Name) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Test-JsonProperty {
    param(
        [AllowNull()][object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    $null -ne $Object.PSObject.Properties[$Name]
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

    if (-not (Test-JsonProperty -Object $Object -Name $Name) -or $null -eq $Object.$Name) {
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

function Update-RootSettings {
    param(
        [string]$RootPath,
        [string]$InstallPath,
        [string]$MumuCliPath
    )

    $settingsPath = Join-Path $RootPath "Setting.json"
    $settings = Read-JsonObject $settingsPath
    Set-JsonProperty $settings "settings_version" 6

    $apps = Get-OrCreateJsonObjectProperty -Object $settings -Name "apps"

    $appIds = @("maa")
    foreach ($appId in $appIds) {
        if (-not (Test-JsonProperty -Object $apps -Name $appId) -or $null -eq $apps.$appId) {
            Set-JsonProperty $apps $appId ([PSCustomObject]@{})
        }

        $appSettings = $apps.$appId
        Set-JsonProperty $appSettings "mumu_dir" $InstallPath
        Set-JsonProperty $appSettings "mumu_cli" $MumuCliPath
        Set-JsonProperty $appSettings "mumu_verified" $true

        if (-not (Test-JsonProperty -Object $appSettings -Name "enabled")) {
            Set-JsonProperty $appSettings "enabled" $false
        }
        if (-not (Test-JsonProperty -Object $appSettings -Name "times")) {
            Set-JsonProperty $appSettings "times" @()
        }
    }

    if (-not (Test-JsonProperty -Object $settings -Name "last_runs")) {
        Set-JsonProperty $settings "last_runs" ([PSCustomObject]@{})
    }
    if (-not (Test-JsonProperty -Object $settings -Name "log_archives")) {
        Set-JsonProperty $settings "log_archives" ([PSCustomObject]@{})
    }

    Save-JsonObject $settingsPath $settings
    Write-Host "Updated root settings: $settingsPath"
    Write-Host "  mumu_dir=$InstallPath"
    Write-Host "  mumu_cli=$MumuCliPath"
}

if (-not $Root) {
    $Root = Join-Path $PSScriptRoot ".."
}
$Root = Resolve-FullPath $Root

$muMuProcessNames = @("MuMuNxMain.exe", "MuMuPlayer.exe", "NemuHeadless.exe")
$processInfo = $null
$processName = ""

foreach ($name in $muMuProcessNames) {
    Write-Host "Looking for $name process..."
    $processInfo = Get-RunningProcessInfo -Name $name -Timeout 0
    if ($processInfo) {
        $processName = $name
        break
    }
}

if (-not $processInfo) {
    Write-Host "Looking for MuMu process (up to $TimeoutSeconds seconds)..."
    Write-Host "Please start MuMu Player 12 if it is not running."
    foreach ($name in $muMuProcessNames) {
        $processInfo = Get-RunningProcessInfo -Name $name -Timeout $TimeoutSeconds
        if ($processInfo) {
            $processName = $name
            break
        }
    }
}

if (-not $processInfo) {
    Write-Host "MuMu process was not found. Please start MuMu Player 12 and try again."
    exit 2
}

$processPath = [string]$processInfo.ExecutablePath

if (-not $processPath) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MuMuProcessHelper
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, StringBuilder lpExeName, ref uint lpdwSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    public static string GetProcessPath(int processId)
    {
        IntPtr hProcess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (hProcess == IntPtr.Zero) return "";
        try
        {
            StringBuilder sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            if (QueryFullProcessImageName(hProcess, 0, sb, ref size))
                return sb.ToString();
            return "";
        }
        finally { CloseHandle(hProcess); }
    }
}
"@ -ErrorAction SilentlyContinue
        $processPath = [MuMuProcessHelper]::GetProcessPath($processInfo.ProcessId)
    }
    catch {
    }
}

if (-not $processPath) {
    Write-Host "Found MuMu process pid=$($processInfo.ProcessId) but could not determine its path."
    exit 2
}

Write-Host "Found ${processName}: pid=$($processInfo.ProcessId), path=$processPath"

# Derive mumu-cli.exe path
# MuMu 12 (NxMain):  <install>\nx_main\MuMuNxMain.exe + mumu-cli.exe  (same dir)
# MuMu 12 (Player):  <install>\shell\MuMuPlayer.exe  ->  <install>\nx_main\mumu-cli.exe
$processDir = Split-Path -Parent $processPath
$mumuCliPath = ""

# Strategy 1: same directory (covers MuMuNxMain.exe)
$candidate = Join-Path $processDir "mumu-cli.exe"
if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $mumuCliPath = $candidate
}

# Strategy 2: go up to install root, then nx_main\mumu-cli.exe (covers MuMuPlayer.exe in \shell\)
if (-not $mumuCliPath) {
    $installRoot = $processDir
    if ($processName -eq "MuMuPlayer.exe" -and (Split-Path -Leaf $processDir) -eq "shell") {
        $installRoot = Split-Path -Parent $processDir
    }
    $candidate = Join-Path $installRoot "nx_main\mumu-cli.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $mumuCliPath = $candidate
    }
    else {
        # Also try going up one level from processDir if that wasn't shell
        if ($installRoot -ne (Split-Path -Parent $processDir)) {
            $alt = Join-Path (Split-Path -Parent $processDir) "nx_main\mumu-cli.exe"
            if (Test-Path -LiteralPath $alt -PathType Leaf) {
                $mumuCliPath = $alt
            }
        }
    }
}

# Strategy 3: recursive search
if (-not $mumuCliPath) {
    Write-Host "Searching for mumu-cli.exe near process path..."
    $searchRoot = if ($processName -eq "MuMuPlayer.exe" -and (Split-Path -Leaf $processDir) -eq "shell") {
        Split-Path -Parent $processDir
    } else {
        Split-Path -Parent $processDir
    }
    if (-not $searchRoot) { $searchRoot = $processDir }
    $found = Get-ChildItem -LiteralPath $searchRoot -Recurse -File -Filter "mumu-cli.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) {
        $mumuCliPath = $found.FullName
    }
}

if (-not $mumuCliPath) {
    Write-Host "mumu-cli.exe was not found. Is MuMu Player 12 installed correctly?"
    exit 2
}

$installPath = Split-Path -Parent $mumuCliPath
Update-RootSettings -RootPath $Root -InstallPath $installPath -MumuCliPath $mumuCliPath
Write-Host "MuMu verification completed."
Write-Host "mumu_dir=$installPath"
Write-Host "mumu_cli=$mumuCliPath"
