param(
    [string]$Root = "",
    [string]$ProjectDir = "",
    [string]$Python = "",
    [int]$TaskIndex = 2
)

$ErrorActionPreference = "Stop"

if (-not $Root) {
    $Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}

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

$MainScript = Join-Path $ProjectDir "main.py"
if (-not (Test-Path -LiteralPath $MainScript -PathType Leaf)) {
    throw "ok-nte main script not found: $MainScript"
}

Push-Location -LiteralPath $ProjectDir
try {
    & $Python $MainScript -t $TaskIndex -e
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "ok-nte exited with code $exitCode"
    }
}
finally {
    Pop-Location
}
