from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


Progress = Callable[[float, str], None]
SESSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_MODELSCOPE_STATE_CACHE: tuple[str, float, str] = ("", 0.0, "not found")


@dataclass
class JobContext:
    config: dict[str, Any]
    progress: Progress

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
        value = str(self.config.get("quest_root") or "/sdcard/Movies/SpatialMP4").strip()
        if not value.startswith("/sdcard/") and not value.startswith("/storage/emulated/0/"):
            raise RuntimeError("Quest root must be under /sdcard or /storage/emulated/0")
        if any(part in {"", ".", ".."} for part in value.split("/")[1:]):
            raise RuntimeError("Quest root contains an unsafe path component")
        return value.rstrip("/")

    @property
    def adb(self) -> str:
        configured = str(self.config.get("adb_path") or "").strip()
        found = configured or shutil.which("adb")
        if not found:
            raise RuntimeError("adb was not found; install Android Platform Tools")
        return found


def run_job(kind: str, payload: dict[str, Any], context: JobContext) -> dict[str, Any]:
    handlers = {
        "scan": scan,
        "start_ego": start_ego,
        "import": import_session,
        "label": label_item,
        "upload": upload_item,
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
        adb = str(config.get("adb_path") or "").strip() or shutil.which("adb")
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

    modelscope = _modelscope_state()

    return {
        "adb": adb_state,
        "quest": quest_state,
        "ffmpeg": "ready" if (str(config.get("ffmpeg_path") or "").strip() or shutil.which("ffmpeg")) else "not found",
        "modelscope": modelscope,
        "dataRoot": str(data_root.resolve()) if data_root else "",
        "freeBytes": free_bytes,
        "platform": platform.platform(),
    }


def _modelscope_state() -> str:
    global _MODELSCOPE_STATE_CACHE
    executable = shutil.which("ms-hub") or ""
    if not executable:
        _MODELSCOPE_STATE_CACHE = ("", 0.0, "not found")
        return "not found"
    cached_executable, expires_at, cached_state = _MODELSCOPE_STATE_CACHE
    now = time.monotonic()
    if cached_executable == executable and now < expires_at:
        return cached_state
    try:
        _run([executable, "whoami"], timeout=15)
        state = "authenticated"
    except Exception:
        state = "not authenticated"
    _MODELSCOPE_STATE_CACHE = (executable, now + 60, state)
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
            previews = _create_preview_frames(local_source, context)
            context.progress(1.0, "本地数据集已读取")
            return {
                "source_session_id": session_id,
                "dataset_name": local_source.name,
                "local_path": str(local_source),
                "label": _read_existing_label(local_source),
                "qc": qc,
                "preview_paths": [str(preview) for preview in previews],
                "quest_deleted": False,
            }
    elif source_kind != "quest":
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
            _pull_quest_session(context, session_id, partial)
        context.progress(0.65, "Validating manifest, media and sidecars")
        qc = validate_session(partial)
        if not qc["ok"]:
            raise RuntimeError("Import integrity checks failed: " + "; ".join(qc["errors"]))

        previews = _create_preview_frames(partial, context)
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
                _delete_quest_session(context, session_id)
                deleted = True
        context.progress(1.0, "Import complete")
        return {
            "source_session_id": session_id,
            "dataset_name": session_id,
            "local_path": str(destination),
            "label": _read_existing_label(destination),
            "qc": qc,
            "preview_paths": [str(preview) for preview in preview_paths],
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
    repo_id = str(payload.get("repo_id") or "").strip()
    revision = str(payload.get("revision") or "master").strip()
    if not item_id or not repo_id or not local_path.is_dir():
        raise RuntimeError("Upload job is missing item, repository or local data")
    sessions_root = (context.data_root / "sessions").resolve()
    if local_path.parent != sessions_root:
        raise RuntimeError("Upload path is outside the configured sessions directory")
    executable = shutil.which("ms-hub")
    if not executable:
        raise RuntimeError("ms-hub was not found; configure ModelScope credentials and client")
    context.progress(0.05, "Starting resumable ModelScope upload")
    command = [
        executable,
        "upload",
        repo_id,
        str(local_path),
        f"sessions/{dataset_name}",
        "--repo-type",
        "dataset",
        "--revision",
        revision,
        "--commit-message",
        f"add {dataset_name}",
    ]
    result = _run(command, timeout=24 * 60 * 60)
    context.progress(1.0, "ModelScope upload complete")
    return {
        "item_id": item_id,
        "repo_id": repo_id,
        "revision": revision,
        "path_in_repo": f"sessions/{dataset_name}",
        "output": result.stdout[-4000:],
        "uploaded_at": datetime.now(timezone.utc).isoformat(),
    }


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
    if not checks["sidecars"]:
        errors.append("sidecars directory is missing")

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
        if not sidecars.is_dir():
            sidecars = candidate / session_id
        sessions.append({
            "session_id": session_id,
            "media_bytes": media.stat().st_size if media.is_file() else 0,
            "has_manifest": True,
            "has_sidecars": sidecars.is_dir(),
            "source": "local",
            "source_path": str(candidate.resolve()),
        })
    return sessions


def _scan_fixture(root: Path) -> list[dict[str, Any]]:
    return _scan_local(root)


def _scan_quest(context: JobContext) -> list[dict[str, Any]]:
    adb, root = context.adb, context.quest_root
    quoted = shlex.quote(root)
    command = f"find {quoted} -maxdepth 1 -type f -name '*.mp4' 2>/dev/null"
    output = _run([adb, "shell", command], timeout=60).stdout
    sessions: list[dict[str, Any]] = []
    for media_path in sorted(line.strip() for line in output.splitlines() if line.strip()):
        session_id = Path(media_path).stem
        if not SESSION_RE.fullmatch(session_id):
            continue
        size_output = _run(
            [adb, "shell", f"stat -c %s {shlex.quote(media_path)} 2>/dev/null || wc -c < {shlex.quote(media_path)}"],
            timeout=20,
        ).stdout.strip()
        try:
            media_bytes = int(size_output.splitlines()[-1])
        except (ValueError, IndexError):
            media_bytes = 0
        sidecar_dir = f"{root}/{session_id}"
        manifest_result = subprocess.run(
            [adb, "shell", f"test -f {shlex.quote(sidecar_dir + '/manifest.json')}"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        sessions.append({
            "session_id": session_id,
            "media_bytes": media_bytes,
            "has_manifest": manifest_result.returncode == 0,
            "has_sidecars": manifest_result.returncode == 0,
            "source": "quest",
            "source_path": media_path,
        })
    return sessions


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
    if not sidecars.is_dir():
        sidecars = source / session_id
    if not sidecars.is_dir():
        raise RuntimeError(f"本地数据集缺少 sidecars: {session_id}")
    shutil.copytree(sidecars, destination / "sidecars")
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


def _pull_quest_session(context: JobContext, session_id: str, destination: Path) -> None:
    adb, root = context.adb, context.quest_root
    media = f"{root}/{session_id}.mp4"
    sidecars = f"{root}/{session_id}"
    _run([adb, "pull", media, str(destination / "media.mp4")], timeout=6 * 60 * 60)
    _run([adb, "pull", sidecars, str(destination / "sidecars")], timeout=6 * 60 * 60)
    manifest = destination / "sidecars" / "manifest.json"
    if not manifest.is_file():
        raise RuntimeError("Quest sidecars did not contain manifest.json")
    shutil.copy2(manifest, destination / "manifest.json")


def _delete_quest_session(context: JobContext, session_id: str) -> None:
    adb, root = context.adb, context.quest_root
    media = f"{root}/{session_id}.mp4"
    sidecars = f"{root}/{session_id}"
    command = (
        f"test -f {shlex.quote(media)} && test -d {shlex.quote(sidecars)} && "
        f"rm -f {shlex.quote(media)} && rm -rf {shlex.quote(sidecars)}"
    )
    _run([adb, "shell", command], timeout=120)


def _create_preview_frames(session_dir: Path, context: JobContext) -> list[Path]:
    if not bool(context.config.get("preview_enabled", True)):
        return []
    media = session_dir / "media.mp4"
    preview_dir = session_dir / "preview_frames"
    ffmpeg = str(context.config.get("ffmpeg_path") or "").strip() or shutil.which("ffmpeg")
    if not ffmpeg:
        return []
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
    except Exception:
        shutil.rmtree(preview_dir, ignore_errors=True)
        return []
    return sorted(preview_dir.glob("*.jpg"))[:6]


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
