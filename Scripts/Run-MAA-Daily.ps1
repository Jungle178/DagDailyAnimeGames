param(
    [string]$TaskName = "daily",
    [string]$Device = "127.0.0.1:16384",
    [int]$VmIndex = 0,
    [int]$WaitSeconds = 120,
    [string]$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path,
    [string]$MaaDir = "",
    [string]$MaaCli = "",
    [string]$MumuCli = "",
    [string]$Adb = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
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

function Resolve-CommandPath {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return ""
}

function Resolve-MaaCliPath {
    param(
        [string]$ExplicitPath,
        [string]$InstallDir
    )

    $path = Resolve-FirstExistingFile @(
        $ExplicitPath,
        (Get-EnvValue "MAA_CLI"),
        (Join-Path $InstallDir "maa-cli.exe")
    )
    if ($path) {
        return $path
    }

    Resolve-CommandPath "maa-cli.exe"
}

function Resolve-MuMuCliPath {
    param([string]$ExplicitPath)

    $programFiles = Get-EnvValue "ProgramFiles"
    $programFilesX86 = Get-EnvValue "ProgramFiles(x86)"
    $candidates = @(
        $ExplicitPath,
        (Get-EnvValue "MAA_MUMU_CLI"),
        "E:\Program Files\Netease\MuMu Player 12\nx_main\mumu-cli.exe",
        "C:\Program Files\Netease\MuMu Player 12\nx_main\mumu-cli.exe"
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

function Require-File {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Wait-AdbDevice {
    param(
        [string]$AdbPath,
        [string]$Serial,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        & $AdbPath connect $Serial | Out-Null
        $devices = & $AdbPath devices
        if ($devices -match ([regex]::Escape($Serial) + "\s+device")) {
            return
        }
        if ($devices -match ([regex]::Escape($Serial) + "\s+offline")) {
            & $AdbPath disconnect $Serial | Out-Null
        }
        Start-Sleep -Seconds 2
    }

    throw "ADB device did not become online within $TimeoutSeconds seconds: $Serial"
}

function Wait-MuMuAndroid {
    param(
        [string]$MumuPath,
        [int]$Index,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $infoText = & $MumuPath info --vmindex $Index
            $info = $infoText | ConvertFrom-Json
            if ($info.launch_err_code -and $info.launch_err_code -ne 0) {
                throw "MuMu launch failed: $($info.launch_err_msg)"
            }
            if ($info.is_android_started -eq $true) {
                return
            }
        }
        catch {
            Write-Verbose "Waiting for MuMu info: $_"
        }

        Start-Sleep -Seconds 2
    }

    throw "MuMu Android did not start within $TimeoutSeconds seconds."
}

function Reset-AdbConnection {
    param(
        [string]$AdbPath,
        [string]$Serial
    )

    & $AdbPath disconnect $Serial | Out-Null
    & $AdbPath kill-server | Out-Null
    Start-Sleep -Seconds 2
    & $AdbPath start-server | Out-Null
    & $AdbPath connect $Serial | Out-Null
}

function Invoke-MaaCli {
    param(
        [string[]]$Arguments,
        [switch]$IgnoreExitCode
    )

    & $MaaCli @Arguments
    $exitCode = $LASTEXITCODE
    if ((-not $IgnoreExitCode) -and $exitCode -ne 0) {
        throw "maa-cli $($Arguments -join ' ') exited with code $exitCode"
    }
}

if (-not $MaaDir) {
    $MaaDir = Join-Path $Root "Apps\MAA"
}

$MaaCli = Resolve-MaaCliPath -ExplicitPath $MaaCli -InstallDir $MaaDir
$MumuCli = Resolve-MuMuCliPath -ExplicitPath $MumuCli
$Adb = Resolve-AdbPath -ExplicitPath $Adb -MumuCliPath $MumuCli

Require-File $MaaCli
Require-File $MumuCli
Require-File $Adb

$maaArgs = @("--batch", "--no-summary")
if (-not $Quiet) {
    $maaArgs += "-v"
}

$adbReady = $false

try {
    Write-Host "Launching MuMu vmindex $VmIndex..."
    & $MumuCli control --vmindex $VmIndex launch

    Write-Host "Waiting for MuMu Android..."
    Wait-MuMuAndroid -MumuPath $MumuCli -Index $VmIndex -TimeoutSeconds $WaitSeconds

    Write-Host "Resetting ADB connection $Device..."
    Reset-AdbConnection -AdbPath $Adb -Serial $Device

    Write-Host "Waiting for ADB device $Device..."
    Wait-AdbDevice -AdbPath $Adb -Serial $Device -TimeoutSeconds $WaitSeconds
    $adbReady = $true

    Write-Host "Running maa-cli task: $TaskName"
    Invoke-MaaCli -Arguments (@("run", $TaskName) + $maaArgs)
}
finally {
    if ($adbReady) {
        Write-Host "Closing game client..."
        try {
            Invoke-MaaCli -Arguments (@("closedown", "Official") + $maaArgs) -IgnoreExitCode
        }
        catch {
            Write-Warning "Failed to close game client: $_"
        }
    }
    else {
        Write-Host "Skipping game closedown because ADB was not ready."
    }

    Write-Host "Shutting down MuMu vmindex $VmIndex..."
    try {
        & $MumuCli control --vmindex $VmIndex shutdown
    }
    catch {
        Write-Warning "Failed to shutdown MuMu: $_"
    }

    Write-Host "Cleaning ADB connection $Device..."
    try {
        & $Adb disconnect $Device | Out-Null
        & $Adb kill-server | Out-Null
    }
    catch {
        Write-Warning "Failed to clean ADB connection: $_"
    }
}
