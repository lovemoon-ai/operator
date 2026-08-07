from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import threading
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from .runtime import FIXED_MODELSCOPE_REPO_ID, find_tool, modelscope_token


Progress = Callable[..., None]
DEFAULT_QUEST_ROOT = "/sdcard/DCIM/SpatialMP4"
LEGACY_QUEST_ROOT = "/sdcard/Movies/SpatialMP4"
SESSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_MODELSCOPE_STATE_CACHE: tuple[str, float, str] = ("", 0.0, "not found")


@dataclass
class JobContext:
    config: dict[str, Any]
    reporter: Progress

    def progress(
        self,
        value: float,
        message: str,
        metrics: dict[str, Any] | None = None,
    ) -> None:
        if metrics is None:
            self.reporter(value, message)
        else:
            self.reporter(value, message, metrics)

    @property
    def data_root(self) -> Path:
        value = str(self.config.get("data_root") or "").strip()
        if not value:
            raise RuntimeError("Local data directory is not configured in the web UI")
        return Path(value).expanduser().resolve()

    @property
    def fixture_root(self) -> Path | None:
        value = str(self.config.get("fixture_root") or "").strip()
        return Path(value).expanduser().resolve() if value else None

    @property
    def local_source_root(self) -> Path:
        value = str(
            self.config.get("local_source_root")
            or self.config.get("fixture_root")
            or self.config.get("data_root")
            or ""
        ).strip()
        if not value:
            raise RuntimeError("请先在网页中设置本地数据集目录")
        root = Path(value).expanduser().resolve()
        if not root.is_dir():
            raise RuntimeError(f"本地数据集目录不存在: {root}")
        return root

    @property
    def quest_root(self) -> str:
        return self.quest_roots[0]

    @property
    def quest_roots(self) -> list[str]:
        configured = str(self.config.get("quest_root") or "").strip()
        candidates = [configured, DEFAULT_QUEST_ROOT, LEGACY_QUEST_ROOT]
        roots: list[str] = []
        for candidate in candidates:
            if not candidate:
                continue
            value = _validate_quest_root(candidate)
            if value not in roots:
                roots.append(value)
        return roots

    @property
    def adb(self) -> str:
        found = find_tool(self.config, "adb")
        if not found:
            raise RuntimeError("adb was not found in the Agent package or system PATH")
        return found


def _validate_quest_root(value: str) -> str:
    value = value.strip()
    if not value.startswith("/sdcard/") and not value.startswith("/storage/emulated/0/"):
        raise RuntimeError("Quest root must be under /sdcard or /storage/emulated/0")
    if any(part in {"", ".", ".."} for part in value.split("/")[1:]):
        raise RuntimeError("Quest root contains an unsafe path component")
    return value.rstrip("/")


class _UploadProgressBar:
    def __init__(
        self,
        tracker: "_UploadProgressTracker",
        iterable: Any,
        total: int,
        unit: str,
        description: str,
    ) -> None:
        self._tracker = tracker
        self._iterable = iterable
        self._total = max(0, int(total or 0))
        self._is_bytes = unit == "B" and self._total > 0
        self._description = description or f"file-{id(self)}"
        self._current = 0

    def __enter__(self) -> "_UploadProgressBar":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()

    def __iter__(self):
        return iter(self._iterable or ())

    def update(self, amount: int = 1) -> None:
        if not self._is_bytes:
            return
        self._current = min(self._total, self._current + max(0, int(amount)))
        self._tracker.update(self._description, self._current, self._total)

    def close(self) -> None:
        if self._is_bytes and self._current:
            self._tracker.update(self._description, self._current, self._total, force=True)


class _UploadProgressTracker:
    """Aggregate byte progress from ModelScope's parallel upload streams."""

    def __init__(
        self,
        context: JobContext,
        total_bytes: int,
        file_count: int,
        workers: int,
    ) -> None:
        self._context = context
        self.total_bytes = max(1, total_bytes)
        self.file_count = file_count
        self.workers = workers
        self._started = time.monotonic()
        self._last_reported = 0.0
        self._files: dict[str, int] = {}
        self._lock = threading.Lock()

    def tqdm(self, iterable: Any = None, *args: Any, **kwargs: Any) -> _UploadProgressBar:
        return _UploadProgressBar(
            self,
            iterable,
            int(kwargs.get("total") or 0),
            str(kwargs.get("unit") or ""),
            str(kwargs.get("desc") or ""),
        )

    def update(
        self,
        key: str,
        current: int,
        _file_total: int,
        *,
        force: bool = False,
    ) -> None:
        now = time.monotonic()
        with self._lock:
            self._files[key] = max(self._files.get(key, 0), current)
            transferred = min(self.total_bytes, sum(self._files.values()))
            if not force and now - self._last_reported < 0.8:
                return
            self._last_reported = now

        elapsed = max(0.001, now - self._started)
        speed = transferred / elapsed
        remaining = max(0, self.total_bytes - transferred)
        eta = remaining / speed if speed > 0 else 0.0
        ratio = min(1.0, transferred / self.total_bytes)
        progress = 0.05 + ratio * 0.92
        message = (
            f"正在上传 {_format_bytes(transferred)} / {_format_bytes(self.total_bytes)}"
            f" · {ratio * 100:.1f}% · {_format_bytes(speed)}/s"
        )
        if eta > 0:
            message += f" · 预计剩余 {_format_duration(eta)}"
        self._context.progress(
            progress,
            message,
            {
                "phase": "uploading",
                "transferredBytes": transferred,
                "totalBytes": self.total_bytes,
                "bytesPerSecond": round(speed),
                "etaSeconds": round(eta),
                "filesTotal": self.file_count,
                "workers": self.workers,
                "resumable": True,
            },
        )

    def summary(self) -> dict[str, int | float]:
        elapsed = max(0.001, time.monotonic() - self._started)
        return {
            "total_bytes": self.total_bytes,
            "duration_seconds": round(elapsed, 3),
            "average_bytes_per_second": round(self.total_bytes / elapsed),
        }


def _format_bytes(value: float) -> str:
    units = ("B", "KB", "MB", "GB", "TB")
    amount = max(0.0, float(value))
    unit = 0
    while amount >= 1024 and unit < len(units) - 1:
        amount /= 1024
        unit += 1
    digits = 0 if unit == 0 else 1
    return f"{amount:.{digits}f} {units[unit]}"


def _format_duration(seconds: float) -> str:
    remaining = max(0, int(seconds))
    if remaining < 60:
        return f"{remaining} 秒"
    minutes, seconds = divmod(remaining, 60)
    if minutes < 60:
        return f"{minutes} 分 {seconds} 秒"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} 小时 {minutes} 分"


def run_job(kind: str, payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    handlers = {
        "scan": scan,
        "start_ego": start_ego,
        "import": import_session,
        "label": label_item,
        "upload": upload_item,
        "preview": preview_item,
        "delete_local": delete_local_item,
        "delete_quest": delete_quest_session,
    }
    handler = handlers.get(kind)
    if not handler:
        raise RuntimeError(f"Unsupported job kind: {kind}")
    return handler(payload, context)


def workstation_state(config: dict[str, Any]) -> dict[str, Any]:
    data_root_value = str(config.get("data_root") or "").strip()
    data_root = Path(data_root_value).expanduser() if data_root_value else None
    free_bytes = 0
    if data_root:
        probe = data_root if data_root.exists() else next(
            (parent for parent in data_root.parents if parent.exists()), Path.home()
        )
        try:
            free_bytes = shutil.disk_usage(probe).free
        except OSError:
            pass

    fixture = str(config.get("fixture_root") or "").strip()
    adb_state = "fixture" if fixture else "not found"
    quest_state = "fixture" if fixture else "not connected"
    if not fixture:
        adb = find_tool(config, "adb")
        if adb:
            adb_state = "ready"
            try:
                output = _run([adb, "devices"], timeout=10).stdout
                devices = [
                    line.split()[0]
                    for line in output.splitlines()[1:]
                    if len(line.split()) >= 2 and line.split()[1] == "device"
                ]
                quest_state = devices[0] if len(devices) == 1 else (
                    "multiple devices" if len(devices) > 1 else "not connected"
                )
            except Exception as error:  # state reporting must not crash the service
                adb_state = f"error: {error}"

    modelscope = _modelscope_state(config)

    return {
        "adb": adb_state,
        "quest": quest_state,
        "ffmpeg": "ready" if find_tool(config, "ffmpeg") else "not found",
        "modelscope": modelscope,
        "python": "ready",
        "pythonVersion": platform.python_version(),
        "modelscopeRepo": FIXED_MODELSCOPE_REPO_ID,
        "dataRoot": str(data_root.resolve()) if data_root else "",
        "freeBytes": free_bytes,
        "platform": platform.platform(),
    }


def _modelscope_state(config: dict[str, Any]) -> str:
    global _MODELSCOPE_STATE_CACHE
    token = modelscope_token(config)
    if not token:
        _MODELSCOPE_STATE_CACHE = ("", 0.0, "not found")
        return "not found"
    cache_key = hashlib.sha256(token.encode("utf-8")).hexdigest()
    cached_key, expires_at, cached_state = _MODELSCOPE_STATE_CACHE
    now = time.monotonic()
    if cached_key == cache_key and now < expires_at:
        return cached_state
    try:
        from modelscope_hub import HubApi

        HubApi(token=token).whoami()
        state = "authenticated"
    except Exception:
        state = "not authenticated"
    _MODELSCOPE_STATE_CACHE = (cache_key, now + 60, state)
    return state


def scan(payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    requested_source = str(payload.get("source") or "").strip().lower()
    source = requested_source or ("local" if context.fixture_root else "quest")
    if source == "local":
        context.progress(0.05, "正在扫描本地数据集")
        sessions = _scan_local(context.local_source_root)
    elif source == "quest":
        context.progress(0.05, "正在扫描 Quest 录制")
        sessions = _scan_quest(context)
    else:
        raise RuntimeError(f"不支持的数据来源: {source}")
    context.progress(1.0, f"发现 {len(sessions)} 条数据")
    return {"source": source, "sessions": sessions}


def start_ego(_payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    if context.fixture_root:
        context.progress(1.0, "Fixture mode: Ego launch skipped")
        return {"status": "fixture"}
    adb = context.adb
    context.progress(0.2, "Stopping previous Operator process")
    _run([adb, "shell", "am", "force-stop", "com.lovemoon.operator"], timeout=20)
    context.progress(0.5, "Starting Ego mode")
    result = _run(
        [
            adb,
            "shell",
            "am",
            "start",
            "-W",
            "-n",
            "com.lovemoon.operator/com.godot.game.GodotApp",
            "--es",
            "operator.mode",
            "ego",
        ],
        timeout=30,
    )
    if "Status: ok" not in result.stdout:
        raise RuntimeError(f"Ego launch did not report Status: ok\n{result.stdout}")
    context.progress(1.0, "Ego is running; USB may now be disconnected")
    return {"status": "ok", "output": result.stdout[-2000:]}


def import_session(payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    session_id = str(payload.get("session_id") or "").strip()
    if not SESSION_RE.fullmatch(session_id):
        raise RuntimeError("Invalid session ID")
    delete_after = bool(payload.get("delete_after", False))
    source_kind = str(payload.get("source") or "").strip().lower()
    if not source_kind:
        source_kind = "local" if context.fixture_root else "quest"
    root = context.data_root
    incoming_root = root / "incoming"
    sessions_root = root / "sessions"
    incoming_root.mkdir(parents=True, exist_ok=True)
    sessions_root.mkdir(parents=True, exist_ok=True)
    destination = sessions_root / session_id
    local_source: Path | None = None
    quest_source: dict[str, str] | None = None
    if source_kind == "local":
        local_source = _resolve_local_source(
            context.local_source_root,
            session_id,
            str(payload.get("source_path") or "").strip(),
        )
        if local_source.parent == sessions_root.resolve():
            context.progress(0.15, "正在校验本地数据集")
            qc = validate_session(local_source)
            if not qc["ok"]:
                raise RuntimeError("本地数据校验失败: " + "; ".join(qc["errors"]))
            previews, preview_warning = _create_previews_with_warning(
                local_source, context, qc
            )
            context.progress(1.0, "本地数据集已读取")
            return {
                "source_session_id": session_id,
                "dataset_name": local_source.name,
                "local_path": str(local_source),
                "label": _read_existing_label(local_source),
                "qc": qc,
                "preview_paths": [str(preview) for preview in previews],
                "preview_warning": preview_warning,
                "quest_deleted": False,
            }
    elif source_kind == "quest":
        quest_source = _resolve_quest_source(context, session_id, payload)
    else:
        raise RuntimeError(f"不支持的数据来源: {source_kind}")

    partial = incoming_root / f"{session_id}.partial"
    if partial.exists() or destination.exists():
        raise RuntimeError(f"Destination already exists for {session_id}; refusing to overwrite")
    partial.mkdir(mode=0o700)

    try:
        context.progress(0.05, "Copying media and sidecars")
        if source_kind == "local":
            assert local_source is not None
            _copy_local_session(local_source, session_id, partial)
        else:
            assert quest_source is not None
            _pull_quest_session(context, session_id, partial, quest_source)
        context.progress(0.65, "Validating manifest and media")
        qc = validate_session(partial)
        if not qc["ok"]:
            raise RuntimeError("Import integrity checks failed: " + "; ".join(qc["errors"]))

        previews, preview_warning = _create_previews_with_warning(partial, context, qc)
        os.replace(partial, destination)
        preview_paths = [
            destination / preview.parent.name / preview.name
            for preview in previews
        ]
        context.progress(0.9, "Verified local copy is committed")

        deleted = False
        if delete_after:
            if source_kind == "local":
                qc["warnings"].append("本地来源数据不会被自动删除")
            else:
                assert quest_source is not None
                _delete_quest_source(context, quest_source)
                deleted = True
        context.progress(1.0, "Import complete")
        return {
            "source_session_id": session_id,
            "dataset_name": session_id,
            "local_path": str(destination),
            "label": _read_existing_label(destination),
            "qc": qc,
            "preview_paths": [str(preview) for preview in preview_paths],
            "preview_warning": preview_warning,
            "quest_deleted": deleted,
        }
    except Exception:
        # A failed copy is deliberately retained under incoming for forensics.
        # The final sessions directory is never created until validation passes.
        raise


def label_item(payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    item_id = str(payload.get("item_id") or "").strip()
    source_session_id = str(payload.get("source_session_id") or "").strip()
    label = str(payload.get("label") or "").strip().lower()
    local_path = Path(str(payload.get("local_path") or "")).expanduser().resolve()
    if not item_id or not SESSION_RE.fullmatch(source_session_id):
        raise RuntimeError("Invalid label job item")
    if not LABEL_RE.fullmatch(label):
        raise RuntimeError("Label must use a-z, 0-9, _ or -")
    sessions_root = (context.data_root / "sessions").resolve()
    if local_path.parent != sessions_root or not local_path.is_dir():
        raise RuntimeError("Item path is outside the configured sessions directory")

    manifest = _read_manifest(local_path)
    dataset_name = build_dataset_name(source_session_id, label, manifest)
    target = sessions_root / dataset_name
    if target.exists() and target != local_path:
        raise RuntimeError(f"Dataset name already exists: {dataset_name}")
    labels = {
        "name": dataset_name,
        "source_session_id": source_session_id,
        "label": label,
        "result": "pass",
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    (local_path / "labels.json").write_text(
        json.dumps(labels, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    if target != local_path:
        os.replace(local_path, target)
    context.progress(1.0, f"Renamed to {dataset_name}")
    return {
        "item_id": item_id,
        "source_session_id": source_session_id,
        "dataset_name": dataset_name,
        "local_path": str(target),
        "label": label,
    }


def upload_item(payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    item_id = str(payload.get("item_id") or "").strip()
    local_path = Path(str(payload.get("local_path") or "")).expanduser().resolve()
    dataset_name = str(payload.get("dataset_name") or local_path.name).strip()
    revision = str(payload.get("revision") or "master").strip()
    if not item_id or not local_path.is_dir():
        raise RuntimeError("Upload job is missing item or local data")
    sessions_root = (context.data_root / "sessions").resolve()
    if local_path.parent != sessions_root:
        raise RuntimeError("Upload path is outside the configured sessions directory")
    token = modelscope_token(context.config)
    if not token:
        raise RuntimeError("ModelScope credentials were not provisioned by Station")
    files = [
        path
        for path in local_path.rglob("*")
        if path.is_file() and path.name not in {".ms_upload_cache", ".ms_upload_progress"}
    ]
    total_bytes = sum(path.stat().st_size for path in files)
    if total_bytes <= 0:
        raise RuntimeError("Upload dataset does not contain any files")
    try:
        configured_workers = int(context.config.get("modelscope_upload_workers") or 8)
    except (TypeError, ValueError):
        configured_workers = 8
    workers = max(1, min(configured_workers, 8))
    context.progress(
        0.02,
        f"正在准备可续传上传 · {len(files)} 个文件 · {_format_bytes(total_bytes)}",
        {
            "phase": "preparing",
            "transferredBytes": 0,
            "totalBytes": total_bytes,
            "bytesPerSecond": 0,
            "etaSeconds": 0,
            "filesTotal": len(files),
            "workers": workers,
            "resumable": True,
        },
    )
    from modelscope_hub import HubApi
    import modelscope_hub._upload as modelscope_upload

    tracker = _UploadProgressTracker(context, total_bytes, len(files), workers)
    original_tqdm = modelscope_upload.tqdm
    modelscope_upload.tqdm = tracker.tqdm
    try:
        HubApi(token=token).upload_folder(
            FIXED_MODELSCOPE_REPO_ID,
            "dataset",
            local_path,
            path_in_repo=f"sessions/{dataset_name}",
            revision=revision,
            commit_message=f"add {dataset_name}",
            max_workers=workers,
            use_cache=True,
            disable_tqdm=False,
        )
    finally:
        modelscope_upload.tqdm = original_tqdm
    summary = tracker.summary()
    context.progress(
        1.0,
        f"ModelScope 上传完成 · {_format_bytes(total_bytes)}",
        {
            "phase": "completed",
            "transferredBytes": total_bytes,
            "totalBytes": total_bytes,
            "bytesPerSecond": summary["average_bytes_per_second"],
            "etaSeconds": 0,
            "filesTotal": len(files),
            "workers": workers,
            "resumable": True,
        },
    )
    return {
        "item_id": item_id,
        "repo_id": FIXED_MODELSCOPE_REPO_ID,
        "revision": revision,
        "path_in_repo": f"sessions/{dataset_name}",
        "uploaded_at": datetime.now(timezone.utc).isoformat(),
        **summary,
    }


def preview_item(payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    item_id = str(payload.get("item_id") or "").strip()
    local_path = Path(str(payload.get("local_path") or "")).expanduser().resolve()
    _require_managed_session(item_id, local_path, context)
    previews = _create_preview_frames(local_path, context)
    if not previews:
        raise RuntimeError("没有生成任何预览图片")
    context.progress(1.0, f"已生成 {len(previews)} 张预览图片")
    return {
        "item_id": item_id,
        "preview_paths": [str(preview) for preview in previews],
    }


def delete_local_item(payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    item_id = str(payload.get("item_id") or "").strip()
    local_path = Path(str(payload.get("local_path") or "")).expanduser().resolve()
    _require_managed_session(item_id, local_path, context)
    trash_root = (context.data_root / "trash").resolve()
    trash_root.mkdir(parents=True, exist_ok=True)
    suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = trash_root / f"{local_path.name}.{suffix}"
    if target.exists():
        target = trash_root / f"{local_path.name}.{suffix}.{item_id[:8]}"
    context.progress(0.2, "正在将本地数据移到回收站")
    os.replace(local_path, target)
    context.progress(1.0, "本地数据已移到回收站")
    return {
        "item_id": item_id,
        "dataset_name": local_path.name,
        "trash_path": str(target),
    }


def _require_managed_session(item_id: str, local_path: Path, context: JobContext) -> None:
    sessions_root = (context.data_root / "sessions").resolve()
    if not item_id or local_path.parent != sessions_root or not local_path.is_dir():
        raise RuntimeError("Local item is outside the managed sessions directory")


def validate_session(session_dir: Path) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []
    checks: dict[str, Any] = {}
    media = session_dir / "media.mp4"
    manifest_path = session_dir / "manifest.json"
    sidecars = session_dir / "sidecars"

    manifest: dict[str, Any] = {}
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        checks["manifest"] = isinstance(manifest, dict)
        if not isinstance(manifest, dict):
            errors.append("manifest.json is not an object")
    except Exception as error:
        checks["manifest"] = False
        errors.append(f"manifest.json invalid: {error}")

    checks["media_exists"] = media.is_file() and media.stat().st_size > 0
    if not checks["media_exists"]:
        errors.append("media.mp4 is missing or empty")
    checks["sidecars"] = sidecars.is_dir()

    expected_hash = str(
        (((manifest.get("artifacts") or {}).get("media") or {}).get("sha256") or "")
    ).lower()
    actual_hash = _sha256(media) if media.is_file() else ""
    checks["media_hash"] = bool(expected_hash) and expected_hash == actual_hash
    if not expected_hash:
        errors.append("manifest has no media SHA-256")
    elif expected_hash != actual_hash:
        errors.append("media SHA-256 mismatch")

    expected_bytes = int(
        (((manifest.get("artifacts") or {}).get("media") or {}).get("bytes") or 0)
    )
    actual_bytes = media.stat().st_size if media.is_file() else 0
    checks["media_bytes"] = not expected_bytes or expected_bytes == actual_bytes
    if expected_bytes and expected_bytes != actual_bytes:
        errors.append("media byte count mismatch")

    streams: dict[str, Any] = {}
    if sidecars.is_dir():
        for relative, group_key in [
            ("left_camera_frames.jsonl", "eye"),
            ("right_camera_frames.jsonl", "eye"),
            ("poses/hands.jsonl", "hand"),
            ("depth/frames.jsonl", "depth"),
        ]:
            path = sidecars / relative
            streams[relative] = _jsonl_stats(path, group_key)
    depth_status = (((manifest.get("stream_confirmations") or {}).get("depth") or {}).get("status"))
    if depth_status == "missing":
        warnings.append("Depth requested but missing")

    qc = {
        "ok": not errors,
        "checks": checks,
        "errors": errors,
        "warnings": warnings,
        "streams": streams,
        "media_bytes": actual_bytes,
        "media_sha256": actual_hash,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }
    (session_dir / "qc.json").write_text(
        json.dumps(qc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return qc


def build_dataset_name(session_id: str, label: str, manifest: dict[str, Any]) -> str:
    match = re.fullmatch(r"(\d{8})_(\d{6})", session_id)
    millis = 0
    try:
        unix_us = int(float(manifest.get("session_start_unix_us", 0)))
        millis = (unix_us // 1000) % 1000
    except (TypeError, ValueError):
        pass
    if match:
        date_part, time_part = match.groups()
    else:
        now = datetime.now(timezone.utc)
        date_part, time_part = now.strftime("%Y%m%d"), now.strftime("%H%M%S")
    return f"{date_part}_{label}_{time_part}{millis:03d}"


def _scan_local(root: Path) -> list[dict[str, Any]]:
    if not root.is_dir():
        raise RuntimeError(f"Fixture directory does not exist: {root}")
    candidates = [root] if (root / "manifest.json").is_file() else [p for p in root.iterdir() if p.is_dir()]
    sessions: list[dict[str, Any]] = []
    for candidate in sorted(candidates):
        try:
            manifest = _read_manifest(candidate)
        except Exception:
            continue
        session_id = str(manifest.get("session_id") or candidate.name)
        media = _fixture_media(candidate, session_id)
        sidecars = candidate / "sidecars"
        complete = media.is_file() and media.stat().st_size > 0
        sessions.append({
            "session_id": session_id,
            "media_bytes": media.stat().st_size if media.is_file() else 0,
            "has_manifest": True,
            "has_sidecars": sidecars.is_dir(),
            "complete": complete,
            "layout": "normalized" if (candidate / "media.mp4").is_file() else "session_directory",
            "source": "local",
            "source_path": str(candidate.resolve()),
        })
    return sessions


def _scan_fixture(root: Path) -> list[dict[str, Any]]:
    return _scan_local(root)


def _scan_quest(context: JobContext) -> list[dict[str, Any]]:
    adb = context.adb
    sessions: list[dict[str, Any]] = []
    for root in context.quest_roots:
        quoted_root = shlex.quote(root)
        directory_output = _run(
            [adb, "shell", f"if [ -d {quoted_root} ]; then find {quoted_root} -mindepth 1 -maxdepth 1 -type d 2>/dev/null; fi"],
            timeout=60,
        ).stdout
        for session_dir in sorted(line.strip() for line in directory_output.splitlines() if line.strip()):
            session_id = session_dir.rstrip("/").rsplit("/", 1)[-1]
            if not SESSION_RE.fullmatch(session_id):
                continue
            media_path = f"{session_dir}/{session_id}.mp4"
            if not _adb_test_file(adb, media_path):
                continue
            manifest_path = f"{session_dir}/manifest.json"
            has_manifest = _adb_test_file(adb, manifest_path)
            sessions.append(_quest_scan_record(
                adb, root, session_id, "session_directory", session_dir,
                media_path, manifest_path, has_manifest,
            ))

        file_output = _run(
            [adb, "shell", f"if [ -d {quoted_root} ]; then find {quoted_root} -maxdepth 1 -type f -name '*.mp4' 2>/dev/null; fi"],
            timeout=60,
        ).stdout
        for media_path in sorted(line.strip() for line in file_output.splitlines() if line.strip()):
            if media_path.endswith(".partial.mp4"):
                continue
            session_id = media_path.rsplit("/", 1)[-1][:-4]
            if not SESSION_RE.fullmatch(session_id):
                continue
            session_dir = f"{root}/{session_id}"
            manifest_path = f"{session_dir}/manifest.json"
            has_manifest = _adb_test_file(adb, manifest_path)
            sessions.append(_quest_scan_record(
                adb, root, session_id, "legacy_siblings", media_path,
                media_path, manifest_path, has_manifest,
            ))
    return sessions


def _quest_scan_record(
    adb: str,
    root: str,
    session_id: str,
    layout: str,
    source_path: str,
    media_path: str,
    manifest_path: str,
    has_manifest: bool,
) -> dict[str, Any]:
    media_bytes = _adb_file_size(adb, media_path)
    return {
        "session_id": session_id,
        "media_bytes": media_bytes,
        "has_manifest": has_manifest,
        "has_sidecars": has_manifest,
        "complete": has_manifest and media_bytes > 0,
        "layout": layout,
        "quest_root": root,
        "media_path": media_path,
        "manifest_path": manifest_path,
        "source": "quest",
        "source_path": source_path,
    }


def _adb_test_file(adb: str, path: str) -> bool:
    result = subprocess.run(
        [adb, "shell", f"test -f {shlex.quote(path)}"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    return result.returncode == 0


def _adb_file_size(adb: str, path: str) -> int:
    output = _run(
        [adb, "shell", f"stat -c %s {shlex.quote(path)} 2>/dev/null || wc -c < {shlex.quote(path)}"],
        timeout=20,
    ).stdout.strip()
    try:
        return int(output.splitlines()[-1])
    except (ValueError, IndexError):
        return 0


def _resolve_local_source(root: Path, session_id: str, explicit_path: str) -> Path:
    root = root.resolve()
    if explicit_path:
        source = Path(explicit_path).expanduser().resolve()
        if source != root and root not in source.parents:
            raise RuntimeError("本地数据集路径超出已配置目录")
        candidates = [source]
    else:
        candidates = [root] if (root / "manifest.json").is_file() else [root / session_id]
    source = next((candidate for candidate in candidates if candidate.is_dir()), None)
    if not source:
        raise RuntimeError(f"找不到本地数据集: {session_id}")
    manifest = _read_manifest(source)
    manifest_session_id = str(manifest.get("session_id") or source.name)
    if manifest_session_id != session_id:
        raise RuntimeError("本地数据集的 manifest session_id 与所选数据不一致")
    return source


def _copy_local_session(source: Path, session_id: str, destination: Path) -> None:
    media = _fixture_media(source, session_id)
    if not media.is_file():
        raise RuntimeError(f"本地数据集缺少视频: {session_id}")
    shutil.copy2(media, destination / "media.mp4")
    sidecars = source / "sidecars"
    if sidecars.is_dir():
        shutil.copytree(sidecars, destination / "sidecars")
    else:
        # Current Quest recordings are self-contained and keep metadata in the
        # MP4. Preserve any optional debug artifacts without requiring them.
        ignored = {
            media.name,
            "media.mp4",
            "manifest.json",
            "labels.json",
            "qc.json",
            "preview.mp4",
            "previews",
        }
        # Keep current-layout artifacts at their original relative paths so
        # manifest artifact filenames continue to resolve after import.
        extras = [entry for entry in source.iterdir() if entry.name not in ignored]
        for entry in extras:
            target = destination / entry.name
            if entry.is_dir():
                shutil.copytree(entry, target)
            elif entry.is_file():
                shutil.copy2(entry, target)
    manifest = source / "manifest.json"
    if not manifest.is_file():
        manifest = sidecars / "manifest.json"
    shutil.copy2(manifest, destination / "manifest.json")
    labels = source / "labels.json"
    if labels.is_file():
        shutil.copy2(labels, destination / "labels.json")


def _copy_fixture_session(root: Path, session_id: str, destination: Path) -> None:
    source = _resolve_local_source(root, session_id, "")
    _copy_local_session(source, session_id, destination)


def _quest_source(root: str, session_id: str, layout: str) -> dict[str, str]:
    session_dir = f"{root}/{session_id}"
    if layout == "session_directory":
        media = f"{session_dir}/{session_id}.mp4"
        source_path = session_dir
    elif layout == "legacy_siblings":
        media = f"{root}/{session_id}.mp4"
        source_path = media
    else:
        raise RuntimeError(f"不支持的 Quest 数据结构: {layout}")
    return {
        "root": root,
        "layout": layout,
        "session_dir": session_dir,
        "media": media,
        "manifest": f"{session_dir}/manifest.json",
        "source_path": source_path,
    }


def _resolve_quest_source(
    context: JobContext,
    session_id: str,
    payload: dict[str, Any],
) -> dict[str, str]:
    requested_root = str(payload.get("quest_root") or "").strip()
    requested_layout = str(payload.get("layout") or "").strip()
    roots = context.quest_roots
    if requested_root:
        requested_root = _validate_quest_root(requested_root)
        if requested_root not in roots:
            raise RuntimeError("Quest 数据路径不在允许的扫描目录中")
        roots = [requested_root]
    if requested_layout:
        if requested_layout not in {"session_directory", "legacy_siblings"}:
            raise RuntimeError("Quest 数据结构参数无效")
        return _quest_source(roots[0], session_id, requested_layout)

    # Backward compatibility for jobs queued by an older Station frontend.
    for root in roots:
        for layout in ("session_directory", "legacy_siblings"):
            source = _quest_source(root, session_id, layout)
            if _adb_test_file(context.adb, source["media"]) and _adb_test_file(
                context.adb, source["manifest"]
            ):
                return source
    raise RuntimeError(f"Quest 上找不到完整数据: {session_id}")


def _pull_quest_session(
    context: JobContext,
    session_id: str,
    destination: Path,
    source: dict[str, str],
) -> None:
    adb = context.adb
    if source["layout"] == "legacy_siblings":
        _run([adb, "pull", source["media"], str(destination / "media.mp4")], timeout=6 * 60 * 60)
        _run([adb, "pull", source["session_dir"], str(destination / "sidecars")], timeout=6 * 60 * 60)
        manifest = destination / "sidecars" / "manifest.json"
        if not manifest.is_file():
            raise RuntimeError("Quest sidecars did not contain manifest.json")
        shutil.copy2(manifest, destination / "manifest.json")
        return

    pulled_root = destination / "quest_session"
    _run([adb, "pull", source["session_dir"], str(pulled_root)], timeout=6 * 60 * 60)
    pulled = pulled_root
    if not (pulled / "manifest.json").is_file() and (pulled / session_id).is_dir():
        pulled = pulled / session_id
    media = pulled / f"{session_id}.mp4"
    manifest = pulled / "manifest.json"
    if not media.is_file() or not manifest.is_file():
        raise RuntimeError("Quest 新格式数据缺少 MP4 或 manifest.json")
    shutil.move(str(media), destination / "media.mp4")
    shutil.copy2(manifest, destination / "manifest.json")

    ignored = {f"{session_id}.partial.mp4", "manifest.json"}
    extras = [entry for entry in pulled.iterdir() if entry.name not in ignored]
    for entry in extras:
        # Preserve current-layout relative paths referenced by manifest.json.
        shutil.move(str(entry), destination / entry.name)
    shutil.rmtree(pulled_root, ignore_errors=True)


def _delete_quest_source(context: JobContext, source: dict[str, str]) -> None:
    media = shlex.quote(source["media"])
    manifest = shlex.quote(source["manifest"])
    session_dir = shlex.quote(source["session_dir"])
    if source["layout"] == "session_directory":
        command = f"test -f {media} && test -f {manifest} && rm -rf {session_dir}"
    else:
        command = (
            f"test -f {media} && test -f {manifest} && test -d {session_dir} && "
            f"rm -f {media} && rm -rf {session_dir}"
        )
    _run([context.adb, "shell", command], timeout=120)


def delete_quest_session(payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    session_id = str(payload.get("session_id") or "").strip()
    if not SESSION_RE.fullmatch(session_id):
        raise RuntimeError("Invalid session ID")
    source = _resolve_quest_source(context, session_id, payload)
    context.progress(0.2, "正在删除 Quest 数据")
    _delete_quest_source(context, source)
    context.progress(0.8, "Quest 数据已删除，正在刷新列表")
    sessions = _scan_quest(context)
    context.progress(1.0, "Quest 数据已删除")
    return {
        "session_id": session_id,
        "source_path": source["source_path"],
        "layout": source["layout"],
        "sessions": sessions,
    }


def _create_previews_with_warning(
    session_dir: Path,
    context: JobContext,
    qc: dict[str, Any],
) -> tuple[list[Path], str]:
    try:
        return _create_preview_frames(session_dir, context), ""
    except RuntimeError as error:
        warning = f"图片预览生成失败: {error}"
        warnings = qc.setdefault("warnings", [])
        if isinstance(warnings, list) and warning not in warnings:
            warnings.append(warning)
        (session_dir / "qc.json").write_text(
            json.dumps(qc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        return [], warning


def _create_preview_frames(session_dir: Path, context: JobContext) -> list[Path]:
    if not bool(context.config.get("preview_enabled", True)):
        return []
    media = session_dir / "media.mp4"
    preview_dir = session_dir / "preview_frames"
    ffmpeg = find_tool(context.config, "ffmpeg")
    if not ffmpeg:
        raise RuntimeError("Agent 安装包中未找到 FFmpeg")
    if preview_dir.exists():
        shutil.rmtree(preview_dir)
    preview_dir.mkdir(mode=0o700)
    context.progress(0.76, "正在生成轻量图片预览")
    pattern = preview_dir / "%02d.jpg"
    command = [
        ffmpeg,
        "-y",
        "-v",
        "error",
        "-i",
        str(media),
        "-map",
        "0:v:0",
        "-an",
        "-t",
        "120",
        "-vf",
        "crop=iw/2:ih:0:0,fps=1/20,scale=640:-2",
        "-frames:v",
        "6",
        "-q:v",
        "3",
        str(pattern),
    ]
    try:
        _run(command, timeout=60 * 60)
    except Exception as error:
        shutil.rmtree(preview_dir, ignore_errors=True)
        raise RuntimeError(str(error)) from error
    previews = sorted(preview_dir.glob("*.jpg"))[:6]
    if not previews:
        raise RuntimeError("FFmpeg 执行完成，但没有输出图片")
    return previews


def _read_manifest(session_dir: Path) -> dict[str, Any]:
    path = session_dir / "manifest.json"
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("manifest is not an object")
    return value


def _read_existing_label(session_dir: Path) -> str:
    path = session_dir / "labels.json"
    if not path.is_file():
        return ""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        label = str(value.get("label") or "").strip().lower()
        return label if LABEL_RE.fullmatch(label) else ""
    except Exception:
        return ""


def _fixture_media(source: Path, session_id: str) -> Path:
    normalized = source / "media.mp4"
    return normalized if normalized.is_file() else source / f"{session_id}.mp4"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _jsonl_stats(path: Path, group_key: str) -> dict[str, Any]:
    if not path.is_file():
        return {"records": 0, "missing": True}
    timestamps: dict[str, list[int]] = defaultdict(list)
    invalid = 0
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                value = json.loads(line)
                group = str(value.get(group_key, "all")) if group_key != "depth" else "depth"
                timestamp = value.get("timestamp_ns")
                if isinstance(timestamp, (int, float)):
                    timestamps[group].append(int(timestamp))
                else:
                    invalid += 1
            except Exception:
                invalid += 1
    groups: dict[str, Any] = {}
    for group, values in timestamps.items():
        span = (max(values) - min(values)) / 1_000_000_000 if len(values) > 1 else 0
        groups[group] = {
            "records": len(values),
            "span_seconds": round(span, 6),
            "hz": round((len(values) - 1) / span, 3) if span else 0,
            "monotonic": all(a <= b for a, b in zip(values, values[1:])),
        }
    return {"records": sum(len(values) for values in timestamps.values()), "invalid": invalid, "groups": groups}


def _run(command: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise RuntimeError(f"Command failed ({error.returncode}): {command[0]}\n{detail}") from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Command timed out: {command[0]}") from error
