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

function Get-JsonPropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $null
}

function Get-SettingInstallDir {
    param(
        [string]$RootPath,
        [string]$AppId
    )

    $settingsPath = Join-Path $RootPath "Setting.json"
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return ""
    }

    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return ""
    }

    $apps = Get-JsonPropertyValue -Object $settings -Name "apps"
    $appSettings = Get-JsonPropertyValue -Object $apps -Name $AppId
    $installDir = Get-JsonPropertyValue -Object $appSettings -Name "install_dir"
    if ([string]::IsNullOrWhiteSpace([string]$installDir)) {
        return ""
    }

    [string]$installDir
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

function Resolve-MaaInstallDir {
    param(
        [string]$ExplicitDir,
        [string]$RootPath
    )

    $envDir = Get-EnvValue "MAA_DIR"
    $settingDir = Get-SettingInstallDir -RootPath $RootPath -AppId "maa"
    $candidates = @(
        $ExplicitDir,
        $envDir,
        $settingDir,
        (Join-Path $RootPath "src\MAA"),
        (Join-Path $RootPath "src\MaaAssistantArknights"),
        (Join-Path $RootPath "Apps\MAA")
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $maaExe = Join-Path $candidate "MAA.exe"
        if (Test-Path -LiteralPath $maaExe -PathType Leaf) {
            return $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate)
        }
    }

    if ($ExplicitDir) {
        return $ExplicitDir
    }

    return Join-Path $RootPath "Apps\MAA"
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

function Get-SettingMumuDir {
    param(
        [string]$RootPath,
        [string]$AppId
    )

    $settingsPath = Join-Path $RootPath "Setting.json"
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return ""
    }

    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return ""
    }

    $apps = Get-JsonPropertyValue -Object $settings -Name "apps"
    $appSettings = Get-JsonPropertyValue -Object $apps -Name $AppId
    if ($appSettings -and $appSettings.mumu_verified -eq $true) {
        return [string]$appSettings.mumu_dir
    }
    return ""
}

function Get-SettingMumuCli {
    param(
        [string]$RootPath,
        [string]$AppId
    )

    $settingsPath = Join-Path $RootPath "Setting.json"
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return ""
    }

    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return ""
    }

    $apps = Get-JsonPropertyValue -Object $settings -Name "apps"
    $appSettings = Get-JsonPropertyValue -Object $apps -Name $AppId
    if ($appSettings -and $appSettings.mumu_verified -eq $true) {
        return [string]$appSettings.mumu_cli
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

function Require-File {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Invoke-QuietNativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$IgnoreExitCode
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
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ((-not $IgnoreExitCode) -and $process.ExitCode -ne 0) {
        throw "$FilePath $($Arguments -join ' ') exited with code $($process.ExitCode): $stderr"
    }

    return $stdout
}

function Resolve-PowerShellPath {
    $windowsPowerShell = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
        return $windowsPowerShell
    }

    $pwsh = Join-Path $PSHOME "pwsh.exe"
    if (Test-Path -LiteralPath $pwsh -PathType Leaf) {
        return $pwsh
    }

    $command = Get-Command "powershell.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $command = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "PowerShell executable was not found."
}

function Start-MaaCliConfigSyncJob {
    param(
        [string]$RootPath,
        [string]$InstallDir
    )

    $installer = Join-Path $PSScriptRoot "Install-App.ps1"
    Require-File $installer

    Write-Host "Syncing maa-cli config from MAA GUI settings while MuMu starts..."
    $powerShell = Resolve-PowerShellPath
    Start-Job -ScriptBlock {
        param(
            [string]$PowerShellPath,
            [string]$InstallerPath,
            [string]$RootArg,
            [string]$InstallDirArg
        )

        & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $InstallerPath maa -Root $RootArg -MaaDir $InstallDirArg -SkipInstall *>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Install-App.ps1 exited with code $exitCode"
        }
    } -ArgumentList $powerShell, $installer, $RootPath, $InstallDir
}

function Complete-MaaCliConfigSyncJob {
    param([AllowNull()][object]$Job)

    if ($null -eq $Job) {
        return
    }

    Write-Host "Waiting for maa-cli config sync..."
    Wait-Job -Job $Job | Out-Null
    $output = @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)
    foreach ($line in $output) {
        if ($null -ne $line -and [string]$line -ne "") {
            Write-Host $line
        }
    }

    $state = $Job.State
    Remove-Job -Job $Job -Force
    if ($state -ne "Completed") {
        throw "Failed to sync maa-cli config; sync job state was $state"
    }
}

function Stop-MaaCliConfigSyncJob {
    param([AllowNull()][object]$Job)

    if ($null -eq $Job) {
        return
    }

    try {
        if ($Job.State -eq "Running") {
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Failed to clean maa-cli config sync job: $_"
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
        Invoke-QuietNativeCommand -FilePath $AdbPath -Arguments @("connect", $Serial) -IgnoreExitCode | Out-Null
        $devices = Invoke-QuietNativeCommand -FilePath $AdbPath -Arguments @("devices") -IgnoreExitCode
        if ($devices -match ([regex]::Escape($Serial) + "\s+device")) {
            return
        }
        if ($devices -match ([regex]::Escape($Serial) + "\s+offline")) {
            Invoke-QuietNativeCommand -FilePath $AdbPath -Arguments @("disconnect", $Serial) -IgnoreExitCode | Out-Null
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
            if ($info.is_android_started -eq $true -or $info.player_state -eq "start_finished") {
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

    Invoke-QuietNativeCommand -FilePath $AdbPath -Arguments @("disconnect", $Serial) -IgnoreExitCode | Out-Null
    Invoke-QuietNativeCommand -FilePath $AdbPath -Arguments @("kill-server") -IgnoreExitCode | Out-Null
    Start-Sleep -Seconds 2
    Invoke-QuietNativeCommand -FilePath $AdbPath -Arguments @("start-server") -IgnoreExitCode | Out-Null
    Invoke-QuietNativeCommand -FilePath $AdbPath -Arguments @("connect", $Serial) -IgnoreExitCode | Out-Null
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

$MaaDir = Resolve-MaaInstallDir -ExplicitDir $MaaDir -RootPath $Root

$MaaCli = Resolve-MaaCliPath -ExplicitPath $MaaCli -InstallDir $MaaDir
$settingMumuCli = Get-SettingMumuCli -RootPath $Root -AppId "maa"
if (-not $MumuCli -and $settingMumuCli) {
    $MumuCli = $settingMumuCli
}
$MumuCli = Resolve-MuMuCliPath -ExplicitPath $MumuCli
$Adb = Resolve-AdbPath -ExplicitPath $Adb -MumuCliPath $MumuCli

Require-File $MaaCli
Require-File $MumuCli
Require-File $Adb
Require-File (Join-Path $MaaDir "MAA.exe")

$maaArgs = @("--batch", "--no-summary")
if (-not $Quiet) {
    $maaArgs += "-v"
}

$adbReady = $false
$syncJob = $null

try {
    Write-Host "Launching MuMu vmindex $VmIndex..."
    & $MumuCli control --vmindex $VmIndex launch
    $syncJob = Start-MaaCliConfigSyncJob -RootPath $Root -InstallDir $MaaDir

    Write-Host "Waiting for MuMu Android..."
    Wait-MuMuAndroid -MumuPath $MumuCli -Index $VmIndex -TimeoutSeconds $WaitSeconds
    Complete-MaaCliConfigSyncJob -Job $syncJob
    $syncJob = $null

    Write-Host "Resetting ADB connection $Device..."
    Reset-AdbConnection -AdbPath $Adb -Serial $Device

    Write-Host "Waiting for ADB device $Device..."
    Wait-AdbDevice -AdbPath $Adb -Serial $Device -TimeoutSeconds $WaitSeconds
    $adbReady = $true

    Write-Host "Running maa-cli task: $TaskName"
    Invoke-MaaCli -Arguments (@("run", $TaskName) + $maaArgs)
}
finally {
    Stop-MaaCliConfigSyncJob -Job $syncJob

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
        Invoke-QuietNativeCommand -FilePath $Adb -Arguments @("disconnect", $Device) -IgnoreExitCode | Out-Null
        Invoke-QuietNativeCommand -FilePath $Adb -Arguments @("kill-server") -IgnoreExitCode | Out-Null
    }
    catch {
        Write-Warning "Failed to clean ADB connection: $_"
    }
}
