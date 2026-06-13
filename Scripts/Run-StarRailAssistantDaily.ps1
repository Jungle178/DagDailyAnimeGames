param(
    [string]$Root = "",
    [string]$ProjectDir = "",
    [string]$Python = "",
    [string[]]$ConfigName = @()
)

$ErrorActionPreference = "Stop"

function Stop-ProcessTree {
    param([int]$ProcessId)

    Write-Host "Force stopping process tree PID=$ProcessId"
    $output = & taskkill /PID $ProcessId /T /F 2>&1
    foreach ($line in @($output)) {
        if ($null -ne $line -and "$line".Trim()) {
            Write-Host $line
        }
    }
}

function ConvertTo-SraCliToken {
    param([string]$Value)

    if ($Value -notmatch "\s" -and $Value -notmatch '"') {
        return $Value
    }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-StarRailAssistantCli {
    param(
        [string]$PythonPath,
        [string]$MainScriptPath,
        [string[]]$Commands
    )

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $PythonPath
    $processInfo.Arguments = "`"$MainScriptPath`" --no-admin --inline"
    $processInfo.WorkingDirectory = (Get-Location).Path
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true
    $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $processInfo.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    $outputSubscriber = $null
    $errorSubscriber = $null
    $eventAction = {
        if ($null -ne $EventArgs.Data -and "$($EventArgs.Data)".Trim()) {
            Write-Host $EventArgs.Data
        }
    }

    try {
        $outputSubscriber = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $eventAction
        $errorSubscriber = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $eventAction

        [void]$process.Start()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        foreach ($command in $Commands) {
            Write-Host "sra> $command"
            $process.StandardInput.WriteLine($command)
        }
        $process.StandardInput.Close()

        while (-not $process.WaitForExit(1000)) {
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
        if ($process -and -not $process.HasExited) {
            Stop-ProcessTree -ProcessId $process.Id
        }
        if ($process) {
            $process.Dispose()
        }
    }

    if ($exitCode -ne 0) {
        throw "StarRailAssistant exited with code $exitCode"
    }
}

if (-not $Root) {
    $Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}

if (-not $ProjectDir) {
    $ProjectDir = Join-Path $Root "src\StarRailAssistant"
}

if (-not $Python) {
    $Python = Join-Path $Root ".venv-sra\Scripts\python.exe"
}

if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
    throw "Project directory not found: $ProjectDir"
}

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Python executable not found: $Python"
}

$MainScript = Join-Path $ProjectDir "main.py"
if (-not (Test-Path -LiteralPath $MainScript -PathType Leaf)) {
    throw "StarRailAssistant main script not found: $MainScript"
}

$runCommand = "run"
if ($ConfigName.Count -gt 0) {
    $runCommand += " " + (($ConfigName | ForEach-Object { ConvertTo-SraCliToken $_ }) -join " ")
}

Push-Location -LiteralPath $ProjectDir
try {
    Invoke-StarRailAssistantCli `
        -PythonPath $Python `
        -MainScriptPath $MainScript `
        -Commands @($runCommand, "quit")
}
finally {
    Pop-Location
}
