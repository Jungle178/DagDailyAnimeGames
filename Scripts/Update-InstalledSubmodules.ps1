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

function Test-GitWorkTree {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    & git -C $Path rev-parse --is-inside-work-tree *> $null
    return $LASTEXITCODE -eq 0
}

if (-not $Root) {
    $Root = Join-Path $PSScriptRoot ".."
}
$Root = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
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
    Invoke-Checked -FilePath "git" -Arguments @("submodule", "update", "--init", "--recursive") -WorkingDirectory $path
}

Write-Host "Installed submodules are up to date."
