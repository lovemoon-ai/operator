from __future__ import annotations

import json
import os
import platform
import stat
from pathlib import Path
from typing import Any


def config_dir() -> Path:
    system = platform.system().lower()
    if system == "darwin":
        return Path.home() / "Library" / "Application Support" / "Operator Collector"
    if system == "windows":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
        return base / "Operator Collector"
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "operator-collector"


def config_path() -> Path:
    override = os.environ.get("OPERATOR_COLLECTOR_CONFIG")
    return Path(override).expanduser().resolve() if override else config_dir() / "config.json"


def load_config() -> dict[str, Any]:
    path = config_path()
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Collector config must be a JSON object: {path}")
    return value


def save_config(value: dict[str, Any]) -> None:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    try:
        temporary.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass
    temporary.replace(path)


def default_server_url() -> str:
    return os.environ.get("OPERATOR_SERVER_URL", "http://127.0.0.1:6153").rstrip("/")
