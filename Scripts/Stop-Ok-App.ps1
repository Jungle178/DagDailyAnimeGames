param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("wuthering", "endfield", "nte", "starrail")]
    [string]$AppId,
    [string]$Root = "",
    [string]$ProjectDir = "",
    [string[]]$GameProcessName = @()
)

$ErrorActionPreference = "Continue"

function Resolve-FullPathIfPossible {
    param([string]$Path)

    try {
        return $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }
    catch {
        return $Path
    }
}

function Invoke-TaskKillTree {
    param(
        [int]$ProcessId,
        [string]$Reason
    )

    Write-Host "Stopping process tree PID=$ProcessId ($Reason)"
    $output = & taskkill /PID $ProcessId /T /F 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output)) {
        if ($null -ne $line -and "$line".Trim()) {
            Write-Host $line
        }
    }
    Write-Host "taskkill PID=$ProcessId exit code: $exitCode"
}

function Stop-GameProcesses {
    param([string[]]$Names)

    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $safeName = $name.Replace("'", "''")
        $processes = @(Get-CimInstance Win32_Process -Filter "Name = '$safeName'" -ErrorAction SilentlyContinue)
        if ($processes.Count -eq 0) {
            Write-Host "No game process found: $name"
            continue
        }

        foreach ($process in $processes) {
            Invoke-TaskKillTree -ProcessId ([int]$process.ProcessId) -Reason $name
        }
    }
}

function Test-CommandLineMatches {
    param(
        [string]$CommandLine,
        [string[]]$Tokens
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    foreach ($token in @($Tokens)) {
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($CommandLine.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Stop-ScopedPythonProcesses {
    param(
        [string]$ResolvedProjectDir,
        [string]$ProjectName
    )

    $mainScript = Join-Path $ResolvedProjectDir "main.py"
    $tokens = @(
        $ResolvedProjectDir,
        $ResolvedProjectDir.Replace("\", "/"),
        $mainScript,
        $mainScript.Replace("\", "/"),
        "\$ProjectName\",
        "/$ProjectName/"
    ) | Sort-Object -Unique

    $pythonNames = @("python.exe", "pythonw.exe")
    $matched = 0
    foreach ($pythonName in $pythonNames) {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name = '$pythonName'" -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            if (-not (Test-CommandLineMatches -CommandLine $commandLine -Tokens $tokens)) {
                continue
            }

            $matched += 1
            Invoke-TaskKillTree -ProcessId ([int]$process.ProcessId) -Reason "$pythonName for $ProjectName"
        }
    }

    if ($matched -eq 0) {
        Write-Host "No scoped Python residuals found for $ProjectName."
    }
}

$projectNames = @{
    wuthering = "ok-wuthering-waves"
    endfield = "ok-end-field"
    nte = "ok-nte"
    starrail = "StarRailAssistant"
}

$defaultGameProcessNames = @{
    wuthering = @("Client-Win64-Shipping.exe")
    endfield = @("Endfield.exe")
    nte = @("HTGame.exe")
    starrail = @("StarRail.exe")
}

if (-not $Root) {
    $Root = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
}
$Root = Resolve-FullPathIfPossible $Root
if (-not $ProjectDir) {
    $ProjectDir = Join-Path $Root ("src\" + $projectNames[$AppId])
}
$ProjectDir = Resolve-FullPathIfPossible $ProjectDir

if ($GameProcessName.Count -eq 0) {
    $GameProcessName = $defaultGameProcessNames[$AppId]
}

Write-Host "Cleaning ok app residuals: app=$AppId project=$ProjectDir"
Stop-GameProcesses -Names $GameProcessName
Stop-ScopedPythonProcesses -ResolvedProjectDir $ProjectDir -ProjectName $projectNames[$AppId]
