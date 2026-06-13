param(
    [string]$Root = "",
    [string]$VenvName = ".venv",
    [string]$RequirementsPath = "",
    [switch]$Recreate,
    [switch]$SkipInstall,
    [switch]$SkipPythonInstall,
    [switch]$SkipValidation
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BundledPythonVersion = "3.12.10"

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

function Get-PythonVersionText {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    $versionArgs = @($Arguments) + @("-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")
    $version = & $FilePath @versionArgs
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    [string]($version | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
}

function Test-CompatiblePythonVersion {
    param([string]$Version)

    $match = [regex]::Match($Version, "^(\d+)\.(\d+)(?:\.(\d+))?$")
    if (-not $match.Success) {
        return $false
    }

    $major = [int]$match.Groups[1].Value
    $minor = [int]$match.Groups[2].Value
    return ($major -eq 3 -and $minor -in @(11, 12, 13))
}

function Get-PythonCandidateList {
    $candidates = @(
        @{ FilePath = "py"; Arguments = @("-3.12") },
        @{ FilePath = "py"; Arguments = @("-3.13") },
        @{ FilePath = "py"; Arguments = @("-3.11") }
    )

    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $localPythonRoot = Join-Path $localAppData "Programs\Python"
        foreach ($directoryName in @("Python312", "Python313", "Python311")) {
            $candidates += @{ FilePath = (Join-Path (Join-Path $localPythonRoot $directoryName) "python.exe"); Arguments = @() }
        }
    }

    foreach ($programRoot in @($env:ProgramFiles, [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"))) {
        if ([string]::IsNullOrWhiteSpace($programRoot)) {
            continue
        }
        foreach ($directoryName in @("Python312", "Python313", "Python311")) {
            $candidates += @{ FilePath = (Join-Path (Join-Path $programRoot $directoryName) "python.exe"); Arguments = @() }
        }
    }

    $candidates += @(
        @{ FilePath = "python"; Arguments = @() },
        @{ FilePath = "python3"; Arguments = @() }
    )

    $candidates
}

function Get-CompatiblePython {
    foreach ($candidate in (Get-PythonCandidateList)) {
        try {
            $version = Get-PythonVersionText -FilePath $candidate.FilePath -Arguments $candidate.Arguments
            if (Test-CompatiblePythonVersion $version) {
                $candidate["Version"] = $version
                return $candidate
            }
        }
        catch {
            Write-Verbose "Python candidate failed: $($candidate.FilePath) $($candidate.Arguments -join ' ')"
        }
    }

    return $null
}

function Get-PythonInstallerInfo {
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = ""
    }

    if ($architecture -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64") {
        $fileName = "python-$BundledPythonVersion-arm64.exe"
    }
    elseif ([Environment]::Is64BitOperatingSystem) {
        $fileName = "python-$BundledPythonVersion-amd64.exe"
    }
    else {
        $fileName = "python-$BundledPythonVersion.exe"
    }

    [PSCustomObject]@{
        FileName = $fileName
        Uri = "https://www.python.org/ftp/python/$BundledPythonVersion/$fileName"
    }
}

function Save-UrlToFile {
    param(
        [string]$Uri,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Write-Host "Using cached download: $Destination"
        return
    }

    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    Write-Host "Downloading Python installer: $Uri"
    $oldProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
    }
    catch {
        throw "Failed to download Python installer from $Uri. $_"
    }
    finally {
        $ProgressPreference = $oldProgressPreference
    }

    Require-File $Destination
}

function Install-LocalPython {
    param([string]$RootPath)

    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw "Cannot resolve LocalApplicationData; install Python 3.11, 3.12, or 3.13 manually and retry."
    }

    $installerInfo = Get-PythonInstallerInfo
    $downloadDir = Join-Path $RootPath "Apps\_downloads\python"
    $installerPath = Join-Path $downloadDir $installerInfo.FileName
    Save-UrlToFile -Uri $installerInfo.Uri -Destination $installerPath

    $targetDir = Join-Path $localAppData "Programs\Python\Python312"
    $logPath = Join-Path $downloadDir "python-$BundledPythonVersion-install.log"
    $installerArgs = @(
        "/quiet",
        "/log",
        $logPath,
        "InstallAllUsers=0",
        "InstallLauncherAllUsers=0",
        "TargetDir=$targetDir",
        "PrependPath=0",
        "Include_launcher=0",
        "Include_pip=1",
        "Include_tcltk=1",
        "Include_test=0",
        "Include_doc=0",
        "Shortcuts=0"
    )

    Write-Host "Installing Python $BundledPythonVersion to: $targetDir"
    Push-Location -LiteralPath $RootPath
    try {
        Write-Host "> $installerPath $($installerArgs -join ' ')"
        & $installerPath @installerArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $exitCode -ne 3010) {
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                Write-Host "Python installer log: $logPath"
                Get-Content -LiteralPath $logPath -Tail 40 -ErrorAction SilentlyContinue |
                    ForEach-Object { Write-Host "[python-installer] $_" }
            }
            throw "$installerPath $($installerArgs -join ' ') exited with code $exitCode"
        }
    }
    finally {
        Pop-Location
    }
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

    Write-Host "Removing existing venv: $resolvedVenv"
    Remove-Item -LiteralPath $resolvedVenv -Recurse -Force
}

if (-not $Root) {
    $Root = Join-Path $PSScriptRoot ".."
}
$Root = Resolve-FullPath $Root
if (-not $RequirementsPath) {
    $RequirementsPath = Join-Path $Root "requirements.txt"
}
else {
    $RequirementsPath = Resolve-FullPath $RequirementsPath
}

$VenvPath = Resolve-FullPath (Join-Path $Root $VenvName)
$VenvPython = Join-Path $VenvPath "Scripts\python.exe"

Require-Directory $Root
Require-File $RequirementsPath

if ($Recreate) {
    Remove-VenvSafely -RootPath $Root -VenvPath $VenvPath
}

if (Test-Path -LiteralPath $VenvPython -PathType Leaf) {
    try {
        $venvVersion = Get-PythonVersionText -FilePath $VenvPython
    }
    catch {
        $venvVersion = ""
    }

    if (Test-CompatiblePythonVersion $venvVersion) {
        Write-Host "Using existing venv: $VenvPath (Python $venvVersion)"
    }
    else {
        if ([string]::IsNullOrWhiteSpace($venvVersion)) {
            Write-Host "Existing venv Python is broken; recreating shared venv."
        }
        else {
            Write-Host "Existing venv uses unsupported Python $venvVersion; recreating shared venv."
        }
        Remove-VenvSafely -RootPath $Root -VenvPath $VenvPath
    }
}
elseif (Test-Path -LiteralPath $VenvPath -PathType Container) {
    Write-Host "Existing venv is incomplete; recreating shared venv."
    Remove-VenvSafely -RootPath $Root -VenvPath $VenvPath
}

if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    $python = Get-CompatiblePython
    if ($null -eq $python) {
        if ($SkipPythonInstall) {
            throw "Compatible Python was not found. Install Python 3.11, 3.12, or 3.13 manually and retry."
        }

        Write-Host "Compatible Python was not found. Installing Python $BundledPythonVersion..."
        Install-LocalPython -RootPath $Root
        $python = Get-CompatiblePython
        if ($null -eq $python) {
            throw "Python installer completed, but compatible Python was not found. Install Python 3.11, 3.12, or 3.13 manually and retry."
        }
    }

    Write-Host "Creating venv: $VenvPath (Python $($python.Version))"
    Invoke-Checked -FilePath $python.FilePath -Arguments (@($python.Arguments) + @("-m", "venv", $VenvPath)) -WorkingDirectory $Root
}

Require-File $VenvPython

if (-not $SkipInstall) {
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "ensurepip", "--upgrade") -WorkingDirectory $Root
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "install", "-U", "pip", "setuptools", "wheel") -WorkingDirectory $Root
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "install", "-U", "-r", $RequirementsPath) -WorkingDirectory $Root
}
else {
    Write-Host "Skipping dependency installation."
}

if (-not $SkipValidation) {
    Invoke-Checked -FilePath $VenvPython -Arguments @("-c", "import tkinter; from PIL import Image, ImageTk; print('GUI environment OK')") -WorkingDirectory $Root
}
else {
    Write-Host "Skipping validation."
}

Write-Host "GUI venv is ready: $VenvPath"
Write-Host "Python: $VenvPython"
