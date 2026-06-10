param(
    [string]$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path,
    [string]$ProjectDir = "",
    [string]$Python = "",
    [int]$TaskIndex = 2
)

$ErrorActionPreference = "Stop"

if (-not $ProjectDir) {
    $ProjectDir = Join-Path $Root "src\ok-nte"
}

if (-not $Python) {
    $Python = Join-Path $Root ".venv\Scripts\python.exe"
}

if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
    throw "Project directory not found: $ProjectDir"
}

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Python executable not found: $Python"
}

Push-Location -LiteralPath $ProjectDir
try {
    & $Python main.py -t $TaskIndex -e
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "ok-nte exited with code $exitCode"
    }
}
finally {
    Pop-Location
}
