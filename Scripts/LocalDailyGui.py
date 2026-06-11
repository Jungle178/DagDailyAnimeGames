from __future__ import annotations

import argparse
import json
import os
import queue
import re
import subprocess
import threading
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from tkinter import (
    BooleanVar,
    END,
    LEFT,
    RIGHT,
    BOTH,
    X,
    Y,
    Canvas,
    Checkbutton,
    Entry,
    Frame,
    Label,
    Listbox,
    Menu,
    Message,
    Scrollbar,
    StringVar,
    Text,
    Tk,
    Toplevel,
    messagebox,
)
from tkinter import ttk

from PIL import Image, ImageDraw, ImageFont, ImageTk


ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "src"
SCRIPTS = ROOT / "Scripts"
LOG_DIR = ROOT / "Logs" / "LocalDailyGui"
LOG_ARCHIVE_DIR = ROOT / "Logs"
SETTINGS_PATH = ROOT / "Setting.json"
LEGACY_SETTINGS_PATH = SCRIPTS / "LocalDailyGui.settings.json"
POWERSHELL = "powershell.exe"
CATCH_UP_MINUTES = 30
SETTINGS_VERSION = 6
LEGACY_DEFAULT_TIMES = {
    "maa": ["00:00", "19:00"],
    "bettergi": ["04:30"],
    "wuthering": ["00:00"],
    "endfield": ["07:00"],
    "nte": ["07:00"],
}
CREATE_NEW_PROCESS_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
TASK_PROCESS_FLAGS = CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW if os.name == "nt" else 0
HIDDEN_PROCESS_FLAGS = CREATE_NO_WINDOW if os.name == "nt" else 0


@dataclass(frozen=True)
class AppConfig:
    app_id: str
    name: str
    project_dir: Path
    script: Path
    workdir: Path
    icon: Path | None
    default_times: tuple[str, ...]
    installed_file_sets: tuple[tuple[Path, ...], ...] = ()
    initialization_file_sets: tuple[tuple[Path, ...], ...] = ()
    requires_game_verification: bool = True
    cleanup_commands: tuple[tuple[str, ...], ...] = ()


APPS: tuple[AppConfig, ...] = (
    AppConfig(
        app_id="maa",
        name="MAA-明日方舟",
        project_dir=ROOT / "Apps" / "MAA",
        script=SCRIPTS / "Run-MAA-Daily.ps1",
        workdir=ROOT,
        icon=None,
        default_times=("00:00", "19:00"),
        installed_file_sets=(
            (
                SRC_DIR / "MAA" / "MAA.exe",
                SRC_DIR / "MAA" / "maa-cli.exe",
            ),
            (
                SRC_DIR / "MaaAssistantArknights" / "MAA.exe",
                SRC_DIR / "MaaAssistantArknights" / "maa-cli.exe",
            ),
            (
                ROOT / "Apps" / "MAA" / "MAA.exe",
                ROOT / "Apps" / "MAA" / "maa-cli.exe",
            ),
        ),
        initialization_file_sets=(
            (SRC_DIR / "MAA" / "MAA.exe",),
            (SRC_DIR / "MaaAssistantArknights" / "MAA.exe",),
            (ROOT / "Apps" / "MAA" / "MAA.exe",),
        ),
        requires_game_verification=False,
        cleanup_commands=(
            (
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPTS / "Stop-MAA-Daily.ps1"),
            ),
        ),
    ),
    AppConfig(
        app_id="bettergi",
        name="BetterGI-原神",
        project_dir=ROOT / "Apps" / "BetterGI",
        script=SCRIPTS / "Start-BetterGI-OneDragon.ps1",
        workdir=ROOT,
        icon=None,
        default_times=("04:30",),
        installed_file_sets=(
            (SRC_DIR / "BetterGI" / "BetterGI.exe",),
            (SRC_DIR / "better-genshin-impact" / "BetterGI.exe",),
            (ROOT / "Apps" / "BetterGI" / "BetterGI.exe",),
        ),
        requires_game_verification=False,
        cleanup_commands=(("taskkill", "/IM", "BetterGI.exe", "/T", "/F"),),
    ),
    AppConfig(
        app_id="wuthering",
        name="ok-鸣潮",
        project_dir=SRC_DIR / "ok-wuthering-waves",
        script=SCRIPTS / "Run-OkWutheringWavesDaily.ps1",
        workdir=ROOT,
        icon=SRC_DIR / "ok-wuthering-waves" / "icons" / "icon.png",
        default_times=(),
    ),
    AppConfig(
        app_id="endfield",
        name="ok-终末地",
        project_dir=SRC_DIR / "ok-end-field",
        script=SCRIPTS / "Run-OkEndFieldDaily.ps1",
        workdir=ROOT,
        icon=SRC_DIR / "ok-end-field" / "icons" / "icon.png",
        default_times=(),
    ),
    AppConfig(
        app_id="nte",
        name="ok-异环",
        project_dir=SRC_DIR / "ok-nte",
        script=SCRIPTS / "Run-OkNteDaily.ps1",
        workdir=ROOT,
        icon=SRC_DIR / "ok-nte" / "icons" / "icon.png",
        default_times=(),
    ),
)

INSTALL_DIR_MARKERS = {
    "maa": ("MAA.exe", "maa-cli.exe"),
    "bettergi": ("BetterGI.exe",),
}
INITIALIZATION_DIR_MARKERS = {
    "maa": ("MAA.exe",),
}
GAME_PROCESS_NAMES = {
    "wuthering": "Client-Win64-Shipping.exe",
    "endfield": "Endfield.exe",
    "nte": "HTGame.exe",
}


def ensure_dirs() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    LOG_ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
    SCRIPTS.mkdir(parents=True, exist_ok=True)


def now_text() -> str:
    return datetime.now().strftime("%H:%M:%S")


def validate_times(raw: str) -> list[str]:
    items = [item.strip() for item in re.split(r"[,，\s]+", raw) if item.strip()]
    if not items:
        raise ValueError("至少填写一个时间，例如 07:00")

    result: list[str] = []
    for item in items:
        if not re.fullmatch(r"\d{1,2}:\d{2}", item):
            raise ValueError(f"时间格式错误: {item}")
        hour, minute = (int(part) for part in item.split(":"))
        if hour > 23 or minute > 59:
            raise ValueError(f"时间超出范围: {item}")
        result.append(f"{hour:02d}:{minute:02d}")
    return sorted(set(result))


def app_installed(app: AppConfig) -> bool:
    if app.installed_file_sets:
        return any(all(path.is_file() for path in marker_set) for marker_set in app.installed_file_sets)
    return (app.project_dir / "requirements.txt").is_file() and (
        app.project_dir / "main.py"
    ).is_file()


def app_needs_initialization(app: AppConfig) -> bool:
    if not app.initialization_file_sets or app_installed(app):
        return False
    return any(
        all(path.is_file() for path in marker_set)
        for marker_set in app.initialization_file_sets
    )


def default_app_settings(app: AppConfig) -> dict:
    app_settings = {
        "enabled": False,
        "times": list(app.default_times),
        "game_verified": not app.requires_game_verification,
    }
    if app.requires_game_verification:
        app_settings["game_path"] = ""
        app_settings["game_dir"] = ""
    elif app.app_id in INSTALL_DIR_MARKERS:
        app_settings["install_dir"] = ""
    return app_settings


def settings_path_value(value: object) -> Path | None:
    if not isinstance(value, str):
        return None
    value = os.path.expandvars(value.strip())
    if not value:
        return None
    path = Path(value)
    if not path.is_absolute():
        path = ROOT / path
    return path


def canonical_path_text(path: Path) -> str:
    return str(path.resolve(strict=False))


def install_dir_has_markers(app: AppConfig, install_dir: Path, markers: dict[str, tuple[str, ...]]) -> bool:
    names = markers.get(app.app_id)
    if not names:
        return False
    return all((install_dir / name).is_file() for name in names)


def install_dir_ready(app: AppConfig, install_dir: Path) -> bool:
    return install_dir_has_markers(app, install_dir, INSTALL_DIR_MARKERS)


def install_dir_needs_initialization(app: AppConfig, install_dir: Path) -> bool:
    return (
        install_dir_has_markers(app, install_dir, INITIALIZATION_DIR_MARKERS)
        and not install_dir_ready(app, install_dir)
    )


def detected_install_dir(app: AppConfig, allow_initialization: bool = False) -> Path | None:
    for marker_set in app.installed_file_sets:
        if all(path.is_file() for path in marker_set):
            return marker_set[0].parent
    if allow_initialization:
        for marker_set in app.initialization_file_sets:
            if all(path.is_file() for path in marker_set):
                return marker_set[0].parent
    return None


def read_json_object(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return loaded if isinstance(loaded, dict) else {}


def write_json_object(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def saved_game_path_from_project(app: AppConfig) -> Path | None:
    config = read_json_object(app.project_dir / "configs" / "devices.json")
    path = settings_path_value(config.get("pc_full_path"))
    if path and path.is_file():
        return path
    return None


def derive_nte_launcher_path(game_path: Path) -> Path | None:
    full_path = canonical_path_text(game_path)
    marker = "\\Client\\"
    index = full_path.lower().find(marker.lower())
    if index < 0:
        return None
    install_root = Path(full_path[:index])
    candidate = install_root / "NTELauncher" / "NTEGame.exe"
    if candidate.is_file():
        return candidate
    return None


def sync_game_path_config(app: AppConfig, game_path: Path) -> None:
    if not app.project_dir.is_dir():
        return

    process_name = GAME_PROCESS_NAMES.get(app.app_id)
    if not process_name:
        return

    config_path = app.project_dir / "configs" / "devices.json"
    config = read_json_object(config_path)
    config.update(
        {
            "preferred": "pc",
            "pc_full_path": canonical_path_text(game_path),
            "capture": "windows",
            "selected_exe": process_name,
            "selected_hwnd": 0,
        }
    )
    config.setdefault("interaction", "")
    write_json_object(config_path, config)

    if app.app_id != "nte":
        return

    launcher_path = derive_nte_launcher_path(game_path)
    if not launcher_path:
        return
    launcher_config_path = app.project_dir / "configs" / "LauncherTask.json"
    launcher_config = read_json_object(launcher_config_path)
    launcher_config["Launcher Path"] = canonical_path_text(launcher_path)
    write_json_object(launcher_config_path, launcher_config)


class Settings:
    def __init__(self, path: Path):
        self.path = path
        self.loaded_from_legacy = False
        self.data = self._load()
        self.refresh_paths(save=False)

    def _load(self) -> dict:
        defaults = {
            "settings_version": SETTINGS_VERSION,
            "apps": {app.app_id: default_app_settings(app) for app in APPS},
            "last_runs": {},
            "log_archives": {},
        }

        source_path = self.path
        if not source_path.exists() and LEGACY_SETTINGS_PATH.exists():
            source_path = LEGACY_SETTINGS_PATH
            self.loaded_from_legacy = True
        if not source_path.exists():
            return defaults

        try:
            loaded = json.loads(source_path.read_text(encoding="utf-8"))
        except Exception:
            return defaults
        if not isinstance(loaded, dict):
            return defaults

        loaded.setdefault("apps", {})
        if not isinstance(loaded["apps"], dict):
            loaded["apps"] = {}
        for app in APPS:
            if not isinstance(loaded["apps"].get(app.app_id), dict):
                loaded["apps"][app.app_id] = {}
            app_settings = loaded["apps"][app.app_id]
            for key, value in default_app_settings(app).items():
                app_settings.setdefault(key, value)
            if loaded.get("settings_version") != SETTINGS_VERSION:
                if (
                    app_settings.get("enabled") is True
                    and app_settings.get("times") == LEGACY_DEFAULT_TIMES.get(app.app_id)
                ):
                    app_settings["enabled"] = False
                    app_settings["times"] = []
        loaded["settings_version"] = SETTINGS_VERSION
        loaded.setdefault("last_runs", {})
        loaded.setdefault("log_archives", {})
        return loaded

    def reload(self) -> None:
        self.loaded_from_legacy = False
        self.data = self._load()
        self.refresh_paths(save=False)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(self.data, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def refresh_paths(self, save: bool = True) -> None:
        changed = False
        for app in APPS:
            app_settings = self.data["apps"].setdefault(app.app_id, default_app_settings(app))
            if app.app_id in INSTALL_DIR_MARKERS:
                changed = self._refresh_install_dir(app, app_settings) or changed
            if app.requires_game_verification:
                changed = self._refresh_game_path(app, app_settings) or changed
        if changed and save:
            self.save()

    def _refresh_install_dir(self, app: AppConfig, app_settings: dict) -> bool:
        configured = settings_path_value(app_settings.get("install_dir"))
        if configured and (
            install_dir_ready(app, configured)
            or install_dir_needs_initialization(app, configured)
        ):
            return self._set_if_changed(app_settings, "install_dir", canonical_path_text(configured))

        detected = detected_install_dir(app, allow_initialization=True)
        if detected:
            return self._set_if_changed(app_settings, "install_dir", canonical_path_text(detected))
        return False

    def _refresh_game_path(self, app: AppConfig, app_settings: dict) -> bool:
        changed = False
        game_path = settings_path_value(app_settings.get("game_path"))
        if not (game_path and game_path.is_file()):
            game_path = saved_game_path_from_project(app)

        if game_path and game_path.is_file():
            changed = self._set_if_changed(app_settings, "game_path", canonical_path_text(game_path)) or changed
            changed = self._set_if_changed(app_settings, "game_dir", canonical_path_text(game_path.parent)) or changed
            changed = self._set_if_changed(app_settings, "game_verified", True) or changed
            sync_game_path_config(app, game_path)
            return changed

        if app_settings.get("game_verified"):
            app_settings["game_verified"] = False
            app_settings.pop("game_verified_at", None)
            changed = True
        return changed

    def _set_if_changed(self, data: dict, key: str, value: object) -> bool:
        if data.get(key) == value:
            return False
        data[key] = value
        return True

    def configured_install_dir(self, app: AppConfig) -> Path | None:
        if app.app_id not in INSTALL_DIR_MARKERS:
            return None
        return settings_path_value(self.data["apps"][app.app_id].get("install_dir"))

    def app_installed(self, app: AppConfig) -> bool:
        install_dir = self.configured_install_dir(app)
        if install_dir and install_dir_ready(app, install_dir):
            return True
        return app_installed(app)

    def app_needs_initialization(self, app: AppConfig) -> bool:
        install_dir = self.configured_install_dir(app)
        if install_dir and install_dir_needs_initialization(app, install_dir):
            return True
        return app_needs_initialization(app)

    def app_enabled(self, app: AppConfig) -> bool:
        return bool(self.data["apps"][app.app_id].get("enabled", False))

    def app_times(self, app: AppConfig) -> list[str]:
        times = self.data["apps"][app.app_id].get("times")
        if times is None:
            times = app.default_times
        if isinstance(times, str):
            return [times]
        if not isinstance(times, (list, tuple)):
            return list(app.default_times)
        return list(times)

    def update_app(self, app: AppConfig, enabled: bool, times: list[str]) -> None:
        current = self.data["apps"].setdefault(app.app_id, {})
        current.update({"enabled": enabled, "times": times})
        self.save()

    def game_verified(self, app: AppConfig) -> bool:
        return bool(self.data["apps"][app.app_id].get("game_verified", False))

    def mark_game_verified(self, app: AppConfig) -> None:
        app_settings = self.data["apps"].setdefault(app.app_id, {})
        app_settings["game_verified"] = True
        app_settings["game_verified_at"] = datetime.now().isoformat(timespec="seconds")
        self.save()

    def clear_game_verified(self, app: AppConfig) -> None:
        app_settings = self.data["apps"].setdefault(app.app_id, {})
        app_settings["game_verified"] = False
        app_settings.pop("game_verified_at", None)
        self.save()

    def was_run(self, app: AppConfig, date: str, time_value: str) -> bool:
        return self._key(app, date, time_value) in self.data["last_runs"]

    def mark_run(self, app: AppConfig, date: str, time_value: str, reason: str) -> None:
        self.data["last_runs"][self._key(app, date, time_value)] = {
            "at": datetime.now().isoformat(timespec="seconds"),
            "reason": reason,
        }
        self._prune_runs()
        self.save()

    def _key(self, app: AppConfig, date: str, time_value: str) -> str:
        return f"{app.app_id}|{date}|{time_value}"

    def _prune_runs(self) -> None:
        keep_after = (datetime.now() - timedelta(days=14)).strftime("%Y-%m-%d")
        self.data["last_runs"] = {
            key: value
            for key, value in self.data["last_runs"].items()
            if key.split("|")[1] >= keep_after
        }

    def was_log_archive_done(self, date_value: date) -> bool:
        return date_value.isoformat() in self.data["log_archives"]

    def mark_log_archive(self, date_value: date, archive_path: Path, file_count: int) -> None:
        self.data["log_archives"][date_value.isoformat()] = {
            "at": datetime.now().isoformat(timespec="seconds"),
            "path": str(archive_path),
            "file_count": file_count,
        }
        self._prune_log_archives()
        self.save()

    def _prune_log_archives(self) -> None:
        keep_after = (datetime.now() - timedelta(days=60)).date().isoformat()
        self.data["log_archives"] = {
            key: value
            for key, value in self.data["log_archives"].items()
            if key >= keep_after
        }


class AppInstaller:
    def __init__(self, app: AppConfig, log_queue: queue.Queue[tuple[str, str]]):
        self.app = app
        self.log_queue = log_queue
        self.process: subprocess.Popen[str] | None = None
        self.lock = threading.Lock()

    @property
    def running(self) -> bool:
        with self.lock:
            return self.process is not None and self.process.poll() is None

    def start(self) -> bool:
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                self.log("安装正在运行，忽略新的安装请求")
                return False

            command = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPTS / "Install-App.ps1"),
                "-AppId",
                self.app.app_id,
            ]
            self.log(f"安装: {' '.join(command)}")
            self.process = subprocess.Popen(
                command,
                cwd=str(ROOT),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                creationflags=TASK_PROCESS_FLAGS,
            )

        threading.Thread(target=self._read_output, daemon=True).start()
        return True

    def log(self, message: str) -> None:
        self.log_queue.put((self.app.app_id, message))

    def _read_output(self) -> None:
        process = self.process
        if process is None:
            return

        assert process.stdout is not None
        for line in process.stdout:
            self.log(line.rstrip())

        exit_code = process.wait()
        self.log(f"安装结束，退出码: {exit_code}")
        with self.lock:
            if self.process is process:
                self.process = None
        self.log_queue.put((self.app.app_id, f"__INSTALL_EXIT__:{exit_code}"))


class AppRunner:
    def __init__(self, app: AppConfig, log_queue: queue.Queue[tuple[str, str]]):
        self.app = app
        self.log_queue = log_queue
        self.process: subprocess.Popen[str] | None = None
        self.log_file: Path | None = None
        self.lock = threading.Lock()

    @property
    def running(self) -> bool:
        with self.lock:
            return self.process is not None and self.process.poll() is None

    def start(self, reason: str) -> bool:
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                self.log("已经在运行，忽略新的启动请求")
                return False

            ensure_dirs()
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self.log_file = LOG_DIR / f"{stamp}_{self.app.app_id}_{reason}.log"
            command = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(self.app.script),
            ]
            self.log(f"启动: {' '.join(command)}")
            self.log(f"日志文件: {self.log_file}")

            self.process = subprocess.Popen(
                command,
                cwd=str(self.app.workdir),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                creationflags=TASK_PROCESS_FLAGS,
            )

        threading.Thread(target=self._read_output, daemon=True).start()
        return True

    def stop(self) -> None:
        with self.lock:
            process = self.process

        if process is None or process.poll() is not None:
            self.log("没有正在运行的任务")
            self._cleanup()
            return

        self.log(f"强制退出进程树 PID={process.pid}")
        threading.Thread(target=self._kill_tree, args=(process.pid,), daemon=True).start()

    def log(self, message: str) -> None:
        self.log_queue.put((self.app.app_id, message))
        if self.log_file is not None:
            try:
                with self.log_file.open("a", encoding="utf-8") as handle:
                    handle.write(f"[{now_text()}] {message}\n")
            except OSError:
                pass

    def _read_output(self) -> None:
        process = self.process
        if process is None:
            return

        assert process.stdout is not None
        for line in process.stdout:
            self.log(line.rstrip())

        exit_code = process.wait()
        self.log(f"任务结束，退出码: {exit_code}")
        with self.lock:
            if self.process is process:
                self.process = None
        self.log_queue.put((self.app.app_id, "__STATUS__"))

    def _kill_tree(self, pid: int) -> None:
        result = subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            creationflags=HIDDEN_PROCESS_FLAGS,
        )
        output = result.stdout.strip()
        if output:
            for line in output.splitlines():
                self.log(line)
        self._cleanup()
        self.log_queue.put((self.app.app_id, "__STATUS__"))

    def _cleanup(self) -> None:
        for command in self.app.cleanup_commands:
            if not command:
                continue
            executable = command[0]
            if ":" in executable and not Path(executable).exists():
                self.log(f"跳过清理，文件不存在: {executable}")
                continue
            result = subprocess.run(
                list(command),
                text=True,
                encoding="utf-8",
                errors="replace",
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
                creationflags=HIDDEN_PROCESS_FLAGS,
            )
            self.log(f"清理命令: {' '.join(command)} -> {result.returncode}")
            output = result.stdout.strip()
            if output:
                for line in output.splitlines():
                    self.log(line)


class TaskRow:
    def __init__(
        self,
        parent: Frame,
        app: AppConfig,
        runner: AppRunner,
        installer: AppInstaller,
        settings: Settings,
        scheduler: "DailyGui",
    ):
        self.app = app
        self.runner = runner
        self.installer = installer
        self.settings = settings
        self.scheduler = scheduler

        self.frame = Frame(parent, bg="#f7f7f4", padx=16, pady=14)
        self.frame.pack(fill=X)

        self.icon_image = load_icon(app, 70)
        Label(self.frame, image=self.icon_image, bg="#f7f7f4").pack(side=LEFT)

        info = Frame(self.frame, bg="#f7f7f4", padx=16)
        info.pack(side=LEFT, fill=X, expand=True)
        Label(
            info,
            text=app.name,
            bg="#f7f7f4",
            fg="#1f1f1f",
            font=("Microsoft YaHei UI", 15, "bold"),
            anchor="w",
        ).pack(fill=X)

        self.status_var = StringVar()
        Label(
            info,
            textvariable=self.status_var,
            bg="#f7f7f4",
            fg="#555555",
            font=("Microsoft YaHei UI", 10),
            anchor="w",
        ).pack(fill=X, pady=(4, 0))

        actions = Frame(self.frame, bg="#f7f7f4")
        actions.pack(side=RIGHT)

        self.start_button = ttk.Button(actions, text="启动", command=self.start)
        self.stop_button = ttk.Button(actions, text="强制退出", command=self.stop)
        self.schedule_button = ttk.Button(actions, text="定时", command=self.configure_schedule)
        self.install_button = ttk.Button(actions, text="安装", command=self.install)
        self.verify_button = ttk.Button(actions, text="确认游戏", command=self.verify_game)
        self.start_button.grid(row=0, column=0, padx=6, ipadx=18, ipady=10)
        self.stop_button.grid(row=0, column=1, padx=6, ipadx=12, ipady=10)
        self.schedule_button.grid(row=0, column=2, padx=6, ipadx=18, ipady=10)
        self.install_button.grid(row=0, column=0, columnspan=3, padx=6, ipadx=86, ipady=10)
        self.verify_button.grid(row=0, column=0, columnspan=3, padx=6, ipadx=76, ipady=10)

        Canvas(parent, height=1, bg="#222222", highlightthickness=0).pack(
            fill=X, padx=18, pady=4
        )
        self.refresh()

    def start(self, reason: str = "manual") -> None:
        if not self.settings.app_installed(self.app):
            self.install()
            return
        if (
            self.app.requires_game_verification
            and not self.settings.game_verified(self.app)
        ):
            if not self.scheduler.ensure_game_verified(self.app):
                self.refresh()
                return
        if reason == "manual" and self.scheduler.any_running(except_app_id=self.app.app_id):
            if not messagebox.askyesno(
                "已有任务运行",
                "已有其他任务正在运行。继续启动可能抢占前台窗口或设备，是否仍要启动？",
                parent=self.scheduler.root,
            ):
                return
        if self.runner.start(reason):
            self.refresh()

    def stop(self) -> None:
        self.runner.stop()
        self.refresh()

    def install(self) -> None:
        if self.installer.start():
            self.refresh()

    def verify_game(self) -> None:
        self.scheduler.ensure_game_verified(self.app, force_prompt=True)
        self.refresh()

    def refresh(self) -> None:
        if self.installer.running:
            self.status_var.set("安装中 | 正在下载并准备运行环境")
            self.start_button.grid_remove()
            self.stop_button.grid_remove()
            self.schedule_button.grid_remove()
            self.verify_button.grid_remove()
            self.install_button.grid()
            self.install_button.configure(text="安装")
            self.install_button.configure(state="disabled")
            return

        if not self.settings.app_installed(self.app):
            if self.settings.app_needs_initialization(self.app):
                self.status_var.set("已检测到本地程序 | 点击初始化下载缺失组件")
                self.install_button.configure(text="初始化")
            else:
                self.status_var.set("未安装 | 点击安装下载并准备运行环境")
                self.install_button.configure(text="安装")
            self.start_button.grid_remove()
            self.stop_button.grid_remove()
            self.schedule_button.grid_remove()
            self.install_button.grid()
            self.verify_button.grid_remove()
            self.install_button.configure(
                state="disabled" if self.installer.running else "normal"
            )
            return

        self.install_button.grid_remove()
        self.install_button.configure(text="安装")
        if (
            self.app.requires_game_verification
            and not self.settings.game_verified(self.app)
        ):
            self.status_var.set("已安装 | 未确认游戏位置 | 打开游戏后点击确认")
            self.start_button.grid_remove()
            self.stop_button.grid_remove()
            self.schedule_button.grid_remove()
            self.verify_button.grid()
            self.verify_button.configure(state="normal")
            return

        self.verify_button.grid_remove()
        self.start_button.grid()
        self.stop_button.grid()
        self.schedule_button.grid()
        enabled = self.settings.app_enabled(self.app)
        times_list = self.settings.app_times(self.app)
        times = ", ".join(times_list) if times_list else "未设置"
        state = "运行中" if self.runner.running else "空闲"
        schedule = "定时开" if enabled and times_list else "定时关"
        self.status_var.set(f"{state} | {schedule} | {times}")
        self.start_button.configure(state="disabled" if self.runner.running else "normal")
        self.stop_button.configure(state="normal" if self.runner.running else "disabled")

    def configure_schedule(self) -> None:
        ScheduleDialog(self.scheduler.root, self.app, self.settings, self.refresh)


class ScheduleDialog:
    def __init__(self, root: Tk, app: AppConfig, settings: Settings, on_save):
        self.app = app
        self.settings = settings
        self.on_save = on_save
        self.window = Toplevel(root)
        self.window.title(f"定时 - {app.name}")
        self.window.resizable(False, False)
        self.window.transient(root)
        self.window.grab_set()

        panel = Frame(self.window, padx=18, pady=16, bg="#f7f7f4")
        panel.pack(fill=BOTH, expand=True)

        self.enabled = BooleanVar(value=settings.app_enabled(app))
        Checkbutton(
            panel,
            text="启用定时",
            variable=self.enabled,
            bg="#f7f7f4",
            font=("Microsoft YaHei UI", 11),
        ).pack(anchor="w")

        Label(
            panel,
            text="时间，多个用逗号分隔，例如 00:00,19:00",
            bg="#f7f7f4",
            fg="#555555",
            font=("Microsoft YaHei UI", 10),
        ).pack(anchor="w", pady=(12, 4))

        self.times = StringVar(value=",".join(settings.app_times(app)))
        Entry(panel, textvariable=self.times, width=34, font=("Consolas", 12)).pack(fill=X)

        buttons = Frame(panel, bg="#f7f7f4")
        buttons.pack(anchor="e", pady=(16, 0))
        ttk.Button(buttons, text="取消", command=self.window.destroy).pack(side=LEFT, padx=6)
        ttk.Button(buttons, text="保存", command=self.save).pack(side=LEFT)

    def save(self) -> None:
        raw_times = self.times.get()
        if self.enabled.get() or raw_times.strip():
            try:
                times = validate_times(raw_times)
            except ValueError as exc:
                messagebox.showerror("定时设置错误", str(exc), parent=self.window)
                return
        else:
            times = []

        self.settings.update_app(self.app, self.enabled.get(), times)
        self.on_save()
        self.window.destroy()


class DailyGui:
    def __init__(self):
        ensure_dirs()
        self.settings = Settings(SETTINGS_PATH)
        self.settings.save()
        self.log_queue: queue.Queue[tuple[str, str]] = queue.Queue()
        self.installers = {app.app_id: AppInstaller(app, self.log_queue) for app in APPS}
        self.runners = {app.app_id: AppRunner(app, self.log_queue) for app in APPS}
        self.rows: dict[str, TaskRow] = {}
        self.images: list[ImageTk.PhotoImage] = []
        self.pending_scheduled: list[AppConfig] = []

        self.root = Tk()
        self.root.title("本地日常调度器")
        self.root.geometry("1080x640")
        self.root.minsize(980, 560)
        self.root.configure(bg="#f7f7f4")
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self._setup_style()
        self._build_layout()
        self._build_menu()

    def _setup_style(self) -> None:
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure(
            "TButton",
            font=("Microsoft YaHei UI", 12),
            padding=(12, 8),
            background="#f4f1ea",
            bordercolor="#777777",
        )

    def _build_layout(self) -> None:
        outer = Frame(self.root, bg="#f7f7f4", padx=18, pady=18)
        outer.pack(fill=BOTH, expand=True)

        left = Frame(outer, bg="#f7f7f4")
        left.pack(side=LEFT, fill=BOTH, expand=True, padx=(0, 18))

        right = Frame(outer, bg="#f7f7f4", highlightbackground="#8a8a8a", highlightthickness=1)
        right.pack(side=RIGHT, fill=Y)

        for app in APPS:
            row = TaskRow(
                left,
                app,
                self.runners[app.app_id],
                self.installers[app.app_id],
                self.settings,
                self,
            )
            self.rows[app.app_id] = row
            self.images.append(row.icon_image)

        Label(
            right,
            text="Logs",
            bg="#f7f7f4",
            fg="#1f1f1f",
            font=("Microsoft YaHei UI", 14, "bold"),
            pady=10,
        ).pack(fill=X)

        log_container = Frame(right, bg="#f7f7f4")
        log_container.pack(fill=BOTH, expand=True, padx=10, pady=(0, 10))
        scrollbar = Scrollbar(log_container)
        scrollbar.pack(side=RIGHT, fill=Y)
        self.log_text = Text(
            log_container,
            width=44,
            wrap="word",
            state="disabled",
            font=("Consolas", 10),
            bg="#fcfcfa",
            fg="#1f1f1f",
            yscrollcommand=scrollbar.set,
        )
        self.log_text.pack(side=LEFT, fill=BOTH, expand=True)
        scrollbar.config(command=self.log_text.yview)

        self.log("system", "GUI 已启动。定时检查每 10 秒执行一次。")

    def _build_menu(self) -> None:
        menu = Menu(self.root)
        task_menu = Menu(menu, tearoff=False)
        for app in APPS:
            task_menu.add_command(
                label=f"启动 {app.name}",
                command=lambda app_id=app.app_id: self.rows[app_id].start(),
            )
            task_menu.add_command(
                label=f"强制退出 {app.name}",
                command=lambda app_id=app.app_id: self.rows[app_id].stop(),
            )
            task_menu.add_separator()
        task_menu.add_command(label="强制退出全部", command=self.stop_all)
        menu.add_cascade(label="任务", menu=task_menu)
        menu.add_command(label="保存今天日志", command=self.save_today_logs)
        menu.add_command(label="清空日志", command=self.clear_logs)
        menu.add_command(label="退出", command=self.on_close)
        self.root.config(menu=menu)

    def run(self) -> None:
        self.root.after(250, self.process_logs)
        self.root.after(1000, self.check_schedule)
        self.root.mainloop()

    def log(self, app_id: str, message: str) -> None:
        self.log_queue.put((app_id, message))

    def app_by_id(self, app_id: str) -> AppConfig | None:
        return next((app for app in APPS if app.app_id == app_id), None)

    def ensure_game_verified(self, app: AppConfig, force_prompt: bool = False) -> bool:
        if not app.requires_game_verification:
            return True
        if self.settings.game_verified(app) and not force_prompt:
            return True
        if not self.settings.app_installed(app):
            return False

        if not messagebox.askokcancel(
            "确认游戏位置",
            f"请先打开 {app.name} 的 PC 游戏窗口。\n\n"
            "打开并等待游戏窗口出现后，点击“确定”开始检测。\n"
            "如果还没准备好，可以取消，之后再点“确认游戏”。",
            parent=self.root,
        ):
            self.log(app.app_id, "已取消游戏位置确认")
            return False

        command = [
            POWERSHELL,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SCRIPTS / "Verify-AppGame.ps1"),
            "-AppId",
            app.app_id,
        ]
        self.log(app.app_id, f"确认游戏位置: {' '.join(command)}")
        try:
            result = subprocess.run(
                command,
                cwd=str(ROOT),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=60,
                check=False,
                creationflags=HIDDEN_PROCESS_FLAGS,
            )
        except subprocess.TimeoutExpired:
            self.log(app.app_id, "确认游戏位置超时")
            messagebox.showerror(
                "确认失败",
                f"没有在限定时间内确认 {app.name} 的游戏位置。",
                parent=self.root,
            )
            return False

        output = result.stdout.strip()
        if output:
            for line in output.splitlines():
                self.log(app.app_id, line)

        if result.returncode == 0:
            self.settings.reload()
            self.settings.mark_game_verified(app)
            self.refresh_rows()
            messagebox.showinfo(
                "确认完成",
                f"{app.name} 的游戏位置已确认，可以正式运行。",
                parent=self.root,
            )
            return True

        self.settings.clear_game_verified(app)
        self.refresh_rows()
        messagebox.showerror(
            "确认失败",
            f"没有找到 {app.name} 的游戏进程。\n\n"
            "请确认已经打开 PC 游戏窗口，然后再试一次。",
            parent=self.root,
        )
        return False

    def process_logs(self) -> None:
        while True:
            try:
                app_id, message = self.log_queue.get_nowait()
            except queue.Empty:
                break

            if message == "__STATUS__":
                self.refresh_rows()
                self.start_next_scheduled()
                continue

            if message.startswith("__INSTALL_EXIT__:"):
                self.settings.refresh_paths()
                self.refresh_rows()
                exit_code_text = message.split(":", 1)[1]
                try:
                    exit_code = int(exit_code_text)
                except ValueError:
                    exit_code = -1
                app = self.app_by_id(app_id)
                if (
                    exit_code == 0
                    and app is not None
                    and self.settings.app_installed(app)
                    and app.requires_game_verification
                    and not self.settings.game_verified(app)
                ):
                    self.root.after(
                        100,
                        lambda current_app=app: self.ensure_game_verified(
                            current_app,
                            force_prompt=True,
                        ),
                    )
                self.start_next_scheduled()
                continue

            app_name = next((app.name for app in APPS if app.app_id == app_id), app_id)
            self.log_text.configure(state="normal")
            self.log_text.insert(END, f"[{now_text()}] [{app_name}] {message}\n")
            self.log_text.see(END)
            self.log_text.configure(state="disabled")

        self.root.after(250, self.process_logs)

    def check_schedule(self) -> None:
        now = datetime.now()
        today = now.strftime("%Y-%m-%d")
        self.check_log_archive(now)
        for app in APPS:
            if not self.settings.app_installed(app):
                continue
            if app.requires_game_verification and not self.settings.game_verified(app):
                continue
            if not self.settings.app_enabled(app):
                continue

            for time_value in self.settings.app_times(app):
                hour, minute = (int(part) for part in time_value.split(":"))
                scheduled = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
                if now < scheduled or now > scheduled + timedelta(minutes=CATCH_UP_MINUTES):
                    continue
                if self.settings.was_run(app, today, time_value):
                    continue

                self.settings.mark_run(app, today, time_value, "scheduled")
                self.queue_scheduled(app, time_value)

        self.refresh_rows()
        self.start_next_scheduled()
        self.root.after(10_000, self.check_schedule)

    def check_log_archive(self, now: datetime) -> None:
        midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
        if now < midnight or now > midnight + timedelta(minutes=CATCH_UP_MINUTES):
            return

        target_date = (now - timedelta(days=1)).date()
        if self.settings.was_log_archive_done(target_date):
            return

        archive_path, file_count = archive_logs_for_date(target_date, self.current_log_text())
        self.settings.mark_log_archive(target_date, archive_path, file_count)
        self.clear_logs()
        self.log("system", f"已自动保存 {target_date.isoformat()} 日志到 {archive_path}，文件数 {file_count}")

    def save_today_logs(self) -> None:
        target_date = datetime.now().date()
        archive_path, file_count = archive_logs_for_date(target_date, self.current_log_text())
        self.settings.mark_log_archive(target_date, archive_path, file_count)
        self.clear_logs()
        self.log("system", f"已手动保存今天日志到 {archive_path}，文件数 {file_count}")
        messagebox.showinfo(
            "日志已保存",
            f"保存路径：\n{archive_path}\n\n文件数：{file_count}",
            parent=self.root,
        )

    def queue_scheduled(self, app: AppConfig, time_value: str) -> None:
        if app.app_id in [item.app_id for item in self.pending_scheduled]:
            return
        self.pending_scheduled.append(app)
        self.log(app.app_id, f"到达定时时间 {time_value}，已加入串行队列")

    def start_next_scheduled(self) -> None:
        if self.any_running():
            return
        if not self.pending_scheduled:
            return
        app = self.pending_scheduled.pop(0)
        self.log(app.app_id, "开始执行队列中的定时任务")
        self.rows[app.app_id].start(reason="scheduled")

    def any_running(self, except_app_id: str | None = None) -> bool:
        for app_id, runner in self.runners.items():
            if except_app_id is not None and app_id == except_app_id:
                continue
            if runner.running:
                return True
        return False

    def refresh_rows(self) -> None:
        for row in self.rows.values():
            row.refresh()

    def stop_all(self) -> None:
        for runner in self.runners.values():
            runner.stop()

    def clear_logs(self) -> None:
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", END)
        self.log_text.configure(state="disabled")

    def current_log_text(self) -> str:
        return self.log_text.get("1.0", END).strip()

    def on_close(self) -> None:
        running = [app.name for app in APPS if self.runners[app.app_id].running]
        if running:
            choice = messagebox.askyesnocancel(
                "仍有任务运行",
                "以下任务仍在运行：\n"
                + "\n".join(running)
                + "\n\n是：强制退出后关闭\n否：仅关闭窗口\n取消：返回",
                parent=self.root,
            )
            if choice is None:
                return
            if choice is True:
                self.stop_all()
        self.root.destroy()


def load_icon(app: AppConfig, size: int) -> ImageTk.PhotoImage:
    try:
        if app.icon is None:
            raise FileNotFoundError
        image = Image.open(app.icon).convert("RGBA")
    except Exception:
        image = Image.new("RGBA", (size, size), "#d8d2c4")
        draw = ImageDraw.Draw(image)
        try:
            font = ImageFont.truetype("msyh.ttc", 20)
        except Exception:
            font = ImageFont.load_default()
        text = app.name[:2]
        box = draw.textbbox((0, 0), text, font=font)
        draw.text(
            ((size - (box[2] - box[0])) / 2, (size - (box[3] - box[1])) / 2),
            text,
            fill="#1f1f1f",
            font=font,
        )

    image.thumbnail((size, size), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(image, ((size - image.width) // 2, (size - image.height) // 2))
    return ImageTk.PhotoImage(canvas)


def archive_logs_for_date(target_date: date, displayed_logs: str | None = None) -> tuple[Path, int]:
    ensure_dirs()
    date_tag = target_date.strftime("%Y%m%d")
    archive_path = LOG_ARCHIVE_DIR / f"LocalDailyGui_{date_tag}.logs"
    log_files = sorted(LOG_DIR.glob(f"{date_tag}_*.log"))

    lines = [
        f"Archive created: {datetime.now().isoformat(timespec='seconds')}",
        f"Target date: {target_date.isoformat()}",
        f"Source directory: {LOG_DIR}",
        f"Task log file count: {len(log_files)}",
        "",
        "===== GUI Logs Panel =====",
        displayed_logs or "(empty)",
        "",
        "===== Task Log Files =====",
    ]

    for path in log_files:
        lines.extend(
            [
                "",
                f"----- {path.name} -----",
            ]
        )
        try:
            lines.append(path.read_text(encoding="utf-8", errors="replace").rstrip())
        except OSError as exc:
            lines.append(f"<failed to read {path}: {exc}>")

    archive_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

    return archive_path, len(log_files)


def check_config() -> int:
    settings = Settings(SETTINGS_PATH)
    print(f"Python: {os.sys.executable}")
    print(f"Project root: {ROOT}")
    print(f"Settings: {SETTINGS_PATH}")
    if settings.loaded_from_legacy:
        print(f"Legacy settings source: {LEGACY_SETTINGS_PATH}")
    print(f"Log directory: {LOG_DIR}")
    print(f"Log archive directory: {LOG_ARCHIVE_DIR}")
    for app in APPS:
        markers = (
            ";".join(
                ",".join(str(path.exists()).lower() for path in marker_set)
                for marker_set in app.installed_file_sets
            )
            if app.installed_file_sets
            else "default"
        )
        app_settings = settings.data["apps"].get(app.app_id, {})
        saved_path = app_settings.get("install_dir") or app_settings.get("game_path") or ""
        print(
            f"{app.app_id}: script={app.script.exists()} "
            f"project={settings.app_installed(app)} "
            f"workdir={app.workdir.exists()} icon={app.icon and app.icon.exists()} "
            f"verify={app.requires_game_verification} saved_path={saved_path} markers={markers}"
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Local daily GUI scheduler.")
    parser.add_argument("--check", action="store_true", help="validate config and exit")
    args = parser.parse_args()

    if args.check:
        return check_config()

    DailyGui().run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
