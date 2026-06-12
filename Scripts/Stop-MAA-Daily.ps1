param(
    [string]$Device = "127.0.0.1:16384",
    [int]$VmIndex = 0,
    [string]$MumuCli = "",
    [string]$Adb = ""
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

function Get-EnvValue {
    param([string]$Name)

    [Environment]::GetEnvironmentVariable($Name)
}

function Resolve-FirstExistingFile {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate)
        }
    }

    return ""
}

function Resolve-MuMuCliPath {
    param([string]$ExplicitPath)

    $programFiles = Get-EnvValue "ProgramFiles"
    $programFilesX86 = Get-EnvValue "ProgramFiles(x86)"
    $candidates = @(
        $ExplicitPath,
        (Get-EnvValue "MAA_MUMU_CLI")
    )
    if ($programFiles) {
        $candidates += (Join-Path $programFiles "Netease\MuMu Player 12\nx_main\mumu-cli.exe")
    }
    if ($programFilesX86) {
        $candidates += (Join-Path $programFilesX86 "Netease\MuMu Player 12\nx_main\mumu-cli.exe")
    }

    Resolve-FirstExistingFile $candidates
}

function Resolve-AdbPath {
    param(
        [string]$ExplicitPath,
        [string]$MumuCliPath
    )

    $candidates = @(
        $ExplicitPath,
        (Get-EnvValue "MAA_ADB")
    )
    if ($MumuCliPath) {
        $candidates += (Join-Path (Split-Path -Parent $MumuCliPath) "adb.exe")
    }

    Resolve-FirstExistingFile $candidates
}

function Invoke-QuietNativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ($Arguments -join " ")
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $process.StandardOutput.ReadToEnd() | Out-Null
    $process.StandardError.ReadToEnd() | Out-Null
    $process.WaitForExit()
}

$MumuCli = Resolve-MuMuCliPath -ExplicitPath $MumuCli
$Adb = Resolve-AdbPath -ExplicitPath $Adb -MumuCliPath $MumuCli

if ($MumuCli) {
    Write-Host "Shutting down MuMu vmindex $VmIndex..."
    & $MumuCli control --vmindex $VmIndex shutdown
}
else {
    Write-Host "MuMu CLI not found; skipping emulator shutdown."
}

if ($Adb) {
    Write-Host "Cleaning ADB connection $Device..."
    Invoke-QuietNativeCommand -FilePath $Adb -Arguments @("disconnect", $Device)
    Invoke-QuietNativeCommand -FilePath $Adb -Arguments @("kill-server")
}
else {
    Write-Host "ADB not found; skipping ADB cleanup."
}
