param(
    [string]$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path,
    [string]$VenvName = ".venv",
    [string]$RequirementsPath = "",
    [switch]$Recreate,
    [switch]$SkipInstall,
    [switch]$SkipValidation
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-FullPath {
    param([string]$Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $PWD.Path
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

function Require-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory not found: $Path"
    }
}

function Get-Python312 {
    $candidates = @(
        @{ FilePath = "py"; Arguments = @("-3.12") },
        @{ FilePath = "python"; Arguments = @() }
    )

    foreach ($candidate in $candidates) {
        try {
            $versionArgs = @($candidate.Arguments) + @("-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
            $version = & $candidate.FilePath @versionArgs
            if ($LASTEXITCODE -eq 0 -and ($version | Select-Object -First 1) -eq "3.12") {
                return $candidate
            }
        }
        catch {
            Write-Verbose "Python candidate failed: $($candidate.FilePath) $($candidate.Arguments -join ' ')"
        }
    }

    throw "Python 3.12 was not found. Install Python 3.12 or make sure 'py -3.12' works."
}

function Remove-VenvSafely {
    param(
        [string]$RootPath,
        [string]$VenvPath
    )

    if (-not (Test-Path -LiteralPath $VenvPath)) {
        return
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path.TrimEnd("\")
    $resolvedVenv = (Resolve-Path -LiteralPath $VenvPath).Path.TrimEnd("\")
    $expectedPrefix = "$resolvedRoot\"

    if (-not $resolvedVenv.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove venv outside root: $resolvedVenv"
    }

    if ((Split-Path -Leaf $resolvedVenv) -ne $VenvName) {
        throw "Refusing to remove unexpected directory: $resolvedVenv"
    }

    Write-Host "Removing existing shared venv: $resolvedVenv"
    Remove-Item -LiteralPath $resolvedVenv -Recurse -Force
}

$Root = Resolve-FullPath $Root
$VenvPath = Resolve-FullPath (Join-Path $Root $VenvName)
$VenvPython = Join-Path $VenvPath "Scripts\python.exe"
if (-not $RequirementsPath) {
    $RequirementsPath = Join-Path $Root "requirements.txt"
}
else {
    $RequirementsPath = Resolve-FullPath $RequirementsPath
}
$MergeRequirementsScript = Join-Path $Root "Scripts\Merge-Requirements.py"

$Projects = @(
    "src\ok-end-field",
    "src\ok-nte",
    "src\ok-wuthering-waves"
)

$RequirementFiles = @(
    (Join-Path $Root "src\ok-end-field\requirements.txt"),
    (Join-Path $Root "src\ok-nte\requirements.txt"),
    (Join-Path $Root "src\ok-wuthering-waves\requirements.txt")
)

Require-Directory $Root
foreach ($project in $Projects) {
    Require-Directory (Join-Path $Root $project)
}
Require-File $MergeRequirementsScript
foreach ($requirementsFile in $RequirementFiles) {
    Require-File $requirementsFile
}

if ($Recreate) {
    Remove-VenvSafely -RootPath $Root -VenvPath $VenvPath
}

if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    $python = Get-Python312
    Write-Host "Creating shared venv: $VenvPath"
    Invoke-Checked -FilePath $python.FilePath -Arguments (@($python.Arguments) + @("-m", "venv", $VenvPath)) -WorkingDirectory $Root
}
else {
    Write-Host "Using existing shared venv: $VenvPath"
}

Require-File $VenvPython

Invoke-Checked -FilePath $VenvPython -Arguments (@($MergeRequirementsScript, "--output", $RequirementsPath) + $RequirementFiles) -WorkingDirectory $Root
Require-File $RequirementsPath

if (-not $SkipInstall) {
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "install", "-U", "pip", "setuptools", "wheel") -WorkingDirectory $Root
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "install", "-U", "-r", $RequirementsPath) -WorkingDirectory $Root
}
else {
    Write-Host "Skipping dependency installation."
}

if (-not $SkipValidation) {
    foreach ($project in $Projects) {
        $projectPath = Join-Path $Root $project
        Invoke-Checked -FilePath $VenvPython -Arguments @("-c", "import ok, main; print('$project import ok/main OK', ok.__file__)") -WorkingDirectory $projectPath
    }
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "check") -WorkingDirectory $Root
}
else {
    Write-Host "Skipping validation."
}

Write-Host "Shared OK venv is ready: $VenvPath"
Write-Host "Python: $VenvPython"
