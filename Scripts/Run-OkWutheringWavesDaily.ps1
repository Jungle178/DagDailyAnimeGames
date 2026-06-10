param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

$script = Join-Path $PSScriptRoot "Test-OkWutheringWaves.ps1"
$arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script) + $RemainingArgs
& powershell @arguments
exit $LASTEXITCODE
