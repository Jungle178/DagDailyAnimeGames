# DagDailyAnimeGames

本项目是一个本地日常任务 GUI 调度器，用于统一启动以下 `ok-*` 自动化项目：

- `ok-end-field`
- `ok-nte`
- `ok-wuthering-waves`

三个上游项目以 Git submodule 的方式放在 `src/` 下。本仓库维护本地 GUI、启动脚本和安装/更新脚本。

## 启动

需要 Windows、Git 和 Python 3.12。推荐直接运行根目录入口：

```powershell
.\Run.bat
```

`Run.bat` 会检测 `.venv` 是否存在且能加载 GUI 依赖；缺失时会自动运行 `Setup.bat` 创建环境，然后启动 GUI。

## 安装游戏项目

首次打开 GUI 时，如果某个游戏的 submodule 还没有下载，该行只会显示一个大的“安装”按钮。点击后会：

1. 下载对应的 Git submodule。
2. 使用根目录 `.venv` 安装该项目自己的 `requirements.txt`。
3. 安装完成后自动切回“启动 / 强制退出 / 定时”按钮。

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
- `Scripts/Install-App.ps1`：按单个游戏下载 submodule 并安装依赖。
- `Scripts/Run-OkEndFieldDaily.ps1`：启动 `ok-end-field` 日常任务。
- `Scripts/Run-OkNteDaily.ps1`：启动 `ok-nte` 日常任务。
- `Scripts/Run-OkWutheringWavesDaily.ps1`：启动 `ok-wuthering-waves` 日常任务。
- `src/`：上游 `ok-*` 项目的 Git submodule。

## 本地文件

以下内容不会提交到 Git：

- `.venv/` 和其他虚拟环境。
- `Logs/` 中的运行日志。
- `Scripts/LocalDailyGui.settings.json` 中的本地定时配置。

## 许可证

本仓库默认使用 MIT License。`src/` 下各 submodule 保留其上游项目自己的许可证。
