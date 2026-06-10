param(
    [switch]$Check,
    [switch]$NoElevate,
    [string]$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$python = Join-Path $Root ".venv-ok\Scripts\python.exe"
$pythonw = Join-Path $Root ".venv-ok\Scripts\pythonw.exe"
$gui = Join-Path $PSScriptRoot "LocalDailyGui.py"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $NoElevate -and -not (Test-IsAdmin)) {
    $scriptPath = $PSCommandPath
    $elevatedArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$scriptPath`""
    )
    if ($Check) {
        $elevatedArgs += "-Check"
    }

    Start-Process -FilePath "powershell.exe" -ArgumentList $elevatedArgs -Verb RunAs -WindowStyle Hidden
    exit 0
}

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Python executable not found: $python"
}
if (-not (Test-Path -LiteralPath $gui -PathType Leaf)) {
    throw "GUI script not found: $gui"
}

$arguments = @($gui)
if ($Check) {
    $arguments += "--check"
}

if ($Check) {
    & $python @arguments
    exit $LASTEXITCODE
}

$guiPython = if (Test-Path -LiteralPath $pythonw -PathType Leaf) { $pythonw } else { $python }
Start-Process -FilePath $guiPython -ArgumentList @("`"$gui`"") -WorkingDirectory $Root -WindowStyle Hidden
exit 0
