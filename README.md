# DagDailyAnimeGames

本项目是一个本地日常任务 GUI 调度器，用于统一启动以下自动化项目：

- `MAA-明日方舟`
- `BetterGI-原神`
- `ok-end-field`
- `ok-nte`
- `ok-wuthering-waves`

三个 `ok-*` 上游项目以 Git submodule 的方式放在 `src/` 下。MAA 和 BetterGI 不拉取源码，安装时下载官方 release 包到本地 `Apps/`。本仓库维护本地 GUI、启动脚本和安装/更新脚本。

## 启动

需要 Windows、Git 和 Python 3.12。推荐直接运行根目录入口：

```powershell
.\Run.bat
```

`Run.bat` 会检测 `.venv` 是否存在且能加载 GUI 依赖；缺失时会自动运行 `Setup.bat` 创建环境，然后启动 GUI。

## 安装项目

首次打开 GUI 时，如果某个项目还没有准备好，该行只会显示一个大的“安装”按钮。

`ok-*` 项目点击后会：

1. 下载对应的 Git submodule。
2. 使用根目录 `.venv` 安装该项目自己的 `requirements.txt`。
3. 提示你打开对应 PC 游戏窗口，并检测游戏进程位置。
4. 检测成功后切回“启动 / 强制退出 / 定时”按钮。

MAA 点击后会：

1. 从 `MaaAssistantArknights/MaaAssistantArknights` 下载 Windows x64 官方 release 包。
2. 从 `MaaAssistantArknights/maa-cli` 下载 Windows x64 `maa-cli`。
3. 解压到 `Apps/MAA`，并把 CLI 保存为 `Apps/MAA/maa-cli.exe`。
4. 安装完成后直接切回“启动 / 强制退出 / 定时”按钮。

BetterGI 点击后会：

1. 从 `babalae/better-genshin-impact` 下载 Windows 便携 release 包。
2. 解压到 `Apps/BetterGI`。
3. 安装完成后直接切回“启动 / 强制退出 / 定时”按钮。

`ok-*` 的检测结果会写入各子项目自己的 `configs/` 目录，用于后续启动时定位游戏。未确认游戏位置的 `ok-*` 项目不会正式运行，也不会执行定时任务。MAA 运行时默认调用 MuMu 12 和 `maa-cli run daily`，任务配置仍使用 `maa-cli` 自己的配置目录。BetterGI 运行时默认执行 `BetterGI.exe startOneDragon`。

根目录 `requirements.txt` 只包含 GUI 自身运行所需依赖。各游戏项目依赖在点击对应“安装”按钮时单独安装。

## 手动准备 GUI 环境

```powershell
.\Setup.bat
```

等价 PowerShell 命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Setup-OkSharedVenv.ps1
```

## 更新已下载项目

```powershell
.\Update.bat
```

该脚本只更新当前已经下载的 submodule，跳过未安装项目。更新时会直接把每个 submodule 重置到它自己的远端分支最新版：

- `src/ok-end-field` -> `origin/master`
- `src/ok-nte` -> `origin/main`
- `src/ok-wuthering-waves` -> `origin/master`

## 目录说明

- `Run.bat`：自动准备 GUI 环境并启动 GUI。
- `Setup.bat`：创建或更新 GUI 运行环境。
- `Update.bat`：更新已下载的 submodule。
- `Scripts/LocalDailyGui.py`：Tkinter GUI 调度器。
- `Scripts/Install-App.ps1`：按单个项目安装；`ok-*` 下载 submodule 并安装依赖，MAA/BetterGI 下载官方 release 包。
- `Scripts/Verify-AppGame.ps1`：安装后确认本机游戏进程位置。
- `Scripts/Run-MAA-Daily.ps1`：启动 MAA 日常任务，默认拉起 MuMu 12、连接 ADB 并执行 `maa-cli run daily`。
- `Scripts/Stop-MAA-Daily.ps1`：强制退出 MAA 任务后清理 MuMu/ADB。
- `Scripts/Start-BetterGI-OneDragon.ps1`：启动 BetterGI 一条龙任务，默认执行 `BetterGI.exe startOneDragon`。
- `Scripts/Run-OkEndFieldDaily.ps1`：启动 `ok-end-field` 日常任务。
- `Scripts/Run-OkNteDaily.ps1`：启动 `ok-nte` 日常任务。
- `Scripts/Run-OkWutheringWavesDaily.ps1`：启动 `ok-wuthering-waves` 日常任务；鸣潮路径来自运行中进程或安装确认缓存，不再写死本机盘符。
- `src/`：上游 `ok-*` 项目的 Git submodule。
- `Apps/`：本地下载的 MAA、BetterGI release 和工具目录，不提交到 Git。

## 本地文件

以下内容不会提交到 Git：

- `.venv/` 和其他虚拟环境。
- `Apps/` 中下载的 MAA、BetterGI release 包和工具。
- `Logs/` 中的运行日志。
- `Scripts/LocalDailyGui.settings.json` 中的本地定时配置。

## 许可证

本仓库默认使用 MIT License。`src/` 下各 submodule 保留其上游项目自己的许可证。
