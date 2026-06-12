param(
    [Parameter(Position = 0)]
    [ValidateSet("status", "start", "stop", "stop_all", "queue", "clear_queue", "set_schedule", "reload_settings", "exit")]
    [string]$Command = "status",

    [string]$AppId = "",
    [string]$Reason = "",
    [string[]]$Times = @(),
    [ValidateSet("", "true", "false")]
    [string]$Enabled = "",
    [switch]$Force,
    [string]$Time = "",
    [string]$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path,
    [string]$RawJson = ""
)

$ErrorActionPreference = "Stop"

$commandPath = Join-Path $Root "Logs\LocalDailyGui\debug_commands.jsonl"
$commandDir = Split-Path -Parent $commandPath
New-Item -ItemType Directory -Path $commandDir -Force | Out-Null

if ($RawJson) {
    $line = $RawJson.Trim()
}
else {
    $payload = [ordered]@{
        id      = [guid]::NewGuid().ToString("N")
        command = $Command
        at      = (Get-Date).ToString("s")
    }

    if ($AppId) {
        $payload.app_id = $AppId
    }
    if ($Reason) {
        $payload.reason = $Reason
    }
    if ($Times.Count -gt 0) {
        $payload.times = @($Times)
    }
    if ($Enabled) {
        $payload.enabled = [bool]::Parse($Enabled)
    }
    if ($Force.IsPresent) {
        $payload.force = $true
    }
    if ($Time) {
        $payload.time = $Time
    }

    $line = $payload | ConvertTo-Json -Compress
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($commandPath, $line + [Environment]::NewLine, $utf8NoBom)

Write-Host "Wrote command to $commandPath"
Write-Host $line
