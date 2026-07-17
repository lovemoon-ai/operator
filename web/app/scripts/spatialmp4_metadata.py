"""Lightweight metadata-source resolution for the SpatialMP4 Rerun worker.

This module intentionally uses only the Python standard library so the
self-contained-MP4 contract can be tested without importing Rerun, OpenCV, or
the native SpatialMP4 SDK.
"""

from __future__ import annotations

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


def camera2_metadata_candidates(
    input_path: Path,
    operator_static: Optional[Dict[str, Any]],
    eye: str,
) -> Tuple[List[CameraMetadataCandidate], List[str]]:
    """Return Camera2 metadata embedded in MP4 operator_static."""
    _ = input_path
    candidates: List[CameraMetadataCandidate] = []
    embedded = extract_camera2_characteristics(operator_static, eye)
    if embedded is not None:
        candidates.append((embedded, f"MP4 operator_static {eye} Camera2 characteristics", True))
    return candidates, []


def resolve_android_timebase_metadata(
    input_path: Path,
    operator_static: Optional[Dict[str, Any]],
) -> Tuple[Optional[Dict[str, Any]], str, Optional[str]]:
    _ = input_path
    embedded = extract_android_timebase(operator_static)
    if embedded is not None:
        return embedded, "mp4", None
    return None, "", None
