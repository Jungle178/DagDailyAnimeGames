# AGENTS.md

This repo was split out from `F:\MAA_git`.

- The GUI came from `F:\MAA_git\Scripts\LocalDailyGui.py`.
- The launcher/setup scripts were adapted from `F:\MAA_git\Scripts`.
- The `src/` projects are Git submodules for `ok-end-field`, `ok-nte`, and `ok-wuthering-waves`; do not vendor their contents into the parent repo.
- Keep `.venv/`, `Logs/`, and `Scripts/LocalDailyGui.settings.json` local-only.
- Root `requirements.txt` is only for the GUI. Game dependencies are installed per app by `Scripts/Install-App.ps1`.
- `Update.bat` intentionally forces downloaded submodules to their upstream branch heads; avoid running it as a harmless check.

## MAA/maa-cli 注意事项

- maa-cli 的 `daily.toml` 是生成文件，位置在 `%APPDATA%\loong\maa\config\tasks\daily.toml`；源配置来自 MAA 本体的 `config/gui.json` 当前激活 profile 和 `config/gui.new.json` 的 `TaskQueue`，当前 profile 不存在时回退 `Default`。
- `Scripts/Run-MAA-Daily.ps1` 会在发起 MuMu 启动后后台同步 maa-cli 配置，并在等待 MuMu Android 启动期间并行完成；不要把同步移到 ADB ready 之后。
- 转换 MAA `StartUp` 时必须带 `start_game_enabled = true`，任务末尾保留 `CloseDown`；脚本的 `finally` 仍负责额外 `closedown`、关闭 MuMu 和清理 ADB。
- Windows PowerShell 5.1 下，`adb` 写 stderr 会在 `$ErrorActionPreference = "Stop"` 时变成 `NativeCommandError`；静默 ADB 命令用 `Invoke-QuietNativeCommand`/`ProcessStartInfo`，不要用 `*> $null` 直接跑 ADB。
- 验证 MAA 改动优先跑：`.\Scripts\Install-App.ps1 maa -SkipInstall -MaaDir .\src\MAA`、`.\src\MAA\maa-cli.exe run daily --dry-run --batch --no-summary -v`；完整启动测试用临时 `CloseDown` 任务，测完删除。

## 目录说明

- `Run.bat`：自动准备 GUI 环境并启动 GUI。
- `Update.bat`：更新根仓库和已下载的 submodule。
- `Setting.json`：本机定时配置、已确认的 PC 游戏路径，以及 MAA/BetterGI 本地目录；不提交到 Git。
- `assets/unattended-remote-debugging.md`：无人值守测试期间通过 Codex 远程控制 GUI 的调试命令说明。
- `icons/icon.png`：GUI 窗口图标；`icons/<app>.png` 是各任务行的本地图标，安装项目之前也可显示。
- `Scripts/Setup.bat`：手动创建或更新 GUI 运行环境的隐藏入口。
- `Scripts/LocalDailyGui.py`：Tkinter GUI 调度器。
- `Scripts/Register-StartupTask.ps1`：注册/删除 Windows 登录自启动计划任务，启动入口是根目录 `Run.bat`。
- `Scripts/Install-App.ps1`：按单个项目安装；`ok-*` 下载 submodule 并安装依赖，MAA/BetterGI 下载官方 release 包。
- `Scripts/Verify-AppGame.ps1`：确认并缓存 `ok-wuthering-waves` 的本机游戏进程位置。
- `Scripts/Run-MAA-Daily.ps1`：启动 MAA 日常任务，默认拉起 MuMu 12、连接 ADB 并执行 `maa-cli run daily`。
- `Scripts/Stop-MAA-Daily.ps1`：强制退出 MAA 任务后清理 MuMu/ADB。
- `Scripts/Start-BetterGI-OneDragon.ps1`：启动 BetterGI 一条龙任务，默认执行 `BetterGI.exe startOneDragon`。
- `Scripts/Run-OkEndFieldDaily.ps1`：启动 `ok-end-field` 日常任务。
- `Scripts/Run-OkNteDaily.ps1`：启动 `ok-nte` 日常任务。
- `Scripts/Run-OkWutheringWavesDaily.ps1`：启动 `ok-wuthering-waves` 日常任务；鸣潮路径来自运行中进程或安装确认缓存，不再写死本机盘符。
- `src/`：上游 `ok-*` 项目的 Git submodule，也可手动放入 `src/MAA` 和 `src/BetterGI`。
- `Apps/`：本地下载的 MAA、BetterGI release 和工具目录，不提交到 Git。
