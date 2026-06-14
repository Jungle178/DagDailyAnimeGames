param(
    [string]$Root = "",
    [string]$ProjectDir = "",
    [string]$Python = "",
    [string]$DotNet = "",
    [string[]]$ConfigName = @(),
    [switch]$RunDaily
)

$ErrorActionPreference = "Stop"

function Require-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Read-JsonObject {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [PSCustomObject]@{}
    }

    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [PSCustomObject]@{}
        }
        return $text | ConvertFrom-Json
    }
    catch {
        Write-Warning "Ignoring invalid json file: $Path"
        return [PSCustomObject]@{}
    }
}

function Test-JsonProperty {
    param(
        [AllowNull()][object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    $null -ne $Object.PSObject.Properties[$Name]
}

function Set-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if (Test-JsonProperty -Object $Object -Name $Name) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Get-OrCreateJsonObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if (-not (Test-JsonProperty -Object $Object -Name $Name) -or $null -eq $Object.$Name) {
        Set-JsonProperty $Object $Name ([PSCustomObject]@{})
    }

    $Object.$Name
}

function Save-JsonObject {
    param(
        [string]$Path,
        [object]$Object
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
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
}

function ConvertTo-SraCliToken {
    param([string]$Value)

    if ($Value -notmatch "\s" -and $Value -notmatch '"') {
        return $Value
    }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Resolve-DotNetPath {
    param([string]$DotNetPath)

    if ($DotNetPath) {
        if (Test-Path -LiteralPath $DotNetPath -PathType Leaf) {
            return $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DotNetPath)
        }

        $specifiedCommand = Get-Command $DotNetPath -ErrorAction SilentlyContinue
        if ($specifiedCommand) {
            return $specifiedCommand.Source
        }

        throw "dotnet executable not found: $DotNetPath"
    }

    $command = Get-Command "dotnet.exe" -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command "dotnet" -ErrorAction SilentlyContinue
    }
    if ($command) {
        return $command.Source
    }

    throw "dotnet was not found. Install the .NET 10 SDK, then try StarRailAssistant again."
}

function Update-StarRailFrontendSettings {
    param(
        [string]$PythonPath,
        [string]$MainScriptPath
    )

    if (-not $env:APPDATA) {
        throw "APPDATA is not set; cannot locate StarRailAssistant settings directory."
    }

    $settingsPath = Join-Path (Join-Path $env:APPDATA "SRA") "settings.json"
    $settings = Read-JsonObject -Path $settingsPath
    $advanced = Get-OrCreateJsonObjectProperty -Object $settings -Name "advanced"

    $resolvedPython = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PythonPath)
    $resolvedMainScript = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MainScriptPath)

    Set-JsonProperty $advanced "developerMode.enabled" $true
    Set-JsonProperty $advanced "developerMode.python.enabled" $true
    Set-JsonProperty $advanced "developerMode.python.path" $resolvedPython
    Set-JsonProperty $advanced "developerMode.python.main" $resolvedMainScript
    Set-JsonProperty $advanced "backend.launchArgs" "--no-admin --inline"

    Save-JsonObject -Path $settingsPath -Object $settings
    Write-Host "Updated StarRailAssistant GUI backend settings: $settingsPath"
}

function Invoke-StarRailAssistantGui {
    param(
        [string]$DotNetPath,
        [string]$FrontendProjectPath,
        [string]$WorkingDirectory
    )

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $DotNetPath
    $processInfo.Arguments = "run --project `"$FrontendProjectPath`" --no-launch-profile"
    $processInfo.WorkingDirectory = $WorkingDirectory
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true
    $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    Write-Host "Opening StarRailAssistant GUI..."
    Write-Host "> $DotNetPath $($processInfo.Arguments)"

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
        throw "StarRailAssistant GUI exited with code $exitCode"
    }
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

$ProjectDir = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectDir)
$Python = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Python)

if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
    throw "Project directory not found: $ProjectDir"
}

Require-File $Python

$MainScript = Join-Path $ProjectDir "main.py"
Require-File $MainScript

$FrontendProject = Join-Path $ProjectDir "SRAFrontend\SRAFrontend.Desktop\SRAFrontend.Desktop.csproj"

Push-Location -LiteralPath $ProjectDir
try {
    if ($RunDaily) {
        $runCommand = "run"
        if ($ConfigName.Count -gt 0) {
            $runCommand += " " + (($ConfigName | ForEach-Object { ConvertTo-SraCliToken $_ }) -join " ")
        }

        Invoke-StarRailAssistantCli `
            -PythonPath $Python `
            -MainScriptPath $MainScript `
            -Commands @($runCommand, "quit")
    }
    else {
        Require-File $FrontendProject
        $DotNetPath = Resolve-DotNetPath -DotNetPath $DotNet
        Update-StarRailFrontendSettings -PythonPath $Python -MainScriptPath $MainScript
        Invoke-StarRailAssistantGui `
            -DotNetPath $DotNetPath `
            -FrontendProjectPath $FrontendProject `
            -WorkingDirectory $ProjectDir
    }
}
finally {
    Pop-Location
}
