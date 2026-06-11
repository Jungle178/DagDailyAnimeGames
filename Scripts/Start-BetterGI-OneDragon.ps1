param(
    [string]$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path,
    [string]$ExePath = "",
    [string]$WorkingDirectory = "",
    [string]$StartArgument = "startOneDragon",
    [int]$LaunchTimeoutSeconds = 60,
    [int]$PollSeconds = 30,
    [int]$MaxWaitHours = 4
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-EnvValue {
    param([string]$Name)

    [Environment]::GetEnvironmentVariable($Name)
}

function Get-JsonPropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $null
}

function Get-SettingInstallDir {
    param(
        [string]$RootPath,
        [string]$AppId
    )

    $settingsPath = Join-Path $RootPath "Setting.json"
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return ""
    }

    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return ""
    }

    $apps = Get-JsonPropertyValue -Object $settings -Name "apps"
    $appSettings = Get-JsonPropertyValue -Object $apps -Name $AppId
    $installDir = Get-JsonPropertyValue -Object $appSettings -Name "install_dir"
    if ([string]::IsNullOrWhiteSpace([string]$installDir)) {
        return ""
    }

    [string]$installDir
}

function Resolve-BetterGiDirectory {
    param(
        [string]$ExplicitDirectory,
        [string]$RootPath
    )

    $envDir = Get-EnvValue "BETTERGI_DIR"
    $settingDir = Get-SettingInstallDir -RootPath $RootPath -AppId "bettergi"
    $candidates = @(
        $ExplicitDirectory,
        $envDir,
        $settingDir,
        (Join-Path $RootPath "src\BetterGI"),
        (Join-Path $RootPath "src\better-genshin-impact"),
        (Join-Path $RootPath "Apps\BetterGI")
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $candidateExe = Join-Path $candidate "BetterGI.exe"
        if (Test-Path -LiteralPath $candidateExe -PathType Leaf) {
            return $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate)
        }
    }

    if ($ExplicitDirectory) {
        return $ExplicitDirectory
    }

    return Join-Path $RootPath "Apps\BetterGI"
}

if (-not $WorkingDirectory) {
    $WorkingDirectory = Resolve-BetterGiDirectory -ExplicitDirectory $WorkingDirectory -RootPath $Root
}

if (-not $ExePath) {
    $ExePath = Join-Path $WorkingDirectory "BetterGI.exe"
}

if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    throw "BetterGI executable was not found: $ExePath"
}

if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    throw "Working directory was not found: $WorkingDirectory"
}

Push-Location -LiteralPath $WorkingDirectory
try {
    & $ExePath $StartArgument
}
finally {
    Pop-Location
}

$launchDeadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
do {
    $betterGiProcesses = @(Get-Process -Name "BetterGI" -ErrorAction SilentlyContinue)
    if ($betterGiProcesses.Count -gt 0) {
        break
    }

    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $launchDeadline)

if ($betterGiProcesses.Count -eq 0) {
    throw "BetterGI did not appear within $LaunchTimeoutSeconds seconds after launch."
}

Write-Host "BetterGIStarted=True"

$exitDeadline = (Get-Date).AddHours($MaxWaitHours)
while ((Get-Date) -lt $exitDeadline) {
    $betterGiProcesses = @(Get-Process -Name "BetterGI" -ErrorAction SilentlyContinue)
    if ($betterGiProcesses.Count -eq 0) {
        Write-Host "BetterGIExited=True"
        exit 0
    }

    Start-Sleep -Seconds $PollSeconds
}

throw "Timed out waiting for BetterGI to exit."
