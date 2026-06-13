from __future__ import annotations

import argparse
import ctypes
import json
import os
import queue
import re
import subprocess
import threading
from ctypes import wintypes
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from tkinter import (
    BooleanVar,
    END,
    HORIZONTAL,
    LEFT,
    RIGHT,
    BOTH,
    VERTICAL,
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
ICONS_DIR = ROOT / "icons"
APP_ICON = ICONS_DIR / "icon.png"
MAA_ICON = ICONS_DIR / "maa.png"
BETTERGI_ICON = ICONS_DIR / "bettergi.png"
WUTHERING_ICON = ICONS_DIR / "ok-wuthering-waves.png"
ENDFIELD_ICON = ICONS_DIR / "ok-end-field.png"
NTE_ICON = ICONS_DIR / "ok-nte.png"
STARRAIL_ICON = ICONS_DIR / "starrail.png"
LOG_DIR = ROOT / "Logs" / "LocalDailyGui"
LOG_ARCHIVE_DIR = ROOT / "Logs"
DEBUG_COMMANDS_PATH = LOG_DIR / "debug_commands.jsonl"
DEBUG_STATUS_PATH = LOG_DIR / "debug_status.json"
DEBUG_POLL_MS = 2_000
DEBUG_STATUS_REFRESH_SECONDS = 10
SETTINGS_PATH = ROOT / "Setting.json"
LEGACY_SETTINGS_PATH = SCRIPTS / "LocalDailyGui.settings.json"
POWERSHELL = "powershell.exe"
CATCH_UP_MINUTES = 30
SCHEDULED_RUN_TIMEOUT_MINUTES = 30
SCHEDULED_RUN_TIMEOUT = timedelta(minutes=SCHEDULED_RUN_TIMEOUT_MINUTES)
LOG_FILE_STAMP_FORMAT = "%Y%m%d_%H%M%S"
LOG_FILE_STAMP_LENGTH = 15
SETTINGS_VERSION = 7
LEGACY_DEFAULT_TIMES: dict[str, list[str]] = {}
SUBMODULE_UPDATE_LABEL = "子项目更新"
CREATE_NEW_PROCESS_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
TASK_PROCESS_FLAGS = CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW if os.name == "nt" else 0
HIDDEN_PROCESS_FLAGS = CREATE_NO_WINDOW if os.name == "nt" else 0


class SingleInstanceLock:
    ERROR_ALREADY_EXISTS = 183

    def __init__(self, name: str):
        self.handle: int | None = None
        self._kernel32 = None
        self.already_exists = False
        if os.name != "nt":
            return

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.argtypes = (ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR)
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel32.CloseHandle.restype = wintypes.BOOL

        handle = kernel32.CreateMutexW(None, False, name)
        if not handle:
            return
        self.handle = handle
        self._kernel32 = kernel32
        self.already_exists = ctypes.get_last_error() == self.ERROR_ALREADY_EXISTS

    def close(self) -> None:
        if self.handle and self._kernel32:
            self._kernel32.CloseHandle(self.handle)
        self.handle = None


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
    requires_emulator_verification: bool = False
    cleanup_commands: tuple[tuple[str, ...], ...] = ()


APPS: tuple[AppConfig, ...] = (
    AppConfig(
        app_id="maa-gui",
        name="MAA-明日方舟",
        project_dir=ROOT / "Apps" / "MAA",
        script=SCRIPTS / "Run-MAA-GUI.ps1",
        workdir=ROOT,
        icon=MAA_ICON,
        default_times=(),
        installed_file_sets=(
            (SRC_DIR / "MAA" / "MAA.exe",),
            (SRC_DIR / "MaaAssistantArknights" / "MAA.exe",),
            (ROOT / "Apps" / "MAA" / "MAA.exe",),
        ),
        initialization_file_sets=(
            (SRC_DIR / "MAA" / "MAA.exe",),
            (SRC_DIR / "MaaAssistantArknights" / "MAA.exe",),
            (ROOT / "Apps" / "MAA" / "MAA.exe",),
        ),
        requires_game_verification=False,
        cleanup_commands=(
            ("taskkill", "/IM", "MAA.exe", "/T", "/F"),
        ),
    ),
    AppConfig(
        app_id="maa",
        name="MAA-cli",
        project_dir=ROOT / "Apps" / "MAA",
        script=SCRIPTS / "Run-MAA-Daily.ps1",
        workdir=ROOT,
        icon=MAA_ICON,
        default_times=(),
        requires_emulator_verification=True,
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
        icon=BETTERGI_ICON,
        default_times=(),
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
        icon=WUTHERING_ICON,
        default_times=(),
        cleanup_commands=(
            (
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPTS / "Stop-Ok-App.ps1"),
                "-AppId",
                "wuthering",
            ),
        ),
    ),
    AppConfig(
        app_id="endfield",
        name="ok-终末地",
        project_dir=SRC_DIR / "ok-end-field",
        script=SCRIPTS / "Run-OkEndFieldDaily.ps1",
        workdir=ROOT,
        icon=ENDFIELD_ICON,
        default_times=(),
        requires_game_verification=False,
        cleanup_commands=(
            (
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPTS / "Stop-Ok-App.ps1"),
                "-AppId",
                "endfield",
            ),
        ),
    ),
    AppConfig(
        app_id="nte",
        name="ok-异环",
        project_dir=SRC_DIR / "ok-nte",
        script=SCRIPTS / "Run-OkNteDaily.ps1",
        workdir=ROOT,
        icon=NTE_ICON,
        default_times=(),
        requires_game_verification=False,
        cleanup_commands=(
            (
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPTS / "Stop-Ok-App.ps1"),
                "-AppId",
                "nte",
            ),
        ),
    ),
    AppConfig(
        app_id="starrail",
        name="SRA-崩铁",
        project_dir=SRC_DIR / "StarRailAssistant",
        script=SCRIPTS / "Run-StarRailAssistantDaily.ps1",
        workdir=ROOT,
        icon=STARRAIL_ICON,
        default_times=(),
        requires_game_verification=False,
        cleanup_commands=(
            (
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPTS / "Stop-Ok-App.ps1"),
                "-AppId",
                "starrail",
            ),
        ),
    ),
)

INSTALL_DIR_MARKERS = {
    "maa": ("MAA.exe", "maa-cli.exe"),
    "maa-gui": ("MAA.exe",),
    "bettergi": ("BetterGI.exe",),
}
INITIALIZATION_DIR_MARKERS = {
    "maa": ("MAA.exe",),
    "maa-gui": ("MAA.exe",),
}
GAME_PROCESS_NAMES = {
    "wuthering": "Client-Win64-Shipping.exe",
    "endfield": "Endfield.exe",
    "nte": "HTGame.exe",
    "starrail": "StarRail.exe",
}


def ensure_dirs() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    LOG_ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
    SCRIPTS.mkdir(parents=True, exist_ok=True)


def now_text() -> str:
    return datetime.now().strftime("%H:%M:%S")


def log_file_start_time(log_file: Path | None) -> datetime | None:
    if log_file is None:
        return None
    try:
        return datetime.strptime(log_file.name[:LOG_FILE_STAMP_LENGTH], LOG_FILE_STAMP_FORMAT)
    except ValueError:
        return None


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


def debug_bool(value: object, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in ("1", "true", "yes", "y", "on"):
            return True
        if normalized in ("0", "false", "no", "n", "off"):
            return False
        return default
    return bool(value)


def debug_times(value: object) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        if not value.strip():
            return []
        return validate_times(value)
    if isinstance(value, (list, tuple)):
        if not value:
            return []
        return validate_times(",".join(str(item) for item in value))
    raise ValueError("times 必须是字符串或数组")


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
    if app.requires_emulator_verification:
        app_settings["mumu_dir"] = ""
        app_settings["mumu_cli"] = ""
        app_settings["mumu_verified"] = False
    return app_settings


def default_submodule_update_settings() -> dict:
    return {
        "enabled": False,
        "times": [],
    }


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
            "submodule_update": default_submodule_update_settings(),
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
        if not isinstance(loaded.get("submodule_update"), dict):
            loaded["submodule_update"] = {}
        for key, value in default_submodule_update_settings().items():
            loaded["submodule_update"].setdefault(key, value)
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

    def submodule_update_enabled(self) -> bool:
        return bool(self.data["submodule_update"].get("enabled", False))

    def submodule_update_times(self) -> list[str]:
        times = self.data["submodule_update"].get("times")
        if isinstance(times, str):
            return [times]
        if not isinstance(times, (list, tuple)):
            return []
        return list(times)

    def update_submodule_schedule(self, enabled: bool, times: list[str]) -> None:
        current = self.data.setdefault("submodule_update", default_submodule_update_settings())
        current.update({"enabled": enabled, "times": times})
        self.save()

    def was_submodule_update_run(self, date: str, time_value: str) -> bool:
        return self._submodule_update_key(date, time_value) in self.data["last_runs"]

    def mark_submodule_update_run(self, date: str, time_value: str, reason: str) -> None:
        self.data["last_runs"][self._submodule_update_key(date, time_value)] = {
            "at": datetime.now().isoformat(timespec="seconds"),
            "reason": reason,
        }
        self._prune_runs()
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

    def mumu_verified(self, app: AppConfig) -> bool:
        return bool(self.data["apps"][app.app_id].get("mumu_verified", False))

    def mark_mumu_verified(self, app: AppConfig, mumu_dir: str, mumu_cli: str) -> None:
        app_settings = self.data["apps"].setdefault(app.app_id, {})
        app_settings["mumu_dir"] = mumu_dir
        app_settings["mumu_cli"] = mumu_cli
        app_settings["mumu_verified"] = True
        self.save()

    def clear_mumu_verified(self, app: AppConfig) -> None:
        app_settings = self.data["apps"].setdefault(app.app_id, {})
        app_settings["mumu_verified"] = False
        self.save()

    def configured_mumu_cli(self, app: AppConfig) -> str:
        if not app.requires_emulator_verification:
            return ""
        return self.data["apps"][app.app_id].get("mumu_cli", "")

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

    def _submodule_update_key(self, date: str, time_value: str) -> str:
        return f"submodule-update|{date}|{time_value}"

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
    def __init__(self, app: AppConfig, log_queue: queue.Queue[tuple[str, str]], settings: "Settings | None" = None):
        self.app = app
        self.log_queue = log_queue
        self.settings = settings
        self.process: subprocess.Popen[str] | None = None
        self.log_file: Path | None = None
        self.started_at: datetime | None = None
        self.start_reason: str | None = None
        self.stop_requested = False
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
            stamp = datetime.now().strftime(LOG_FILE_STAMP_FORMAT)
            self.log_file = LOG_DIR / f"{stamp}_{self.app.app_id}_{reason}.log"
            self.started_at = datetime.strptime(stamp, LOG_FILE_STAMP_FORMAT)
            self.start_reason = reason
            self.stop_requested = False
            command = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(self.app.script),
            ]

            if self.app.requires_game_verification and self.settings is not None:
                app_settings = self.settings.data["apps"].get(self.app.app_id, {})
                game_path = settings_path_value(app_settings.get("game_path"))
                if not (game_path and game_path.is_file()):
                    game_path = saved_game_path_from_project(self.app)
                if game_path and game_path.is_file():
                    command.extend(["-GameExe", str(game_path)])

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

    def stop(self, reason: str | None = None) -> None:
        with self.lock:
            process = self.process
            if process is None or process.poll() is not None:
                no_running = True
                already_stopping = False
            elif self.stop_requested:
                no_running = False
                already_stopping = True
            else:
                no_running = False
                already_stopping = False
                self.stop_requested = True

        if no_running:
            self.log("没有正在运行的任务")
            self._cleanup()
            return

        if already_stopping:
            if reason:
                self.log(f"{reason}，进程树已在退出中")
            else:
                self.log("进程树已在退出中")
            return

        if reason:
            self.log(reason)
        assert process is not None
        self.log(f"强制退出进程树 PID={process.pid}")
        threading.Thread(target=self._kill_tree, args=(process.pid,), daemon=True).start()

    def scheduled_timeout_elapsed(self, now: datetime) -> timedelta | None:
        with self.lock:
            process = self.process
            if (
                process is None
                or process.poll() is not None
                or self.start_reason != "scheduled"
                or self.stop_requested
            ):
                return None
            started_at = log_file_start_time(self.log_file) or self.started_at

        if started_at is None:
            return None

        elapsed = now - started_at
        if elapsed < SCHEDULED_RUN_TIMEOUT:
            return None
        return elapsed

    def snapshot(self, now: datetime) -> dict:
        with self.lock:
            process = self.process
            running = process is not None and process.poll() is None
            started_at = log_file_start_time(self.log_file) or self.started_at
            start_reason = self.start_reason
            stop_requested = self.stop_requested
            log_file = self.log_file
            pid = process.pid if process is not None else None

        elapsed_seconds = None
        timeout_remaining_seconds = None
        if running and started_at is not None:
            elapsed = now - started_at
            elapsed_seconds = max(0, int(elapsed.total_seconds()))
            if start_reason == "scheduled":
                timeout_remaining_seconds = max(
                    0,
                    int((SCHEDULED_RUN_TIMEOUT - elapsed).total_seconds()),
                )

        return {
            "running": running,
            "pid": pid,
            "start_reason": start_reason,
            "started_at": started_at.isoformat(timespec="seconds") if started_at else None,
            "elapsed_seconds": elapsed_seconds,
            "scheduled_timeout_remaining_seconds": timeout_remaining_seconds,
            "stop_requested": stop_requested,
            "log_file": str(log_file) if log_file is not None else None,
        }

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
            should_cleanup = (
                self.process is process
                and exit_code != 0
                and not self.stop_requested
                and bool(self.app.cleanup_commands)
            )
        if should_cleanup:
            self.log("任务失败，执行残留清理")
            self._cleanup()
        with self.lock:
            if self.process is process:
                self.process = None
                self.started_at = None
                self.start_reason = None
                self.stop_requested = False
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


class SubmoduleUpdateRunner:
    def __init__(self, log_queue: queue.Queue[tuple[str, str]]):
        self.log_queue = log_queue
        self.process: subprocess.Popen[str] | None = None
        self.started_at: datetime | None = None
        self.start_reason: str | None = None
        self.stop_requested = False
        self.lock = threading.Lock()

    @property
    def running(self) -> bool:
        with self.lock:
            return self.process is not None and self.process.poll() is None

    def start(self, reason: str) -> bool:
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                self.log("更新正在运行，忽略新的更新请求")
                return False

            self.started_at = datetime.now()
            self.start_reason = reason
            self.stop_requested = False
            command = [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPTS / "Update-InstalledSubmodules.ps1"),
                "-Root",
                str(ROOT),
                "-SkipRoot",
            ]
            self.log(f"启动更新: {' '.join(command)}")
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

    def stop(self, reason: str | None = None) -> None:
        with self.lock:
            process = self.process
            if process is None or process.poll() is not None:
                return
            if self.stop_requested:
                return
            self.stop_requested = True

        if reason:
            self.log(reason)
        assert process is not None
        self.log(f"强制退出更新进程树 PID={process.pid}")
        result = subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
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

    def scheduled_timeout_elapsed(self, now: datetime) -> timedelta | None:
        with self.lock:
            process = self.process
            if (
                process is None
                or process.poll() is not None
                or self.start_reason != "scheduled"
                or self.stop_requested
                or self.started_at is None
            ):
                return None
            started_at = self.started_at

        elapsed = now - started_at
        if elapsed < SCHEDULED_RUN_TIMEOUT:
            return None
        return elapsed

    def snapshot(self, now: datetime) -> dict:
        with self.lock:
            process = self.process
            running = process is not None and process.poll() is None
            started_at = self.started_at
            start_reason = self.start_reason
            stop_requested = self.stop_requested
            pid = process.pid if process is not None else None

        elapsed_seconds = None
        if running and started_at is not None:
            elapsed_seconds = max(0, int((now - started_at).total_seconds()))

        return {
            "running": running,
            "pid": pid,
            "start_reason": start_reason,
            "started_at": started_at.isoformat(timespec="seconds") if started_at else None,
            "elapsed_seconds": elapsed_seconds,
            "stop_requested": stop_requested,
        }

    def log(self, message: str) -> None:
        self.log_queue.put(("update", message))

    def _read_output(self) -> None:
        process = self.process
        if process is None:
            return

        assert process.stdout is not None
        for line in process.stdout:
            self.log(line.rstrip())

        exit_code = process.wait()
        self.log(f"更新结束，退出码: {exit_code}")
        with self.lock:
            if self.process is process:
                self.process = None
                self.started_at = None
                self.start_reason = None
                self.stop_requested = False
        self.log_queue.put(("update", f"__UPDATE_EXIT__:{exit_code}"))


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
        self.verify_button = ttk.Button(
            actions,
            text="确认游戏",
            command=self.verify_required,
        )
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
        if (
            self.app.requires_emulator_verification
            and not self.settings.mumu_verified(self.app)
        ):
            if not self.scheduler.ensure_emulator_verified(self.app):
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

    def set_install_progress(self, message: str) -> None:
        if self.installer.running:
            self.status_var.set(f"安装中 | {message}")

    def verify_required(self) -> None:
        if (
            self.app.requires_game_verification
            and not self.settings.game_verified(self.app)
        ):
            self.scheduler.ensure_game_verified(self.app, force_prompt=True)
        elif (
            self.app.requires_emulator_verification
            and not self.settings.mumu_verified(self.app)
        ):
            self.scheduler.ensure_emulator_verified(self.app, force_prompt=True)
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
            self.verify_button.configure(text="确认游戏")
            self.verify_button.configure(state="normal")
            return

        self.verify_button.grid_remove()
        if (
            self.app.requires_emulator_verification
            and not self.settings.mumu_verified(self.app)
        ):
            self.status_var.set("已安装 | 未确认模拟器位置 | 打开MuMu后点击确认")
            self.start_button.grid_remove()
            self.stop_button.grid_remove()
            self.schedule_button.grid_remove()
            self.verify_button.grid()
            self.verify_button.configure(text="确认模拟器")
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


class SubmoduleUpdateDialog:
    def __init__(self, root: Tk, settings: Settings, on_save, on_run_now):
        self.settings = settings
        self.on_save = on_save
        self.on_run_now = on_run_now
        self.window = Toplevel(root)
        self.window.title("子项目更新计划")
        self.window.resizable(False, False)
        self.window.transient(root)
        self.window.grab_set()

        panel = Frame(self.window, padx=18, pady=16, bg="#f7f7f4")
        panel.pack(fill=BOTH, expand=True)

        self.enabled = BooleanVar(value=settings.submodule_update_enabled())
        Checkbutton(
            panel,
            text="启用定时更新",
            variable=self.enabled,
            bg="#f7f7f4",
            font=("Microsoft YaHei UI", 11),
        ).pack(anchor="w")

        Label(
            panel,
            text="时间，多个用逗号分隔，例如 03:30",
            bg="#f7f7f4",
            fg="#555555",
            font=("Microsoft YaHei UI", 10),
        ).pack(anchor="w", pady=(12, 4))

        self.times = StringVar(value=",".join(settings.submodule_update_times()))
        Entry(panel, textvariable=self.times, width=34, font=("Consolas", 12)).pack(fill=X)

        buttons = Frame(panel, bg="#f7f7f4")
        buttons.pack(anchor="e", pady=(16, 0))
        ttk.Button(buttons, text="立即更新", command=self.run_now).pack(side=LEFT, padx=6)
        ttk.Button(buttons, text="取消", command=self.window.destroy).pack(side=LEFT, padx=6)
        ttk.Button(buttons, text="保存", command=self.save).pack(side=LEFT)

    def run_now(self) -> None:
        self.on_run_now()
        self.window.destroy()

    def save(self) -> None:
        raw_times = self.times.get()
        if self.enabled.get() or raw_times.strip():
            try:
                times = validate_times(raw_times)
            except ValueError as exc:
                messagebox.showerror("更新计划错误", str(exc), parent=self.window)
                return
        else:
            times = []

        self.settings.update_submodule_schedule(self.enabled.get(), times)
        self.on_save()
        self.window.destroy()


class DailyGui:
    def __init__(self):
        ensure_dirs()
        self.settings = Settings(SETTINGS_PATH)
        self.settings.save()
        self.log_queue: queue.Queue[tuple[str, str]] = queue.Queue()
        self.installers = {app.app_id: AppInstaller(app, self.log_queue) for app in APPS}
        self.runners = {app.app_id: AppRunner(app, self.log_queue, self.settings) for app in APPS}
        self.update_runner = SubmoduleUpdateRunner(self.log_queue)
        self.rows: dict[str, TaskRow] = {}
        self.images: list[ImageTk.PhotoImage] = []
        self.window_icon: ImageTk.PhotoImage | None = None
        self.pending_scheduled: list[AppConfig] = []
        self.debug_command_position = self._initial_debug_command_position()
        self.debug_status_written_at: datetime | None = None

        self.root = Tk()
        self.root.title("DAG二游日常")
        self.root.geometry("1300x720")
        self.root.minsize(1300, 400)
        self.root.configure(bg="#f7f7f4")
        self.window_icon = load_window_icon()
        if self.window_icon is not None:
            self.root.iconphoto(True, self.window_icon)
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

        left_canvas = Canvas(left, bg="#f7f7f4", highlightthickness=0)
        left_scrollbar = Scrollbar(left, orient=VERTICAL, command=left_canvas.yview)
        left_scrollbar.pack(side=RIGHT, fill=Y)
        left_canvas.pack(side=LEFT, fill=BOTH, expand=True)
        left_canvas.configure(yscrollcommand=left_scrollbar.set)

        left_inner = Frame(left_canvas, bg="#f7f7f4")
        left_inner_id = left_canvas.create_window((0, 0), window=left_inner, anchor="nw")

        def _on_canvas_configure(event: "Event[Canvas]") -> None:
            left_canvas.itemconfig(left_inner_id, width=event.width)

        left_canvas.bind("<Configure>", _on_canvas_configure)

        def _on_inner_configure(event: "Event[Frame]") -> None:
            left_canvas.configure(scrollregion=left_canvas.bbox("all"))

        left_inner.bind("<Configure>", _on_inner_configure)

        def _on_mousewheel(event: "Event[Canvas]") -> None:
            left_canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

        left_canvas.bind("<Enter>", lambda _e: left_canvas.bind_all("<MouseWheel>", _on_mousewheel))
        left_canvas.bind("<Leave>", lambda _e: left_canvas.unbind_all("<MouseWheel>"))

        right = Frame(outer, bg="#f7f7f4", highlightbackground="#8a8a8a", highlightthickness=1)
        right.pack(side=RIGHT, fill=Y)

        for app in APPS:
            row = TaskRow(
                left_inner,
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
        log_scrollbar = Scrollbar(log_container)
        log_scrollbar.pack(side=RIGHT, fill=Y)
        self.log_text = Text(
            log_container,
            width=44,
            wrap="word",
            state="disabled",
            font=("Consolas", 10),
            bg="#fcfcfa",
            fg="#1f1f1f",
            yscrollcommand=log_scrollbar.set,
        )
        self.log_text.pack(side=LEFT, fill=BOTH, expand=True)
        log_scrollbar.config(command=self.log_text.yview)

        self.log(
            "system",
            f"GUI 已启动。定时检查每 10 秒执行一次，定时任务超过 {SCHEDULED_RUN_TIMEOUT_MINUTES} 分钟会自动强制退出。",
        )
        self.log("system", f"远程调试命令文件: {DEBUG_COMMANDS_PATH}")
        self.log("system", f"远程调试状态文件: {DEBUG_STATUS_PATH}")
        self.log("system", "本项目为本地开源软件，如果你付费购买了本软件赶紧退款！")

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
        update_menu = Menu(menu, tearoff=False)
        update_menu.add_command(label="立即更新 src 子项目", command=self.start_submodule_update)
        update_menu.add_command(label="定时设置", command=self.configure_submodule_update)
        menu.add_cascade(label="更新", menu=update_menu)
        menu.add_command(label="保存今天日志", command=self.save_today_logs)
        menu.add_command(label="清空日志", command=self.clear_logs)
        menu.add_command(label="退出", command=self.on_close)
        self.root.config(menu=menu)

    def configure_submodule_update(self) -> None:
        SubmoduleUpdateDialog(
            self.root,
            self.settings,
            self.log_submodule_update_schedule,
            self.start_submodule_update,
        )

    def log_submodule_update_schedule(self) -> None:
        enabled = self.settings.submodule_update_enabled()
        times = self.settings.submodule_update_times()
        schedule = "启用" if enabled else "禁用"
        display_times = ", ".join(times) if times else "未设置"
        self.log("update", f"定时更新已保存: {schedule} | {display_times}")
        self.write_debug_status("submodule_update_schedule", force=True)

    def any_app_activity_running(self) -> bool:
        return any(runner.running for runner in self.runners.values()) or any(
            installer.running for installer in self.installers.values()
        )

    def start_submodule_update(self, reason: str = "manual") -> bool:
        if self.update_runner.running:
            self.log("update", "更新正在运行")
            return False

        if self.any_app_activity_running() or self.pending_scheduled:
            if reason == "scheduled":
                return False
            if not messagebox.askyesno(
                "已有任务运行",
                "已有任务正在运行或排队。继续更新可能改动正在使用的源码，是否仍要更新？",
                parent=self.root,
            ):
                return False

        started = self.update_runner.start(reason)
        if started:
            self.write_debug_status("submodule_update_start", force=True)
        return started

    def run(self) -> None:
        self.root.after(250, self.process_logs)
        self.root.after(1000, self.check_schedule)
        self.root.after(1000, self.poll_debug_commands)
        self.write_debug_status("startup", force=True)
        self.root.mainloop()

    def log(self, app_id: str, message: str) -> None:
        self.log_queue.put((app_id, message))

    def app_by_id(self, app_id: str) -> AppConfig | None:
        return next((app for app in APPS if app.app_id == app_id), None)

    def _initial_debug_command_position(self) -> int:
        try:
            return DEBUG_COMMANDS_PATH.stat().st_size
        except OSError:
            return 0

    def poll_debug_commands(self) -> None:
        try:
            for command in self.read_debug_commands():
                self.handle_debug_command(command)
            self.write_debug_status("heartbeat")
        except Exception as exc:
            self.log("system", f"远程调试轮询失败: {exc}")
            try:
                self.write_debug_status("poll_error", force=True)
            except Exception:
                pass
        self.root.after(DEBUG_POLL_MS, self.poll_debug_commands)

    def read_debug_commands(self) -> list[dict]:
        if not DEBUG_COMMANDS_PATH.exists():
            return []

        try:
            current_size = DEBUG_COMMANDS_PATH.stat().st_size
            if current_size < self.debug_command_position:
                self.debug_command_position = 0

            with DEBUG_COMMANDS_PATH.open("r", encoding="utf-8") as handle:
                handle.seek(self.debug_command_position)
                lines = handle.readlines()
                self.debug_command_position = handle.tell()
        except OSError as exc:
            self.log("system", f"读取远程调试命令失败: {exc}")
            return []

        commands: list[dict] = []
        for line in lines:
            text = line.strip()
            if not text:
                continue
            try:
                command = json.loads(text)
            except json.JSONDecodeError as exc:
                self.log("system", f"远程调试命令 JSON 错误: {exc}: {text[:120]}")
                continue
            if not isinstance(command, dict):
                self.log("system", f"远程调试命令必须是 JSON 对象: {text[:120]}")
                continue
            commands.append(command)
        return commands

    def handle_debug_command(self, payload: dict) -> None:
        command = str(payload.get("command") or payload.get("action") or "").strip().lower()
        command_id = str(payload.get("id") or "").strip()
        label = f"{command} ({command_id})" if command_id else command
        if not command:
            self.log("system", "远程调试命令缺少 command")
            return

        self.log("system", f"收到远程调试命令: {label}")
        try:
            if command == "status":
                self.write_debug_status("command:status", force=True)
            elif command == "stop":
                app = self.debug_command_app(payload)
                if app is not None:
                    self.runners[app.app_id].stop("远程调试命令请求强制退出")
            elif command == "stop_all":
                for runner in self.runners.values():
                    runner.stop("远程调试命令请求强制退出全部")
                self.update_runner.stop("远程调试命令请求强制退出全部")
            elif command == "stop_update":
                self.update_runner.stop("远程调试命令请求强制退出更新")
            elif command == "start":
                app = self.debug_command_app(payload)
                if app is not None:
                    reason = str(payload.get("reason") or "debug").strip() or "debug"
                    self.start_app_unattended(
                        app,
                        reason=reason,
                        force=debug_bool(payload.get("force"), default=False),
                    )
            elif command == "queue":
                app = self.debug_command_app(payload)
                if app is not None and self.app_ready_for_unattended_start(app):
                    time_value = str(payload.get("time") or "remote").strip() or "remote"
                    self.queue_scheduled(app, time_value)
                    self.start_next_scheduled()
            elif command == "clear_queue":
                count = len(self.pending_scheduled)
                self.pending_scheduled.clear()
                self.log("system", f"远程调试已清空定时队列，移除 {count} 个待执行任务")
            elif command == "set_schedule":
                app = self.debug_command_app(payload)
                if app is not None:
                    enabled = debug_bool(
                        payload.get("enabled"),
                        default=self.settings.app_enabled(app),
                    )
                    times = (
                        debug_times(payload.get("times"))
                        if "times" in payload
                        else self.settings.app_times(app)
                    )
                    self.settings.update_app(app, enabled, times)
                    self.rows[app.app_id].refresh()
                    schedule = "启用" if enabled else "禁用"
                    display_times = ", ".join(times) if times else "未设置"
                    self.log(app.app_id, f"远程调试已更新定时: {schedule} | {display_times}")
            elif command == "run_update":
                self.start_submodule_update(reason="debug")
            elif command == "set_update_schedule":
                enabled = debug_bool(
                    payload.get("enabled"),
                    default=self.settings.submodule_update_enabled(),
                )
                times = (
                    debug_times(payload.get("times"))
                    if "times" in payload
                    else self.settings.submodule_update_times()
                )
                self.settings.update_submodule_schedule(enabled, times)
                schedule = "启用" if enabled else "禁用"
                display_times = ", ".join(times) if times else "未设置"
                self.log("update", f"远程调试已更新定时: {schedule} | {display_times}")
            elif command == "reload_settings":
                self.settings.reload()
                self.refresh_rows()
                self.log("system", "远程调试已重新加载 Setting.json")
            elif command == "exit":
                force = debug_bool(payload.get("force"), default=False)
                if force:
                    for runner in self.runners.values():
                        runner.stop("远程调试命令请求退出 GUI")
                    self.update_runner.stop("远程调试命令请求退出 GUI")
                self.log("system", "远程调试命令请求退出 GUI")
                self.root.after(1000 if force else 100, self.root.destroy)
            else:
                self.log("system", f"未知远程调试命令: {command}")
        except Exception as exc:
            self.log("system", f"远程调试命令失败 {label}: {exc}")
        finally:
            self.write_debug_status(f"command:{command}", force=True)

    def debug_command_app(self, payload: dict) -> AppConfig | None:
        app_id = str(payload.get("app_id") or payload.get("app") or "").strip()
        if not app_id:
            self.log("system", "远程调试命令缺少 app_id")
            return None

        app = self.app_by_id(app_id)
        if app is None:
            app_ids = ", ".join(app.app_id for app in APPS)
            self.log("system", f"未知 app_id: {app_id}，可用值: {app_ids}")
            return None
        return app

    def app_ready_for_unattended_start(self, app: AppConfig) -> bool:
        if not self.settings.app_installed(app):
            self.log(app.app_id, "远程调试启动被跳过：未安装")
            return False
        if app.requires_game_verification and not self.settings.game_verified(app):
            self.log(app.app_id, "远程调试启动被跳过：未确认游戏位置")
            return False
        if app.requires_emulator_verification and not self.settings.mumu_verified(app):
            self.log(app.app_id, "远程调试启动被跳过：未确认模拟器位置")
            return False
        return True

    def start_app_unattended(self, app: AppConfig, reason: str, force: bool) -> None:
        if not self.app_ready_for_unattended_start(app):
            return
        if not force and self.any_running(except_app_id=app.app_id):
            self.log(app.app_id, "远程调试启动被跳过：已有其他任务运行")
            return
        if self.runners[app.app_id].start(reason):
            self.refresh_rows()

    def write_debug_status(self, reason: str, force: bool = False) -> None:
        now = datetime.now()
        if not force and self.debug_status_written_at is not None:
            status_age = now - self.debug_status_written_at
            if status_age < timedelta(seconds=DEBUG_STATUS_REFRESH_SECONDS):
                return

        ensure_dirs()
        status = {
            "at": now.isoformat(timespec="seconds"),
            "reason": reason,
            "command_file": str(DEBUG_COMMANDS_PATH),
            "command_file_position": self.debug_command_position,
            "pending_scheduled": [app.app_id for app in self.pending_scheduled],
            "submodule_update": {
                "enabled": self.settings.submodule_update_enabled(),
                "times": self.settings.submodule_update_times(),
                **self.update_runner.snapshot(now),
            },
            "apps": {},
        }

        for app in APPS:
            app_status = self.runners[app.app_id].snapshot(now)
            app_status.update(
                {
                    "name": app.name,
                    "installed": self.settings.app_installed(app),
                    "enabled": self.settings.app_enabled(app),
                    "times": self.settings.app_times(app),
                    "game_verified": True
                    if not app.requires_game_verification
                    else self.settings.game_verified(app),
                    "mumu_verified": True
                    if not app.requires_emulator_verification
                    else self.settings.mumu_verified(app),
                }
            )
            status["apps"][app.app_id] = app_status

        temp_path = DEBUG_STATUS_PATH.with_suffix(".json.tmp")
        temp_path.write_text(
            json.dumps(status, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        temp_path.replace(DEBUG_STATUS_PATH)
        self.debug_status_written_at = now

    def ensure_game_verified(self, app: AppConfig, force_prompt: bool = False) -> bool:
        if not app.requires_game_verification:
            return True
        if self.settings.game_verified(app) and not force_prompt:
            return True
        if not self.settings.app_installed(app):
            return False

        if not messagebox.askokcancel(
            "确认游戏位置",
            f"请先打开 {app.name.replace('ok-', '')}游戏窗口。\n\n"
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

    def ensure_emulator_verified(self, app: AppConfig, force_prompt: bool = False) -> bool:
        if not app.requires_emulator_verification:
            return True
        if self.settings.mumu_verified(app) and not force_prompt:
            return True
        if not self.settings.app_installed(app):
            return False

        msg = (
            "请先打开 MuMu Player 12 模拟器。\n\n"
            "打开 MuMu 后，点击【确定】开始检测 mumu-cli 位置。\n"
            "如果还没准备好，可以取消，之后再点【确认模拟器】。"
        )
        if not messagebox.askokcancel(
            "确认模拟器位置",
            msg,
            parent=self.root,
        ):
            self.log(app.app_id, "已取消模拟器位置确认")
            return False

        command = [
            POWERSHELL,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SCRIPTS / "Verify-MuMu.ps1"),
        ]
        self.log(app.app_id, f"确认模拟器位置: {' '.join(command)}")
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
            self.log(app.app_id, "确认模拟器位置超时")
            messagebox.showerror(
                "确认失败",
                "没有在限定时间内确认模拟器位置。",
                parent=self.root,
            )
            return False

        output = result.stdout.strip()
        if output:
            for line in output.splitlines():
                self.log(app.app_id, line)

        if result.returncode == 0:
            self.settings.reload()
            self.refresh_rows()
            messagebox.showinfo(
                "确认完成",
                "模拟器位置已确认，可以正式运行 MAA-cli。",
                parent=self.root,
            )
            return True

        messagebox.showerror(
            "确认失败",
            "没有找到 MuMu 模拟器的运行进程。\n\n"
            "请确认已经打开 MuMu Player 12 模拟器窗口，然后再试一次。",
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

            if message.startswith("__UPDATE_EXIT__:"):
                self.write_debug_status("submodule_update_exit", force=True)
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

            app_name = (
                SUBMODULE_UPDATE_LABEL
                if app_id == "update"
                else next((app.name for app in APPS if app.app_id == app_id), app_id)
            )
            if message.startswith(("Download progress:", "Download completed:")):
                row = self.rows.get(app_id)
                if row is not None:
                    row.set_install_progress(message)
            self.log_text.configure(state="normal")
            self.log_text.insert(END, f"[{now_text()}] [{app_name}] {message}\n")
            self.log_text.see(END)
            self.log_text.configure(state="disabled")

        self.root.after(250, self.process_logs)

    def check_schedule(self) -> None:
        now = datetime.now()
        today = now.strftime("%Y-%m-%d")
        self.check_log_archive(now)
        self.check_scheduled_timeouts(now)
        for app in APPS:
            if not self.settings.app_installed(app):
                continue
            if app.requires_game_verification and not self.settings.game_verified(app):
                continue
            if app.requires_emulator_verification and not self.settings.mumu_verified(app):
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
        self.check_submodule_update_schedule(now, today)
        self.root.after(10_000, self.check_schedule)

    def check_submodule_update_schedule(self, now: datetime, today: str) -> None:
        if not self.settings.submodule_update_enabled():
            return
        if self.update_runner.running or self.any_app_activity_running() or self.pending_scheduled:
            return

        for time_value in self.settings.submodule_update_times():
            hour, minute = (int(part) for part in time_value.split(":"))
            scheduled = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if now < scheduled or now > scheduled + timedelta(minutes=CATCH_UP_MINUTES):
                continue
            if self.settings.was_submodule_update_run(today, time_value):
                continue
            if self.start_submodule_update(reason="scheduled"):
                self.settings.mark_submodule_update_run(today, time_value, "scheduled")
                break

    def check_scheduled_timeouts(self, now: datetime) -> None:
        for runner in self.runners.values():
            elapsed = runner.scheduled_timeout_elapsed(now)
            if elapsed is None:
                continue
            minutes = int(elapsed.total_seconds() // 60)
            runner.stop(
                f"定时任务已运行 {minutes} 分钟，超过 {SCHEDULED_RUN_TIMEOUT_MINUTES} 分钟，自动强制退出"
            )
        elapsed = self.update_runner.scheduled_timeout_elapsed(now)
        if elapsed is not None:
            minutes = int(elapsed.total_seconds() // 60)
            self.update_runner.stop(
                f"定时更新已运行 {minutes} 分钟，超过 {SCHEDULED_RUN_TIMEOUT_MINUTES} 分钟，自动强制退出"
            )

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
        if self.update_runner.running:
            return True
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
        self.update_runner.stop("强制退出全部")

    def clear_logs(self) -> None:
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", END)
        self.log_text.configure(state="disabled")

    def current_log_text(self) -> str:
        return self.log_text.get("1.0", END).strip()

    def on_close(self) -> None:
        running = [app.name for app in APPS if self.runners[app.app_id].running]
        if self.update_runner.running:
            running.append(SUBMODULE_UPDATE_LABEL)
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


def load_window_icon() -> ImageTk.PhotoImage | None:
    try:
        image = Image.open(APP_ICON).convert("RGBA")
    except Exception:
        return None

    image.thumbnail((64, 64), Image.LANCZOS)
    return ImageTk.PhotoImage(image)


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
    update_times = settings.submodule_update_times()
    update_display = ",".join(update_times) if update_times else "未设置"
    print(
        f"submodule_update: enabled={str(settings.submodule_update_enabled()).lower()} "
        f"times={update_display}"
    )
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

    instance_lock = SingleInstanceLock("DagDailyAnimeGames.LocalDailyGui")
    if instance_lock.already_exists:
        return 0

    try:
        DailyGui().run()
        return 0
    finally:
        instance_lock.close()


if __name__ == "__main__":
    raise SystemExit(main())
