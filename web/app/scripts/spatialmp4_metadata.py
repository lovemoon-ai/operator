"""Lightweight metadata-source resolution for the SpatialMP4 Rerun worker.

This module intentionally uses only the Python standard library so the
self-contained-MP4 contract can be tested without importing Rerun, OpenCV, or
the native SpatialMP4 SDK.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


CameraMetadataCandidate = Tuple[Dict[str, Any], str, bool]

# JSON packet streams whose payloads the Rerun converter actually consumes.
# `operator_static` is loaded separately as a one-shot record, while
# `rgb_frame_index` only needs stream identification so it is not eagerly
# demuxed into one Python object per RGB frame.
RERUN_FRAME_METADATA_KINDS = (
    "depth_frame_meta",
    "body_frame_meta",
    "motion_trackers",
)


def extract_camera2_characteristics(
    operator_static: Optional[Dict[str, Any]],
    eye: str,
) -> Optional[Dict[str, Any]]:
    if not isinstance(operator_static, dict):
        return None
    eye_keys = (eye, f"{eye}_camera_characteristics", f"{eye}_camera2_characteristics")
    for key in eye_keys:
        value = operator_static.get(key)
        if isinstance(value, dict):
            return value

    container_keys = (
        "camera2",
        "camera2_characteristics",
        "camera_characteristics",
        "camera2_calibration",
        "cameras",
    )
    for container_key in container_keys:
        container = operator_static.get(container_key)
        if isinstance(container, dict):
            for eye_key in eye_keys:
                value = container.get(eye_key)
                if isinstance(value, dict):
                    return value
            for nested_key in ("characteristics", "camera_characteristics", "camera2_characteristics"):
                nested = container.get(nested_key)
                if not isinstance(nested, dict):
                    continue
                for eye_key in eye_keys:
                    value = nested.get(eye_key)
                    if isinstance(value, dict):
                        return value
        elif isinstance(container, list):
            for item in container:
                if not isinstance(item, dict):
                    continue
                item_eye = str(item.get("eye") or item.get("camera") or item.get("camera_id") or "").lower()
                if item_eye == eye:
                    for nested_key in ("characteristics", "camera_characteristics", "camera2_characteristics"):
                        nested = item.get(nested_key)
                        if isinstance(nested, dict):
                            return nested
                    return item
    return None


def extract_android_timebase(
    operator_static: Optional[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    if not isinstance(operator_static, dict):
        return None
    for key in ("android_timebase", "timebase"):
        value = operator_static.get(key)
        if isinstance(value, dict):
            return value
    return None


def legacy_sidecar_candidates(input_path: Path, filename: str) -> List[Path]:
    return [
        input_path.with_suffix("") / filename,
        input_path.parent / filename,
    ]


def load_legacy_json_sidecar(
    input_path: Path,
    filename: str,
) -> Tuple[Optional[Dict[str, Any]], Optional[Path], Optional[str]]:
    sidecar_path = next(
        (path for path in legacy_sidecar_candidates(input_path, filename) if path.exists()),
        None,
    )
    if sidecar_path is None:
        return None, None, None
    try:
        decoded = json.loads(sidecar_path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        return None, sidecar_path, str(exc)
    if not isinstance(decoded, dict):
        return None, sidecar_path, "metadata is not a JSON object"
    return decoded, sidecar_path, None


def camera2_metadata_candidates(
    input_path: Path,
    operator_static: Optional[Dict[str, Any]],
    eye: str,
) -> Tuple[List[CameraMetadataCandidate], List[str]]:
    """Return embedded metadata first, followed by a legacy sidecar fallback."""
    candidates: List[CameraMetadataCandidate] = []
    errors: List[str] = []
    embedded = extract_camera2_characteristics(operator_static, eye)
    if embedded is not None:
        candidates.append((embedded, f"MP4 operator_static {eye} Camera2 characteristics", True))

    sidecar, sidecar_path, error = load_legacy_json_sidecar(
        input_path,
        f"{eye}_camera_characteristics.json",
    )
    if sidecar is not None and sidecar_path is not None:
        candidates.append((sidecar, str(sidecar_path), False))
    elif error is not None and sidecar_path is not None:
        errors.append(f"Camera2 sidecar read failed ({sidecar_path}): {error}")
    return candidates, errors


def resolve_android_timebase_metadata(
    input_path: Path,
    operator_static: Optional[Dict[str, Any]],
) -> Tuple[Optional[Dict[str, Any]], str, Optional[str]]:
    embedded = extract_android_timebase(operator_static)
    if embedded is not None:
        return embedded, "mp4", None

    sidecar, sidecar_path, error = load_legacy_json_sidecar(input_path, "android_timebase.json")
    if sidecar is not None and sidecar_path is not None:
        return sidecar, str(sidecar_path), None
    return None, str(sidecar_path) if sidecar_path is not None else "", error
