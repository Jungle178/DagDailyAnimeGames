param(
    [string]$TaskName = "DagDailyAnimeGames LocalDailyGui",
    [string]$Root = "",
    [int]$DelaySeconds = 30,
    [switch]$RunNow,
    [switch]$Unregister,
    [switch]$Status,
    [switch]$Elevate,
    [switch]$NoElevate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $Root) {
    $Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}
else {
    $Root = (Resolve-Path -LiteralPath $Root).Path
}

$runBat = Join-Path $Root "Run.bat"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentUserName {
    [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Add-ElevatedArgument {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Name,
        [string]$Value
    )

    $Arguments.Add($Name)
    $Arguments.Add("`"$Value`"")
}

function Invoke-ElevatedSelf {
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add("-NoProfile")
    $arguments.Add("-ExecutionPolicy")
    $arguments.Add("Bypass")
    Add-ElevatedArgument -Arguments $arguments -Name "-File" -Value $PSCommandPath
    Add-ElevatedArgument -Arguments $arguments -Name "-TaskName" -Value $TaskName
    Add-ElevatedArgument -Arguments $arguments -Name "-Root" -Value $Root
    $arguments.Add("-DelaySeconds")
    $arguments.Add([string]$DelaySeconds)
    if ($RunNow) {
        $arguments.Add("-RunNow")
    }
    if ($Unregister) {
        $arguments.Add("-Unregister")
    }
    if ($Status) {
        $arguments.Add("-Status")
    }
    $arguments.Add("-NoElevate")

    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList $arguments `
        -Verb RunAs `
        -Wait `
        -PassThru `
        -WindowStyle Hidden
    exit $process.ExitCode
}

function Get-StartupTask {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Show-StartupTaskStatus {
    $task = Get-StartupTask
    if ($null -eq $task) {
        Write-Host "Task is not registered: $TaskName"
        return
    }

    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $action = $task.Actions | Select-Object -First 1
    $trigger = $task.Triggers | Select-Object -First 1

    [PSCustomObject]@{
        TaskName       = $task.TaskName
        State          = $task.State
        UserId         = $task.Principal.UserId
        RunLevel       = $task.Principal.RunLevel
        Trigger        = $trigger.CimClass.CimClassName
        Delay          = $trigger.Delay
        Action         = "$($action.Execute) $($action.Arguments)"
        WorkingDir     = $action.WorkingDirectory
        LastRunTime    = $info.LastRunTime
        LastTaskResult = $info.LastTaskResult
        NextRunTime    = $info.NextRunTime
    } | Format-List
}

if ($Elevate -and $NoElevate) {
    throw "Use only one of -Elevate or -NoElevate."
}

if ((-not $Status) -and $Elevate -and -not (Test-IsAdmin)) {
    Invoke-ElevatedSelf
}

if ($Unregister) {
    $task = Get-StartupTask
    if ($null -eq $task) {
        Write-Host "Task is not registered: $TaskName"
        exit 0
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed startup task: $TaskName"
    exit 0
}

if ($Status) {
    Show-StartupTaskStatus
    exit 0
}

if (-not (Test-Path -LiteralPath $runBat -PathType Leaf)) {
    throw "Run.bat not found: $runBat"
}

$userName = Get-CurrentUserName
$runLevel = if (Test-IsAdmin) { "Highest" } else { "Limited" }
$action = New-ScheduledTaskAction `
    -Execute "cmd.exe" `
    -Argument "/c `"$runBat`"" `
    -WorkingDirectory $Root

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userName
if ($DelaySeconds -gt 0) {
    $trigger.Delay = "PT$($DelaySeconds)S"
}

$principal = New-ScheduledTaskPrincipal `
    -UserId $userName `
    -LogonType Interactive `
    -RunLevel $runLevel

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Write-Host "Registered startup task: $TaskName"
Write-Host "User: $userName"
Write-Host "RunLevel: $runLevel"
Write-Host "Action: cmd.exe /c `"$runBat`""
Write-Host "Delay: $DelaySeconds seconds after logon"

if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Started scheduled task once: $TaskName"
}

Show-StartupTaskStatus
