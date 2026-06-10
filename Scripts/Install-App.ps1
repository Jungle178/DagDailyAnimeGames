param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("wuthering", "endfield", "nte")]
    [string]$AppId,
    [string]$Root = "",
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        Write-Host "> $FilePath $($Arguments -join ' ')"
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "$FilePath $($Arguments -join ' ') exited with code $exitCode"
        }
    }
    finally {
        Pop-Location
    }
}

function Require-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

$Apps = @{
    wuthering = @{ Path = "src\ok-wuthering-waves"; Name = "ok-wuthering-waves" }
    endfield = @{ Path = "src\ok-end-field"; Name = "ok-end-field" }
    nte = @{ Path = "src\ok-nte"; Name = "ok-nte" }
}

if (-not $Root) {
    $Root = Join-Path $PSScriptRoot ".."
}
$Root = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
$App = $Apps[$AppId]
$ProjectPath = Join-Path $Root $App.Path
$RequirementsPath = Join-Path $ProjectPath "requirements.txt"
$MainPath = Join-Path $ProjectPath "main.py"
$VenvPython = Join-Path $Root ".venv\Scripts\python.exe"
$SetupScript = Join-Path $Root "Scripts\Setup-OkSharedVenv.ps1"

Require-File $SetupScript
if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    Invoke-Checked -FilePath "powershell.exe" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SetupScript) -WorkingDirectory $Root
}

Write-Host "Installing $($App.Name)..."
Invoke-Checked -FilePath "git" -Arguments @("submodule", "update", "--init", "--recursive", "--", $App.Path) -WorkingDirectory $Root

Require-File $RequirementsPath
Require-File $MainPath
Require-File $VenvPython

if (-not $SkipInstall) {
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "install", "-U", "-r", $RequirementsPath) -WorkingDirectory $Root
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "check") -WorkingDirectory $Root
}
else {
    Write-Host "Skipping dependency installation."
}

Write-Host "$($App.Name) is ready."
