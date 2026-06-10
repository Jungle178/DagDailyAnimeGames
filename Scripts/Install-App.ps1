param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("maa", "bettergi", "wuthering", "endfield", "nte")]
    [string]$AppId,
    [string]$Root = "",
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

function Require-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Get-GitHubLatestRelease {
    param([string]$Repository)

    $uri = "https://api.github.com/repos/$Repository/releases/latest"
    Write-Host "Fetching release metadata: $uri"
    Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = "DagDailyAnimeGames-Installer" }
}

function Select-ReleaseAsset {
    param(
        [object]$Release,
        [string[]]$Patterns,
        [string]$Description
    )

    foreach ($pattern in $Patterns) {
        $matches = @(
            $Release.assets |
                Where-Object { $_.name -match $pattern } |
                Sort-Object name
        )
        if ($matches.Count -gt 0) {
            Write-Host "Selected $Description asset: $($matches[0].name)"
            return $matches[0]
        }
    }

    $available = @($Release.assets | ForEach-Object { $_.name }) -join ", "
    throw "No $Description asset matched patterns: $($Patterns -join ', '). Available assets: $available"
}

function Save-ReleaseAsset {
    param(
        [object]$Asset,
        [string]$Destination
    )

    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    Write-Host "Downloading $($Asset.name)..."
    Invoke-WebRequest `
        -Uri $Asset.browser_download_url `
        -OutFile $Destination `
        -Headers @{ "User-Agent" = "DagDailyAnimeGames-Installer" }
}

function Expand-ZipAsset {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Expand-TarReadableAsset {
    param(
        [string]$ArchivePath,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination | Out-Null

    $sevenZip = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($sevenZip) {
        & $sevenZip.Source x "-o$Destination" -y $ArchivePath
        if ($LASTEXITCODE -ne 0) {
            throw "7z.exe failed to extract $ArchivePath with code $LASTEXITCODE"
        }
        return
    }

    $tar = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if (-not $tar) {
        throw "Neither 7z.exe nor tar.exe was found. Cannot extract archive: $ArchivePath"
    }

    & $tar.Source -xf $ArchivePath -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed to extract $ArchivePath with code $LASTEXITCODE"
    }
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$PreserveExistingNames = @()
    )

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Destination | Out-Null
    }

    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        $targetPath = Join-Path $Destination $_.Name
        if (($PreserveExistingNames -contains $_.Name) -and (Test-Path -LiteralPath $targetPath)) {
            Write-Host "Preserving existing path: $targetPath"
        }
        else {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
        }
    }
}

function Install-MaaRelease {
    param([string]$Root)

    $installDir = Join-Path $Root "Apps\MAA"
    $downloadDir = Join-Path $Root "Apps\_downloads"
    $maaExtractDir = Join-Path $downloadDir "maa-release"
    $cliExtractDir = Join-Path $downloadDir "maa-cli"

    if (-not (Test-Path -LiteralPath $downloadDir -PathType Container)) {
        New-Item -ItemType Directory -Path $downloadDir | Out-Null
    }

    $maaRelease = Get-GitHubLatestRelease "MaaAssistantArknights/MaaAssistantArknights"
    $maaAsset = Select-ReleaseAsset `
        -Release $maaRelease `
        -Description "MAA Windows x64" `
        -Patterns @("^MAA-.*-win-x64\.zip$", "^MAA-.*windows.*x64.*\.zip$")
    $maaZip = Join-Path $downloadDir $maaAsset.name
    Save-ReleaseAsset -Asset $maaAsset -Destination $maaZip
    Expand-ZipAsset -ZipPath $maaZip -Destination $maaExtractDir

    $maaExe = Get-ChildItem -LiteralPath $maaExtractDir -Recurse -File -Filter "MAA.exe" |
        Select-Object -First 1
    if (-not $maaExe) {
        throw "MAA.exe was not found in downloaded release: $maaZip"
    }

    $maaSourceDir = Split-Path -Parent $maaExe.FullName
    Write-Host "Installing MAA release to: $installDir"
    Copy-DirectoryContents -Source $maaSourceDir -Destination $installDir -PreserveExistingNames @("config")

    $cliRelease = Get-GitHubLatestRelease "MaaAssistantArknights/maa-cli"
    $cliAsset = Select-ReleaseAsset `
        -Release $cliRelease `
        -Description "maa-cli Windows x64" `
        -Patterns @(
            "^maa_cli-.*-x86_64-pc-windows-msvc\.zip$",
            "^maa-cli-.*-x86_64-pc-windows-msvc\.zip$",
            "^maa(?!.*winget).*x86_64-pc-windows-msvc.*\.zip$"
        )
    $cliZip = Join-Path $downloadDir $cliAsset.name
    Save-ReleaseAsset -Asset $cliAsset -Destination $cliZip
    Expand-ZipAsset -ZipPath $cliZip -Destination $cliExtractDir

    $cliExe = Get-ChildItem -LiteralPath $cliExtractDir -Recurse -File |
        Where-Object { $_.Name -in @("maa.exe", "maa-cli.exe") } |
        Select-Object -First 1
    if (-not $cliExe) {
        throw "maa-cli executable was not found in downloaded release: $cliZip"
    }

    $cliTarget = Join-Path $installDir "maa-cli.exe"
    Write-Host "Installing maa-cli to: $cliTarget"
    Copy-Item -LiteralPath $cliExe.FullName -Destination $cliTarget -Force

    Require-File (Join-Path $installDir "MAA.exe")
    Require-File $cliTarget
    Write-Host "MAA release is ready: $installDir"
}

function Install-BetterGiRelease {
    param([string]$Root)

    $installDir = Join-Path $Root "Apps\BetterGI"
    $downloadDir = Join-Path $Root "Apps\_downloads"
    $extractDir = Join-Path $downloadDir "bettergi-release"

    if (-not (Test-Path -LiteralPath $downloadDir -PathType Container)) {
        New-Item -ItemType Directory -Path $downloadDir | Out-Null
    }

    $release = Get-GitHubLatestRelease "babalae/better-genshin-impact"
    $asset = Select-ReleaseAsset `
        -Release $release `
        -Description "BetterGI portable package" `
        -Patterns @("^BetterGI_v.*\.7z$", "^BetterGI.*\.7z$")
    $archivePath = Join-Path $downloadDir $asset.name
    Save-ReleaseAsset -Asset $asset -Destination $archivePath
    Expand-TarReadableAsset -ArchivePath $archivePath -Destination $extractDir

    $betterGiExe = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter "BetterGI.exe" |
        Select-Object -First 1
    if (-not $betterGiExe) {
        throw "BetterGI.exe was not found in downloaded release: $archivePath"
    }

    $sourceDir = Split-Path -Parent $betterGiExe.FullName
    Write-Host "Installing BetterGI release to: $installDir"
    Copy-DirectoryContents -Source $sourceDir -Destination $installDir -PreserveExistingNames @("User")

    Require-File (Join-Path $installDir "BetterGI.exe")
    Write-Host "BetterGI release is ready: $installDir"
}

$Apps = @{
    wuthering = @{ Path = "src\ok-wuthering-waves"; Name = "ok-wuthering-waves" }
    endfield = @{ Path = "src\ok-end-field"; Name = "ok-end-field" }
    nte = @{ Path = "src\ok-nte"; Name = "ok-nte" }
}

if (-not $Root) {
    $Root = Join-Path $PSScriptRoot ".."
}
$Root = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)

if ($AppId -eq "maa") {
    $maaDir = Join-Path $Root "Apps\MAA"
    if ($SkipInstall) {
        Write-Host "Skipping MAA download; validating existing files."
        Require-File (Join-Path $maaDir "MAA.exe")
        Require-File (Join-Path $maaDir "maa-cli.exe")
    }
    else {
        Install-MaaRelease -Root $Root
    }
    Write-Host "MAA is ready."
    exit 0
}

if ($AppId -eq "bettergi") {
    $betterGiDir = Join-Path $Root "Apps\BetterGI"
    if ($SkipInstall) {
        Write-Host "Skipping BetterGI download; validating existing files."
        Require-File (Join-Path $betterGiDir "BetterGI.exe")
    }
    else {
        Install-BetterGiRelease -Root $Root
    }
    Write-Host "BetterGI is ready."
    exit 0
}

$App = $Apps[$AppId]
$ProjectPath = Join-Path $Root $App.Path
$RequirementsPath = Join-Path $ProjectPath "requirements.txt"
$MainPath = Join-Path $ProjectPath "main.py"
$VenvPython = Join-Path $Root ".venv\Scripts\python.exe"
$SetupScript = Join-Path $Root "Scripts\Setup-OkSharedVenv.ps1"

Require-File $SetupScript
if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    Invoke-Checked -FilePath "powershell.exe" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SetupScript) -WorkingDirectory $Root
}

Write-Host "Installing $($App.Name)..."
Invoke-Checked -FilePath "git" -Arguments @("submodule", "update", "--init", "--recursive", "--", $App.Path) -WorkingDirectory $Root

Require-File $RequirementsPath
Require-File $MainPath
Require-File $VenvPython

if (-not $SkipInstall) {
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "install", "-U", "-r", $RequirementsPath) -WorkingDirectory $Root
    Invoke-Checked -FilePath $VenvPython -Arguments @("-m", "pip", "check") -WorkingDirectory $Root
}
else {
    Write-Host "Skipping dependency installation."
}

Write-Host "$($App.Name) is ready."
