param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("maa", "maa-gui", "bettergi", "wuthering", "endfield", "nte")]
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

function Set-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
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

function Get-OrCreateJsonObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if (-not ($Object.PSObject.Properties.Name -contains $Name) -or $null -eq $Object.$Name) {
        Set-JsonProperty $Object $Name ([PSCustomObject]@{})
    }

    $Object.$Name
}

function Update-InstallDirSetting {
    param(
        [string]$Root,
        [string]$AppId,
        [string]$InstallDir
    )

    $settingsPath = Join-Path $Root "Setting.json"
    $defaultTimes = @{
        maa = @("00:00", "19:00")
        bettergi = @("04:30")
    }
    $settings = Read-JsonObject $settingsPath
    Set-JsonProperty $settings "settings_version" 6

    $apps = Get-OrCreateJsonObjectProperty -Object $settings -Name "apps"
    if (-not ($apps.PSObject.Properties.Name -contains $AppId) -or $null -eq $apps.$AppId) {
        Set-JsonProperty $apps $AppId ([PSCustomObject]@{})
    }

    $appSettings = $apps.$AppId
    $resolvedInstallDir = $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)
    Set-JsonProperty $appSettings "install_dir" $resolvedInstallDir
    Set-JsonProperty $appSettings "game_verified" $true
    if (-not ($appSettings.PSObject.Properties.Name -contains "enabled")) {
        Set-JsonProperty $appSettings "enabled" $false
    }
    if (-not ($appSettings.PSObject.Properties.Name -contains "times")) {
        Set-JsonProperty $appSettings "times" $defaultTimes[$AppId]
    }

    if (-not ($settings.PSObject.Properties.Name -contains "last_runs")) {
        Set-JsonProperty $settings "last_runs" ([PSCustomObject]@{})
    }
    if (-not ($settings.PSObject.Properties.Name -contains "log_archives")) {
        Set-JsonProperty $settings "log_archives" ([PSCustomObject]@{})
    }

    Save-JsonObject $settingsPath $settings
    Write-Host "Updated root settings: $settingsPath"
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

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return "{0:N1} GB" -f ($Bytes / 1GB)
    }
    if ($Bytes -ge 1MB) {
        return "{0:N1} MB" -f ($Bytes / 1MB)
    }
    if ($Bytes -ge 1KB) {
        return "{0:N1} KB" -f ($Bytes / 1KB)
    }
    return "$Bytes B"
}

function Save-UrlWithProgress {
    param(
        [string]$Uri,
        [string]$Destination,
        [string]$Description
    )

    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    Write-Host "Downloading $Description..."

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent = "DagDailyAnimeGames-Installer"
    $request.AllowAutoRedirect = $true
    $request.Timeout = 300000
    $request.ReadWriteTimeout = 300000

    $response = $null
    $responseStream = $null
    $fileStream = $null
    try {
        $response = $request.GetResponse()
        $totalBytes = [long]$response.ContentLength
        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $buffer = New-Object byte[] 1048576
        $downloadedBytes = [long]0
        $lastPercent = 0
        $lastReport = Get-Date

        if ($totalBytes -gt 0) {
            Write-Host "Download progress: 0% (0 B / $(Format-FileSize $totalBytes))"
        }

        while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $downloadedBytes += $read

            if ($totalBytes -gt 0) {
                $percent = [int][Math]::Floor(($downloadedBytes * 100.0) / $totalBytes)
                $percent = [Math]::Min($percent, 100)
                if ($percent -ge ($lastPercent + 5) -or $percent -eq 100) {
                    Write-Host "Download progress: $percent% ($(Format-FileSize $downloadedBytes) / $(Format-FileSize $totalBytes))"
                    $lastPercent = $percent
                    $lastReport = Get-Date
                }
            }
            elseif (((Get-Date) - $lastReport).TotalSeconds -ge 2) {
                Write-Host "Download progress: $(Format-FileSize $downloadedBytes)"
                $lastReport = Get-Date
            }
        }

        if ($totalBytes -le 0) {
            Write-Host "Download progress: $(Format-FileSize $downloadedBytes)"
        }
        Write-Host "Download completed: $Description ($(Format-FileSize $downloadedBytes))"
    }
    finally {
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
        if ($null -ne $responseStream) {
            $responseStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }

    Require-File $Destination
}

function Save-ReleaseAsset {
    param(
        [object]$Asset,
        [string]$Destination
    )

    Save-UrlWithProgress `
        -Uri $Asset.browser_download_url `
        -Destination $Destination `
        -Description $Asset.name
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

function Get-SevenZipExtractor {
    param([string]$Root)

    $sevenZip = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($sevenZip) {
        return $sevenZip.Source
    }

    $toolDir = Join-Path $Root "Apps\_tools"
    $sevenZipReduced = Join-Path $toolDir "7zr.exe"
    if (Test-Path -LiteralPath $sevenZipReduced -PathType Leaf) {
        return $sevenZipReduced
    }

    if (-not (Test-Path -LiteralPath $toolDir -PathType Container)) {
        New-Item -ItemType Directory -Path $toolDir | Out-Null
    }

    $uri = "https://www.7-zip.org/a/7zr.exe"
    Save-UrlWithProgress `
        -Uri $uri `
        -Destination $sevenZipReduced `
        -Description "local 7-Zip extractor"

    Require-File $sevenZipReduced
    return $sevenZipReduced
}

function Expand-SevenZipAsset {
    param(
        [string]$ArchivePath,
        [string]$Destination,
        [string]$Root
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination | Out-Null

    $extractor = Get-SevenZipExtractor -Root $Root
    & $extractor x "-o$Destination" -y $ArchivePath
    if ($LASTEXITCODE -ne 0) {
        throw "$extractor failed to extract $ArchivePath with code $LASTEXITCODE"
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

function Resolve-FirstDirectoryWithFile {
    param(
        [string]$Root,
        [string[]]$RelativeDirectories,
        [string]$FileName
    )

    foreach ($relativeDirectory in $RelativeDirectories) {
        $candidate = Join-Path $Root $relativeDirectory
        if (Test-Path -LiteralPath (Join-Path $candidate $FileName) -PathType Leaf) {
            return $candidate
        }
    }

    return ""
}

function Get-MaaCandidateDirectories {
    @(
        "src\MAA",
        "src\MaaAssistantArknights",
        "Apps\MAA"
    )
}

function Get-BetterGiCandidateDirectories {
    @(
        "src\BetterGI",
        "src\better-genshin-impact",
        "Apps\BetterGI"
    )
}

function Convert-MaaGuiToCliConfig {
    param([string]$MaaDir)

    $cliConfigDir = Join-Path $env:APPDATA "loong\maa\config"
    $cliTasksDir = Join-Path $cliConfigDir "tasks"
    $dailyTomlPath = Join-Path $cliTasksDir "daily.toml"

    $writeDefaultDailyToml = {
        if (-not (Test-Path -LiteralPath $cliTasksDir -PathType Container)) {
            New-Item -ItemType Directory -Path $cliTasksDir -Force | Out-Null
        }

        $content = @(
            '"$schema" = "../schemas/task.schema.json"',
            'client_type = "Official"',
            "",
            "[[tasks]]",
            'name = "开始唤醒"',
            'type = "StartUp"',
            "",
            "[[tasks]]",
            'name = "理智作战"',
            'type = "Fight"',
            "",
            "[[tasks]]",
            'name = "基建换班"',
            'type = "Infrast"',
            "",
            "[[tasks]]",
            'name = "自动公招"',
            'type = "Recruit"',
            "",
            "[[tasks]]",
            'name = "信用收支"',
            'type = "Mall"',
            "",
            "[[tasks]]",
            'name = "领取奖励"',
            'type = "Award"',
            ""
        ) -join [Environment]::NewLine

        [System.IO.File]::WriteAllText(
            $dailyTomlPath,
            $content + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "Generated default CLI config: $dailyTomlPath"
    }

    $guiJsonPath = Join-Path $MaaDir "config\gui.json"
    $guiNewPath = Join-Path $MaaDir "config\gui.new.json"

    if (-not (Test-Path -LiteralPath $guiJsonPath -PathType Leaf)) {
        Write-Host "GUI config not found; generating default CLI config."
        & $writeDefaultDailyToml
        return
    }

    $guiConfig = Read-JsonObject $guiJsonPath
    $currentProfile = $guiConfig.Current
    if (-not $currentProfile) {
        Write-Host "No current profile in gui.json; generating default CLI config."
        & $writeDefaultDailyToml
        return
    }

    if (-not (Test-Path -LiteralPath $guiNewPath -PathType Leaf)) {
        Write-Host "gui.new.json not found; generating default CLI config."
        & $writeDefaultDailyToml
        return
    }

    $guiNew = Read-JsonObject $guiNewPath
    $taskQueue = @()
    if ($guiNew.PSObject.Properties.Name -contains "Configurations") {
        $configs = $guiNew.Configurations
        if ($configs -and $configs.PSObject.Properties.Name -contains $currentProfile) {
            $profile = $configs.$currentProfile
            if ($profile.PSObject.Properties.Name -contains "TaskQueue") {
                $taskQueue = @($profile.TaskQueue)
            }
        }
    }

    if ($taskQueue.Count -eq 0) {
        Write-Host "No tasks found in GUI profile '$currentProfile'; generating default CLI config."
        & $writeDefaultDailyToml
        return
    }

    $typeMap = @{
        StartUp = "StartUp"
        Fight   = "Fight"
        Infrast = "Infrast"
        Recruit = "Recruit"
        Mall    = "Mall"
        Award   = "Award"
    }

    $lines = @(
        '"$schema" = "../schemas/task.schema.json"',
        'client_type = "Official"',
        ""
    )

    foreach ($task in $taskQueue) {
        if (-not $task.IsEnable) { continue }

        $cliType = $typeMap[$task.TaskType]
        if (-not $cliType) {
            Write-Host "Skipping unknown task type: $($task.TaskType)"
            continue
        }

        $name = $task.Name
        $lines += "[[tasks]]"
        $lines += "name = `"$name`""
        $lines += "type = `"$cliType`""

        switch ($task.TaskType) {
            "Fight" {
                if ($task.StagePlan -and $task.StagePlan.Count -gt 0) {
                    $lines += "stage = `"$($task.StagePlan[0])`""
                }
                if ($task.MedicineCount) { $lines += "medicine = $($task.MedicineCount)" }
                if ($task.StoneCount) { $lines += "stone = $($task.StoneCount)" }
                if ($task.TimesLimit) { $lines += "times = $($task.TimesLimit)" }
            }
            "Infrast" {
                if ($task.Mode) { $lines += "mode = $($task.Mode)" }
                if ($task.DormThreshold) {
                    $threshold = [double]$task.DormThreshold / 100.0
                    $lines += "threshold = $threshold"
                }
            }
            "Recruit" {
                if ($task.MaxTimes) { $lines += "times = $($task.MaxTimes)" }
                if ($task.PreserveTagList) {
                    $lines += "preserve_tags = `"$($task.PreserveTagList)`""
                }
            }
            "Mall" {
                if ($task.FirstList -and $task.FirstList -ne "") {
                    $items = @(($task.FirstList -split ";").Trim() | Where-Object { $_ } | ForEach-Object { "`"$_`"" })
                    if ($items.Count -gt 0) {
                        $lines += "buy_first = [$($items -join ", ")]"
                    }
                }
                if ($task.BlackList -and $task.BlackList -ne "") {
                    $items = @(($task.BlackList -split ";").Trim() | Where-Object { $_ } | ForEach-Object { "`"$_`"" })
                    if ($items.Count -gt 0) {
                        $lines += "blacklist = [$($items -join ", ")]"
                    }
                }
            }
            "Award" {
                if ($null -ne $task.FreeGacha) {
                    $lines += "recruit = $($task.FreeGacha.ToString().ToLower())"
                }
            }
        }

        $lines += ""
        Write-Host "  Converted: $name -> $cliType"
    }

    if (-not (Test-Path -LiteralPath $cliTasksDir -PathType Container)) {
        New-Item -ItemType Directory -Path $cliTasksDir -Force | Out-Null
    }

    $content = ($lines -join [Environment]::NewLine)
    [System.IO.File]::WriteAllText(
        $dailyTomlPath,
        $content + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "Converted GUI config to CLI: $dailyTomlPath"
    Write-Host "  Profile: $currentProfile, Tasks converted: $($taskQueue.Where{ $_.IsEnable }.Count)"
}

function Install-MaaCli {
    param(
        [string]$Root,
        [string]$MaaDir
    )

    $downloadDir = Join-Path $Root "Apps\_downloads"
    $cliExtractDir = Join-Path $downloadDir "maa-cli"

    if (-not (Test-Path -LiteralPath $downloadDir -PathType Container)) {
        New-Item -ItemType Directory -Path $downloadDir | Out-Null
    }

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

    $cliTarget = Join-Path $MaaDir "maa-cli.exe"
    Write-Host "Installing maa-cli to: $cliTarget"
    Copy-Item -LiteralPath $cliExe.FullName -Destination $cliTarget -Force
    Require-File $cliTarget

    Write-Host "Cleaning up download artifacts: $downloadDir"
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Install-MaaRelease {
    param([string]$Root)

    $existingMaaDir = Resolve-FirstDirectoryWithFile `
        -Root $Root `
        -RelativeDirectories (Get-MaaCandidateDirectories) `
        -FileName "MAA.exe"
    if ($existingMaaDir) {
        Write-Host "Detected existing MAA release: $existingMaaDir"
        if (-not (Test-Path -LiteralPath (Join-Path $existingMaaDir "maa-cli.exe") -PathType Leaf)) {
            Write-Host "maa-cli is missing; installing CLI into existing MAA directory."
            Install-MaaCli -Root $Root -MaaDir $existingMaaDir
        }
        Write-Host "Syncing CLI config from GUI settings..."
        Convert-MaaGuiToCliConfig -MaaDir $existingMaaDir
        Require-File (Join-Path $existingMaaDir "MAA.exe")
        Require-File (Join-Path $existingMaaDir "maa-cli.exe")
        Write-Host "MAA release is ready: $existingMaaDir"
        Update-InstallDirSetting -Root $Root -AppId "maa" -InstallDir $existingMaaDir
        Update-InstallDirSetting -Root $Root -AppId "maa-gui" -InstallDir $existingMaaDir
        return
    }

    $installDir = Join-Path $Root "Apps\MAA"
    $downloadDir = Join-Path $Root "Apps\_downloads"
    $maaExtractDir = Join-Path $downloadDir "maa-release"

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

    Write-Host "Installing maa-cli and syncing CLI config..."
    Install-MaaCli -Root $Root -MaaDir $installDir
    Convert-MaaGuiToCliConfig -MaaDir $installDir

    Require-File (Join-Path $installDir "MAA.exe")
    Require-File (Join-Path $installDir "maa-cli.exe")
    Write-Host "MAA release is ready: $installDir"
    Update-InstallDirSetting -Root $Root -AppId "maa" -InstallDir $installDir
    Update-InstallDirSetting -Root $Root -AppId "maa-gui" -InstallDir $installDir

    Write-Host "Cleaning up download artifacts: $downloadDir"
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Install-BetterGiRelease {
    param([string]$Root)

    $existingBetterGiDir = Resolve-FirstDirectoryWithFile `
        -Root $Root `
        -RelativeDirectories (Get-BetterGiCandidateDirectories) `
        -FileName "BetterGI.exe"
    if ($existingBetterGiDir) {
        Require-File (Join-Path $existingBetterGiDir "BetterGI.exe")
        Write-Host "Detected existing BetterGI release: $existingBetterGiDir"
        Write-Host "BetterGI release is ready: $existingBetterGiDir"
        Update-InstallDirSetting -Root $Root -AppId "bettergi" -InstallDir $existingBetterGiDir
        return
    }

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
    Expand-SevenZipAsset -ArchivePath $archivePath -Destination $extractDir -Root $Root

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
    Update-InstallDirSetting -Root $Root -AppId "bettergi" -InstallDir $installDir

    Write-Host "Cleaning up download artifacts: $downloadDir"
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
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
Use-GitRuntimePath

function Require-Git {
    $gitCmd = Get-Command "git.exe" -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        throw "Git was not found. Please install Git for Windows (https://git-scm.com/download/win) and try again."
    }
    Write-Host "Found git: $($gitCmd.Source)"
}

if ($AppId -eq "maa") {
    $maaDir = Resolve-FirstDirectoryWithFile `
        -Root $Root `
        -RelativeDirectories (Get-MaaCandidateDirectories) `
        -FileName "MAA.exe"
    if (-not $maaDir) {
        $maaDir = Join-Path $Root "Apps\MAA"
    }
    if ($SkipInstall) {
        Write-Host "Skipping MAA download; validating existing files."
        Require-File (Join-Path $maaDir "MAA.exe")
        Require-File (Join-Path $maaDir "maa-cli.exe")
        Update-InstallDirSetting -Root $Root -AppId "maa" -InstallDir $maaDir
        Update-InstallDirSetting -Root $Root -AppId "maa-gui" -InstallDir $maaDir
    }
    else {
        Install-MaaRelease -Root $Root
    }
    Write-Host "MAA is ready."
    exit 0
}

if ($AppId -eq "maa-gui") {
    $maaDir = Resolve-FirstDirectoryWithFile `
        -Root $Root `
        -RelativeDirectories (Get-MaaCandidateDirectories) `
        -FileName "MAA.exe"
    if (-not $maaDir) {
        $maaDir = Join-Path $Root "Apps\MAA"
    }
    if ($SkipInstall) {
        Write-Host "Skipping MAA download; validating existing files."
        Require-File (Join-Path $maaDir "MAA.exe")
        Update-InstallDirSetting -Root $Root -AppId "maa-gui" -InstallDir $maaDir
    }
    else {
        Install-MaaRelease -Root $Root
    }
    Write-Host "MAA GUI is ready."
    exit 0
}

if ($AppId -eq "bettergi") {
    $betterGiDir = Resolve-FirstDirectoryWithFile `
        -Root $Root `
        -RelativeDirectories (Get-BetterGiCandidateDirectories) `
        -FileName "BetterGI.exe"
    if (-not $betterGiDir) {
        $betterGiDir = Join-Path $Root "Apps\BetterGI"
    }
    if ($SkipInstall) {
        Write-Host "Skipping BetterGI download; validating existing files."
        Require-File (Join-Path $betterGiDir "BetterGI.exe")
        Update-InstallDirSetting -Root $Root -AppId "bettergi" -InstallDir $betterGiDir
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
Require-Git
Invoke-Checked -FilePath "git" -Arguments @("-c", "core.longpaths=true", "submodule", "update", "--init", "--recursive", "--", $App.Path) -WorkingDirectory $Root

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

# Preset ok-framework configs for submodule apps
$PresetApps = @("wuthering", "endfield", "nte")
if ($PresetApps -contains $AppId) {
    $ConfigsDir = Join-Path $ProjectPath "configs"

    # ui_config.json: set light theme
    $UiConfigPath = Join-Path $ConfigsDir "ui_config.json"
    $uiConfig = Read-JsonObject $UiConfigPath
    $qfw = if ($uiConfig.PSObject.Properties.Name -contains "QFluentWidgets") {
        $uiConfig.QFluentWidgets
    } else {
        [PSCustomObject]@{}
    }
    if ($qfw.PSObject.Properties.Name -contains "ThemeMode") {
        $qfw.ThemeMode = "Light"
    } else {
        Add-Member -InputObject $qfw -MemberType NoteProperty -Name "ThemeMode" -Value "Light"
    }
    Set-JsonProperty $uiConfig "QFluentWidgets" $qfw
    Save-JsonObject $UiConfigPath $uiConfig
    Write-Host "  Preset: QFluentWidgets.ThemeMode = Light"

    # DailyTask.json: set exit after task (merge, don't overwrite other fields)
    $DailyConfigPath = Join-Path $ConfigsDir "DailyTask.json"
    $dailyConfig = Read-JsonObject $DailyConfigPath
    Set-JsonProperty $dailyConfig "Exit After Task" $true
    Save-JsonObject $DailyConfigPath $dailyConfig
    Write-Host "  Preset: Exit After Task = true"
}

Write-Host "$($App.Name) is ready."
