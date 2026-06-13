param(
    [string]$Root = "",
    [string]$ProjectDir = "",
    [string]$Python = "",
    [int]$TaskIndex = 1,
    [int]$StartGameTaskIndex = 8,
    [string]$GameProcessName = "Endfield",
    [string]$GameWindowClass = "UnityWndClass",
    [int]$WindowMoveTimeoutSeconds = 180,
    [int]$WindowMoveIntervalMilliseconds = 2000,
    [switch]$RunStartGameTask,
    [switch]$SkipMoveToPrimary
)

$ErrorActionPreference = "Stop"

function Start-PrimaryWindowMover {
    param(
        [string]$ProcessName,
        [string]$WindowClass,
        [int]$TimeoutSeconds,
        [int]$IntervalMilliseconds
    )

    if ($SkipMoveToPrimary) {
        Write-Host "Skipping Endfield primary-monitor window move."
        return $null
    }

    $windowMoverScript = Join-Path $PSScriptRoot "Move-ProcessWindowToPrimary.ps1"
    if (-not (Test-Path -LiteralPath $windowMoverScript -PathType Leaf)) {
        Write-Warning "Window mover script was not found: $windowMoverScript"
        return $null
    }

    Write-Host "Starting Endfield primary-monitor window mover."
    return Start-Job -ScriptBlock {
        param(
            [string]$ScriptPath,
            [string]$ProcessName,
            [string]$WindowClass,
            [int]$TimeoutSeconds,
            [int]$IntervalMilliseconds
        )

        & $ScriptPath `
            -ProcessName $ProcessName `
            -WindowClass $WindowClass `
            -TimeoutSeconds $TimeoutSeconds `
            -IntervalMilliseconds $IntervalMilliseconds
    } -ArgumentList @(
        $windowMoverScript,
        $ProcessName,
        $WindowClass,
        $TimeoutSeconds,
        $IntervalMilliseconds
    )
}

function Stop-PrimaryWindowMover {
    param($Job)

    if ($null -eq $Job) {
        return
    }

    try {
        Wait-Job -Job $Job -Timeout 2 | Out-Null
        if ($Job.State -eq "Running") {
            Stop-Job -Job $Job | Out-Null
            Wait-Job -Job $Job -Timeout 2 | Out-Null
        }

        Receive-Job -Job $Job -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "[window-mover] $_" }
    }
    finally {
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-ProcessTree {
    param([int]$ProcessId)

    Write-Host "Force stopping process tree PID=$ProcessId"
    $output = & taskkill /PID $ProcessId /T /F 2>&1
    foreach ($line in @($output)) {
        if ($null -ne $line -and "$line".Trim()) {
            Write-Host $line
        }
    }
    $taskkillExitCode = $LASTEXITCODE
    if ($taskkillExitCode -ne 0) {
        Write-Host "taskkill PID=$ProcessId exit code: $taskkillExitCode"
        try {
            Stop-Process -Id $ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped root process PID=$ProcessId with Stop-Process fallback."
        }
        catch {
            Write-Warning "Stop-Process fallback failed for PID=$ProcessId`: $_"
        }
    }
}

function Invoke-OkEndFieldTask {
    param(
        [string]$PythonPath,
        [string]$MainScriptPath,
        [int]$Index,
        [string]$Name
    )

    Write-Host "Starting ok-end-field task '$Name' (index $Index)."
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $PythonPath
    $processInfo.Arguments = "`"$MainScriptPath`" -t $Index -e"
    $processInfo.WorkingDirectory = (Get-Location).Path
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true
    $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $processInfo.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    $state = [hashtable]::Synchronized(@{ Failed = $false })
    $eventData = [PSCustomObject]@{
        State = $state
        FailurePatterns = @(
            "exception stopped",
            "pywintypes.error:"
        )
    }
    $eventAction = {
        if ($null -eq $EventArgs.Data) {
            return
        }

        $line = [string]$EventArgs.Data
        Write-Host $line
        foreach ($pattern in $Event.MessageData.FailurePatterns) {
            if ($line.IndexOf([string]$pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $Event.MessageData.State.Failed = $true
                break
            }
        }
    }

    $outputSubscriber = $null
    $errorSubscriber = $null
    $detectedFailure = $false
    try {
        $outputSubscriber = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $eventAction -MessageData $eventData
        $errorSubscriber = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $eventAction -MessageData $eventData

        [void]$process.Start()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        while (-not $process.HasExited) {
            if ($state.Failed) {
                $detectedFailure = $true
                Write-Host "Detected ok-end-field task '$Name' failure output."
                Stop-ProcessTree -ProcessId $process.Id
                break
            }
            Start-Sleep -Milliseconds 500
        }

        if (-not $process.WaitForExit(10000)) {
            throw "ok-end-field task '$Name' did not exit after stop request"
        }

        $exitCode = $process.ExitCode
    }
    finally {
        if ($outputSubscriber) {
            Unregister-Event -SourceIdentifier $outputSubscriber.Name -ErrorAction SilentlyContinue
            Remove-Job -Job $outputSubscriber -Force -ErrorAction SilentlyContinue
        }
        if ($errorSubscriber) {
            Unregister-Event -SourceIdentifier $errorSubscriber.Name -ErrorAction SilentlyContinue
            Remove-Job -Job $errorSubscriber -Force -ErrorAction SilentlyContinue
        }
        if ($process) {
            $process.Dispose()
        }
    }

    if ($detectedFailure) {
        throw "ok-end-field task '$Name' reported failure output"
    }
    if ($exitCode -ne 0) {
        throw "ok-end-field task '$Name' exited with code $exitCode"
    }
    Write-Host "ok-end-field task '$Name' completed."
}

if (-not $Root) {
    $Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}

if (-not $ProjectDir) {
    $ProjectDir = Join-Path $Root "src\ok-end-field"
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
    throw "ok-end-field main script not found: $MainScript"
}

$windowMoverJob = Start-PrimaryWindowMover `
    -ProcessName $GameProcessName `
    -WindowClass $GameWindowClass `
    -TimeoutSeconds $WindowMoveTimeoutSeconds `
    -IntervalMilliseconds $WindowMoveIntervalMilliseconds

Push-Location -LiteralPath $ProjectDir
try {
    if ($RunStartGameTask -and $StartGameTaskIndex -gt 0) {
        Invoke-OkEndFieldTask `
            -PythonPath $Python `
            -MainScriptPath $MainScript `
            -Index $StartGameTaskIndex `
            -Name "start-game"
    }

    Invoke-OkEndFieldTask `
        -PythonPath $Python `
        -MainScriptPath $MainScript `
        -Index $TaskIndex `
        -Name "daily"
}
finally {
    Pop-Location
    Stop-PrimaryWindowMover -Job $windowMoverJob
}
