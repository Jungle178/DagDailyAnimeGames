param(
    [string]$Root = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        Write-Host "> $FilePath $($Arguments -join ' ')"
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "$FilePath $($Arguments -join ' ') exited with code $exitCode"
        }
    }
    finally {
        Pop-Location
    }
}

function Add-PathEntry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $entries = @($env:PATH -split [IO.Path]::PathSeparator)
    if ($entries -notcontains $Path) {
        $env:PATH = $Path + [IO.Path]::PathSeparator + $env:PATH
    }
}

function Use-GitRuntimePath {
    $gitCommand = Get-Command "git.exe" -ErrorAction SilentlyContinue
    if (-not $gitCommand) {
        return
    }

    $gitCmdDir = Split-Path -Parent $gitCommand.Source
    $gitRoot = Split-Path -Parent $gitCmdDir
    Add-PathEntry (Join-Path $gitRoot "usr\bin")
    Add-PathEntry (Join-Path $gitRoot "mingw64\bin")

    try {
        $execPath = (& $gitCommand.Source --exec-path | Select-Object -First 1)
        if ($execPath) {
            Add-PathEntry $execPath
        }
    }
    catch {
        Write-Warning "Failed to resolve git exec path: $_"
    }
}

function Test-GitWorkTree {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    & git -C $Path rev-parse --is-inside-work-tree *> $null
    return $LASTEXITCODE -eq 0
}

function Update-RootRepository {
    param([string]$Path)

    if (-not (Test-GitWorkTree -Path $Path)) {
        Write-Host "Skipping root repository update: not a git work tree."
        return
    }

    $branch = (& git -C $Path rev-parse --abbrev-ref HEAD | Select-Object -First 1)
    if ($branch -eq "HEAD") {
        Write-Host "Skipping root repository update: detached HEAD."
        return
    }

    Write-Host "Updating root repository..."
    Invoke-Checked -FilePath "git" -Arguments @("fetch", "origin") -WorkingDirectory $Path

    $upstream = ""
    try {
        $upstream = (& git -C $Path rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null | Select-Object -First 1)
    }
    catch {
        $upstream = ""
    }

    if ($upstream) {
        Invoke-Checked -FilePath "git" -Arguments @("pull", "--ff-only") -WorkingDirectory $Path
    }
    else {
        Invoke-Checked -FilePath "git" -Arguments @("pull", "--ff-only", "origin", $branch) -WorkingDirectory $Path
    }
}

if (-not $Root) {
    $Root = Join-Path $PSScriptRoot ".."
}
$Root = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
Use-GitRuntimePath

$gitCmd = Get-Command "git.exe" -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    throw "Git was not found. Please install Git for Windows (https://git-scm.com/download/win) and try again."
}
Write-Host "Found git: $($gitCmd.Source)"

Update-RootRepository -Path $Root
$Submodules = @(
    @{ Path = "src\ok-end-field"; Branch = "master"; Name = "ok-end-field" },
    @{ Path = "src\ok-nte"; Branch = "main"; Name = "ok-nte" },
    @{ Path = "src\ok-wuthering-waves"; Branch = "master"; Name = "ok-wuthering-waves" }
)

foreach ($submodule in $Submodules) {
    $path = Join-Path $Root $submodule.Path
    if (-not (Test-GitWorkTree -Path $path)) {
        Write-Host "Skipping $($submodule.Name): not downloaded."
        continue
    }

    Write-Host "Updating $($submodule.Name) to origin/$($submodule.Branch)..."
    Invoke-Checked -FilePath "git" -Arguments @("fetch", "origin", $submodule.Branch) -WorkingDirectory $path
    Invoke-Checked -FilePath "git" -Arguments @("checkout", "-f", "-B", $submodule.Branch, "origin/$($submodule.Branch)") -WorkingDirectory $path
    Invoke-Checked -FilePath "git" -Arguments @("reset", "--hard", "origin/$($submodule.Branch)") -WorkingDirectory $path
    Invoke-Checked -FilePath "git" -Arguments @("-c", "core.longpaths=true", "submodule", "update", "--init", "--recursive") -WorkingDirectory $path
}

Write-Host "Root repository and installed submodules are up to date."
