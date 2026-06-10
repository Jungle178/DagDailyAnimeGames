# DagDailyAnimeGames

本项目是一个本地日常任务 GUI 调度器，用于统一启动以下 `ok-*` 自动化项目：

- `ok-end-field`
- `ok-nte`
- `ok-wuthering-waves`

三个上游项目以 Git submodule 的方式放在 `src/` 下。本仓库只维护本地 GUI、启动脚本和共享环境初始化脚本。

## 初始化

```powershell
git clone --recursive <your-repo-url>
cd DagDailyAnimeGames

# 如果 clone 时没有带 --recursive：
git submodule update --init --recursive
```

## 准备 Python 环境

需要 Windows 和 Python 3.12。首次运行前执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Setup-OkSharedVenv.ps1
```

该脚本会在仓库根目录创建 `.venv-ok`，安装 `ok-nte` 的依赖以及几个三项目共用的补充依赖。

## 启动 GUI

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Start-LocalDailyGui.ps1
```

也可以双击：

```text
Scripts\Start-LocalDailyGui.cmd
```

检查配置：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Start-LocalDailyGui.ps1 -Check -NoElevate
```

## 目录说明

- `Scripts/LocalDailyGui.py`：Tkinter GUI 调度器。
- `Scripts/Run-OkEndFieldDaily.ps1`：启动 `ok-end-field` 日常任务。
- `Scripts/Run-OkNteDaily.ps1`：启动 `ok-nte` 日常任务。
- `Scripts/Run-OkWutheringWavesDaily.ps1`：启动 `ok-wuthering-waves` 日常任务。
- `Scripts/Setup-OkSharedVenv.ps1`：创建并验证共享 Python 环境。
- `src/`：上游 `ok-*` 项目的 Git submodule。

## 本地文件

以下内容不会提交到 Git：

- `.venv-ok/` 和其他虚拟环境。
- `Logs/` 中的运行日志。
- `Scripts/LocalDailyGui.settings.json` 中的本地定时配置。

## 许可证

本仓库默认使用 MIT License。`src/` 下各 submodule 保留其上游项目自己的许可证。
