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

if (-not $WorkingDirectory) {
    $WorkingDirectory = Join-Path $Root "Apps\BetterGI"
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
