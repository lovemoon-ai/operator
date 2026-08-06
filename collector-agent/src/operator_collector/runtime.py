from __future__ import annotations

import os
import platform
import shutil
import sys
from pathlib import Path
from typing import Any


FIXED_MODELSCOPE_REPO_ID = "chenghy666/test"


def find_tool(config: dict[str, Any], name: str) -> str:
    config_key = f"{name}_path"
    configured = str(config.get(config_key) or "").strip()
    if configured:
        return configured

    executable = f"{name}.exe" if platform.system().lower() == "windows" else name
    relative = (
        Path("tools") / "platform-tools" / executable
        if name == "adb"
        else Path("tools") / "ffmpeg" / executable
    )
    for root in _install_roots():
        candidate = root / relative
        if candidate.is_file():
            return str(candidate)
    return shutil.which(name) or ""


def modelscope_token(config: dict[str, Any]) -> str:
    # The Station provisions this into the Agent's private local config after
    # authenticated pairing. It is deliberately never part of remote_config,
    # job payloads, browser APIs or subprocess arguments.
    return str(
        config.get("_modelscope_token")
        or os.environ.get("OPERATOR_MODELSCOPE_TOKEN")
        or ""
    ).strip()


def _install_roots() -> list[Path]:
    roots: list[Path] = []
    override = os.environ.get("OPERATOR_COLLECTOR_HOME")
    if override:
        roots.append(Path(override).expanduser())

    system = platform.system().lower()
    if system == "windows":
        roots.append(Path(sys.executable).resolve().parent)
    elif system == "darwin":
        roots.append(Path(sys.executable).resolve().parent.parent)
        roots.extend([
            Path("/usr/local/lib/operator-collector"),
            Path("/opt/operator-collector"),
        ])
    else:
        roots.extend([
            Path("/usr/lib/operator-collector"),
            Path("/usr/local/lib/operator-collector"),
        ])

    # Source checkout fallback for tests and developer runs.
    roots.append(Path(__file__).resolve().parents[2])
    unique: list[Path] = []
    for root in roots:
        resolved = root.resolve()
        if resolved not in unique:
            unique.append(resolved)
    return unique
