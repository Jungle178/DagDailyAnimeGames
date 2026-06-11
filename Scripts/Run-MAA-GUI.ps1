param(
    [string]$Config = "",
    [string]$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path,
    [string]$MaaDir = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-EnvValue {
    param([string]$Name)

    [Environment]::GetEnvironmentVariable($Name)
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

    if ($settings.apps.$AppId.install_dir) {
        return [string]$settings.apps.$AppId.install_dir
    }

    return ""
}

function Resolve-MaaDir {
    param(
        [string]$ExplicitDir,
        [string]$RootPath
    )

    $envDir = Get-EnvValue "MAA_DIR"
    $settingDir = Get-SettingInstallDir -RootPath $RootPath -AppId "maa-gui"
    if (-not $settingDir) {
        $settingDir = Get-SettingInstallDir -RootPath $RootPath -AppId "maa"
    }
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

function Resolve-MaaExe {
    param([string]$Dir)

    $maaExe = Join-Path $Dir "MAA.exe"
    if (-not (Test-Path -LiteralPath $maaExe -PathType Leaf)) {
        throw "MAA.exe not found in: $Dir"
    }
    return $maaExe
}

$MaaDir = Resolve-MaaDir -ExplicitDir $MaaDir -RootPath $Root
$MaaExe = Resolve-MaaExe -Dir $MaaDir

if ($Config) {
    Write-Host "Starting MAA GUI: $MaaExe --config $Config"
    Start-Process -FilePath $MaaExe -ArgumentList "--config", $Config -WorkingDirectory $MaaDir -Wait
} else {
    Write-Host "Starting MAA GUI: $MaaExe"
    Start-Process -FilePath $MaaExe -WorkingDirectory $MaaDir -Wait
}
