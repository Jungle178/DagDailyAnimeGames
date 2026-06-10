param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("wuthering", "endfield", "nte")]
    [string]$AppId,
    [string]$Root = "",
    [int]$TimeoutSeconds = 0
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

function Update-DevicesConfig {
    param(
        [string]$ProjectPath,
        [string]$ProcessName,
        [string]$ProcessPath
    )

    $configPath = Join-Path $ProjectPath "configs\devices.json"
    $config = Read-JsonObject $configPath
    Set-JsonProperty $config "preferred" "pc"
    Set-JsonProperty $config "pc_full_path" $ProcessPath
    Set-JsonProperty $config "capture" "windows"
    Set-JsonProperty $config "selected_exe" $ProcessName
    Set-JsonProperty $config "selected_hwnd" 0
    if (-not ($config.PSObject.Properties.Name -contains "interaction")) {
        Set-JsonProperty $config "interaction" ""
    }
    Save-JsonObject $configPath $config
    Write-Host "Updated devices config: $configPath"
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
        DisplayName = "ok-wuthering-waves"
    }
    endfield = @{
        Path = "src\ok-end-field"
        ProcessName = "Endfield.exe"
        DisplayName = "ok-end-field"
    }
    nte = @{
        Path = "src\ok-nte"
        ProcessName = "HTGame.exe"
        DisplayName = "ok-nte"
    }
}

$app = $apps[$AppId]
$projectPath = Join-Path $Root $app.Path
if (-not (Test-Path -LiteralPath (Join-Path $projectPath "main.py") -PathType Leaf)) {
    throw "Project is not installed: $projectPath"
}

$processName = $app.ProcessName
Write-Host "Looking for $($app.DisplayName) game process: $processName"
$processInfo = Get-RunningProcessInfo -Name $processName -Timeout $TimeoutSeconds
if (-not $processInfo) {
    Write-Host "Game process was not found. Open the game, wait for its window, then try verification again."
    exit 2
}

$processPath = $processInfo.ExecutablePath
if (-not (Test-Path -LiteralPath $processPath -PathType Leaf)) {
    throw "Detected process path does not exist: $processPath"
}

Write-Host "Found game process: pid=$($processInfo.ProcessId), path=$processPath"
Update-DevicesConfig -ProjectPath $projectPath -ProcessName $processName -ProcessPath $processPath

if ($AppId -eq "nte") {
    Update-NteLauncherConfig -ProjectPath $projectPath -GamePath $processPath
}

Write-Host "Game verification completed."
