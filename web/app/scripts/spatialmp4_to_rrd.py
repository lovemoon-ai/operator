#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13,<3.14"
# dependencies = [
#     # Pin rerun-sdk to the SAME major+minor as the
#     # `@rerun-io/web-viewer` npm dep on the web side. .rrd file format
#     # is NOT stable across rerun minor releases (writer-side format
#     # bumps every minor); a 0.33-written file is unreadable by a 0.32
#     # viewer and vice versa. If you bump one, bump both — search the
#     # repo for `@rerun-io/web-viewer` to find the matching line in
#     # web/app/package.json.
#     "rerun-sdk==0.33.*",
#     "numpy>=1.26.0",
#     "scipy>=1.11.0",
#     "opencv-python>=4.8.0",
# ]
# ///
"""SpatialMP4 → Rerun .rrd converter (web ingest worker variant).

This script is the server-side companion of
``visualize_rerun_quest.py`` in the SpatialMP4 SDK reference repo. It
keeps the **same coordinate conventions, entity paths, blueprint
layout and pose math** so anything an operator learned by playing
with the local viewer translates 1-for-1 to the embedded Rerun web
viewer in the dashboard.

Differences from the reference (deliberate):
  * **Ingest ships ``media.mp4`` + ``manifest.json``**. Camera2
    calibration and Android timebase are preferred from MP4 embedded
    ``operator_static`` metadata, with old sidecar layouts kept as fallback.
    Operator-specific JSON ``mett`` tracks such as ``motion_trackers`` are
    read directly from the MP4 with ffprobe until the SDK exposes typed APIs.
    Depth spool sidecars (``depth/frames.jsonl``) are still skipped here.
    When Quest Camera2 metadata is missing, we use ``T_W_Srgb = T_W_H @
    T_I_Srgb`` straight out of the mp4's RGB extrinsics and accept the
    live-writer's documented ~10° X-axis bias.
  * No typer dep — argparse is enough for a non-interactive worker
    and shaves one wheel off uv's first-run resolve.
  * Always ``rr.save()``; never spawns the viewer. The Node-side
    worker registers the produced ``.rrd`` as an artifact and the
    Next.js page loads it via ``@rerun-io/web-viewer``.
  * Bounded by ``--topk`` (default unlimited, but set
    ``RERUN_TOPK_FRAMES`` to cap dashboard latency on very long
    captures).

Per-device branches (Quest vs Pico):
  The two SDK reference scripts diverge in three places — we mirror
  them via a ``--device-type`` flag (or auto-detect from the manifest
  next to the input):
    1. **head mett track meaning** — Quest's ``head`` IS the IMU pose
       already; Pico's per-frame ``pose`` is the mid-eye position and
       must be passed through the SDK's ``head_to_imu`` axis/quaternion
       conversion before composing with the RGB extrinsic.
    2. **Extrinsic axis convention** — Pico's native axes need a
       cyclic permutation ``[[0,0,1,0],[1,0,0,0],[0,1,0,0],[0,0,0,1]]``
       on the composed ``T_W_S`` before logging.
    3. **Pinhole camera_xyz** — Quest = ``RDF`` (OpenCV); Pico = ``UBR``
       (the reference viewer's camera frame).
  World coordinate system is ``RUB`` for both. Pico raw Godot/OpenXR
  world samples (hands/controllers/head trajectory) are converted through
  the same basis changes that the Pico camera path uses before logging.

Coordinate conventions (mirrored from reference):
  * **world**: ``rr.ViewCoordinates.RUB``
      Quest / OpenXR — X-right, Y-up, Z-back-out-of-page. Head pose
      and all mett rigid_pose tracks live here in absolute world
      coordinates.
  * **camera (RGB + depth)**: Quest uses ``rr.ViewCoordinates.RDF``
      (OpenCV image axes, X-right, Y-down, Z-forward). Pico follows the
      SpatialMP4 reference and logs Pinhole axes as ``UBR`` after composing
      ``T_W_S = T_W_I @ T_I_S`` in Pico-native coordinates.
  * **head gaze**: OpenXR head looks down its local -Z axis, so the
      world-frame gaze direction is ``-R[:, 2]`` of the head rotation
      matrix.
  * **Hand joints**: returned by the SDK in world-frame already
      (XR_HAND_JOINT_*). The 26-joint topology is fixed; we draw
      points + bones using the same parent→child table as the
      reference (see ``XR_HAND_BONES`` below).
  * **Rotation drift guard**: extrinsics composed across multiple
      4×4 multiplications can drift off SO(3). ``ensure_right_handed_rotation``
      does an SVD reproject before handing matrices to Rerun.

SpatialMP4 SDK discovery:
  The SDK is not published to PyPI; it ships as a pybind11 build
  from https://github.com/Pico-Developer/SpatialMP4. The Node-side
  worker auto-detects the source checkout and exports
  ``SPATIALMP4_HOME``. At import time we walk that directory looking
  for a ``spatialmp4.cpython-<tag>-<plat>.so`` that matches the
  current Python ABI and prepend its parent directory to
  ``sys.path``. If we can't find a match the script bails out with
  an actionable hint.
"""

from __future__ import annotations

import argparse
import bisect
import importlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import sysconfig
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


# ---------------------------------------------------------------------------
# SpatialMP4 SDK bootstrap
# ---------------------------------------------------------------------------

def _emit(prefix: str, msg: str) -> None:
    print(f"[spatialmp4_to_rrd] {prefix}{msg}", file=sys.stderr, flush=True)


def info(msg: str) -> None:
    _emit("", msg)


def fatal(msg: str, code: int = 2) -> None:
    _emit("FATAL: ", msg)
    sys.exit(code)


def _abi_tag() -> str:
    """Return e.g. ``cpython-313`` to match the SDK's ``.so`` suffix."""
    impl = sys.implementation.cache_tag or ""
    return impl  # cache_tag is exactly ``cpython-3xx`` on CPython


def _platform_tag() -> str:
    """Return the SDK ``.so``'s platform suffix (``darwin`` / ``linux-gnu`` …)."""
    soabi = sysconfig.get_config_var("SOABI") or ""
    if "darwin" in soabi:
        return "darwin"
    if "linux" in soabi:
        return "linux-gnu"
    return ""


def _discover_spatialmp4_module_dir(home: Path) -> Optional[Path]:
    """Walk SPATIALMP4_HOME for a ``spatialmp4*.so`` matching this ABI.

    The SDK build emits to ``build/<variant>/python/spatialmp4.cpython-<tag>-<plat>.so``.
    We check the common locations cheaply and only `rglob` as a last
    resort to keep startup snappy on big trees.
    """
    abi = _abi_tag()
    plat = _platform_tag()
    expected_name = f"spatialmp4.{abi}-{plat}.so" if plat else f"spatialmp4.{abi}*.so"

    quick_candidates = [
        home / "build" / "host_py" / "python",
        home / "build" / f"python{abi.split('-')[-1] if '-' in abi else '313'}" / "python",
        home / "build" / "rerun_py310" / "python",
        home / "python",
    ]
    deps_root_env = os.environ.get("OPERATOR_DEPS_CACHE_ROOT")
    if deps_root_env:
        quick_candidates.append(Path(deps_root_env).expanduser() / "build" / "spatialmp4" / f"python{abi.split('-')[-1] if '-' in abi else '313'}" / "python")
    else:
        repo_root = Path(__file__).resolve().parents[3]
        quick_candidates.append(repo_root / ".deps" / "build" / "spatialmp4" / f"python{abi.split('-')[-1] if '-' in abi else '313'}" / "python")
    for c in quick_candidates:
        if c.is_dir() and any(c.glob(f"spatialmp4.{abi}-*.so")):
            return c

    # Fallback: scan the whole tree (shallow at first).
    for path in home.glob("build/**/python"):
        if path.is_dir() and any(path.glob(f"spatialmp4.{abi}-*.so")):
            return path

    return None


def _bootstrap_spatialmp4():
    """Make ``import spatialmp4`` work by locating the prebuilt ``.so``.

    Order of resolution:
      1. Already importable (pip-installed, on PYTHONPATH, …): use it.
      2. ``SPATIALMP4_HOME`` env var: discover matching .so, inject.
      3. Operator shared dependency cache under this repo.
      4. Hardcoded common dev paths.
      4. Fail with an actionable hint.
    """
    try:
        return importlib.import_module("spatialmp4")
    except ImportError:
        pass

    candidates: List[Path] = []
    env_home = os.environ.get("SPATIALMP4_HOME")
    if env_home:
        candidates.append(Path(env_home).expanduser().resolve())
    repo_root = Path(__file__).resolve().parents[3]
    deps_root = Path(os.environ.get("OPERATOR_DEPS_CACHE_ROOT", repo_root / ".deps"))
    candidates.append((deps_root / "src" / "SpatialMP4").expanduser().resolve())
    # Common dev checkout locations — first one that exists wins.
    candidates.extend(
        Path(p).expanduser()
        for p in (
            "~/ws/spatialmp4-quest/SpatialMP4",
            "~/spatialmp4-quest/SpatialMP4",
            "~/SpatialMP4",
        )
    )

    for home in candidates:
        if not home.is_dir():
            continue
        mod_dir = _discover_spatialmp4_module_dir(home)
        if mod_dir is None:
            continue
        info(f"injecting {mod_dir} for SpatialMP4 SDK (home={home})")
        sys.path.insert(0, str(mod_dir))
        try:
            return importlib.import_module("spatialmp4")
        except ImportError as exc:
            info(f"  import failed: {exc}; continuing search")
            sys.path.pop(0)
            continue

    abi = _abi_tag()
    fatal(
        "SpatialMP4 SDK not importable. Set SPATIALMP4_HOME to a checkout "
        f"that has a built `spatialmp4.{abi}-<plat>.so` under "
        "`build/<variant>/python/`, or pip-install the SDK into the env "
        "uv uses. The Node worker normally exports SPATIALMP4_HOME for you — "
        "check that the autodetect path resolved on the server or run "
        "scripts/setup_spatialmp4.sh."
    )


try:
    import numpy as np  # type: ignore
except ImportError:
    fatal("numpy missing — uv should have installed it from PEP 723 deps")

try:
    import cv2  # type: ignore  # only used for the depth colormap blend
except ImportError:
    fatal("opencv-python missing — uv should have installed it from PEP 723 deps")

try:
    import rerun as rr  # type: ignore
    import rerun.blueprint as rrb  # type: ignore
except ImportError:
    fatal("rerun-sdk missing — uv should have installed it from PEP 723 deps")

try:
    from scipy.spatial.transform import Rotation  # type: ignore
except ImportError:
    fatal("scipy missing — uv should have installed it from PEP 723 deps")

sm = _bootstrap_spatialmp4()


# ---------------------------------------------------------------------------
# Rerun compatibility shims (same as reference)
# ---------------------------------------------------------------------------


def set_time_seconds(name: str, seconds: float) -> None:
    """rerun 0.23 uses ``set_time_seconds`` while 0.30+ replaced it with
    ``set_time(timeline, duration=...)``. Support both."""
    if hasattr(rr, "set_time_seconds"):
        rr.set_time_seconds(name, seconds)  # type: ignore[attr-defined]
    else:
        rr.set_time(name, duration=float(seconds))


def log_transform3d(path: str, translation, rotation_xyzw, axis_len: float = 0.0) -> None:
    """Log a Transform3D; on older rerun SDKs that lack the ``axis_length``
    keyword we emit a small Arrows3D triad as a child entity instead."""
    transform_kwargs = {
        "translation": translation,
        "rotation": rr.Quaternion(xyzw=rotation_xyzw),
    }
    if axis_len > 0:
        try:
            rr.log(path, rr.Transform3D(axis_length=axis_len, **transform_kwargs))
            return
        except TypeError:
            pass
    rr.log(path, rr.Transform3D(**transform_kwargs))
    if axis_len > 0:
        rr.log(
            f"{path}/axes",
            rr.Arrows3D(
                vectors=[[axis_len, 0, 0], [0, axis_len, 0], [0, 0, axis_len]],
                colors=[[255, 60, 60], [60, 255, 60], [60, 60, 255]],
            ),
        )


# ---------------------------------------------------------------------------
# Pose math (mirrored from reference)
# ---------------------------------------------------------------------------


def ensure_right_handed_rotation(rotation_matrix: np.ndarray) -> np.ndarray:
    """Project a 3×3 matrix back onto SO(3). Extrinsic chains can drift
    a few ulps off orthonormal which makes Rerun's Transform3D parser
    unhappy; an SVD reproject is cheap insurance.
    """
    r = np.array(rotation_matrix, dtype=np.float64, copy=True)
    u, _, vh = np.linalg.svd(r)
    corrected = u @ vh
    if np.linalg.det(corrected) < 0:
        u[:, -1] *= -1
        corrected = u @ vh
    return corrected


def pose_frame_to_matrix(pose) -> np.ndarray:
    mat = np.eye(4, dtype=np.float64)
    rot = Rotation.from_quat([pose.qx, pose.qy, pose.qz, pose.qw]).as_matrix()
    mat[:3, :3] = rot
    mat[:3, 3] = [pose.x, pose.y, pose.z]
    return mat


# ---------------------------------------------------------------------------
# Head-pose lookup (binary-search by timestamp)
# ---------------------------------------------------------------------------


class PoseLookup:
    """Sorted-by-timestamp head pose track with nearest-neighbour lookup.

    Used to attach each RGB/depth frame to the head pose that was
    closest in time at capture; the muxed mp4 stores pose on its own
    timed-metadata track so this lookup is the only correct way to
    rebuild ``T_W_camera`` per video frame.
    """

    def __init__(self, frames: Sequence) -> None:
        valid = [f for f in frames if f.timestamp > 0]
        valid.sort(key=lambda f: f.timestamp)
        self._ts = [f.timestamp for f in valid]
        self._frames = valid

    def __len__(self) -> int:
        return len(self._frames)

    def empty(self) -> bool:
        return len(self._frames) == 0

    def nearest(self, t: float):
        if not self._frames:
            return None
        idx = bisect.bisect_left(self._ts, t)
        candidates = []
        if idx < len(self._ts):
            candidates.append(idx)
        if idx > 0:
            candidates.append(idx - 1)
        best = min(candidates, key=lambda i: abs(self._ts[i] - t))
        return self._frames[best]

    def trajectory_xyz(self) -> np.ndarray:
        return np.array(
            [[f.x, f.y, f.z] for f in self._frames], dtype=np.float64
        )

    @property
    def frames(self):
        return self._frames


# ---------------------------------------------------------------------------
# Device profile (Quest vs Pico)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DeviceProfile:
    """Per-device knobs the reference SDK encodes by having two separate
    scripts (``visualize_rerun_quest.py`` vs ``visualize_rerun_pico.py``).

    Three axes of difference:
      * ``head_is_imu``        — does the ``head`` mett track / per-frame
                                 ``pose`` already represent the IMU pose
                                 (Quest) or the mid-eye head pose (Pico)?
                                 Pico's needs the SDK ``head_to_imu``
                                 convention conversion before composing
                                 with RGB / depth extrinsics.
      * ``head_model_offset``  — translation offset supplied to the SDK
                                 conversion above. Pico follows the
                                 SpatialMP4 reference path and uses
                                 ``HEAD_MODEL_OFFSET`` unless the caller
                                 explicitly supplies another offset.
      * ``extrinsic_perm``     — 4×4 axis swap applied to the composed
                                 ``T_W_S`` for both RGB and depth cameras
                                 before handing it to Rerun. Quest = None
                                 (identity); Pico maps native (X,Y,Z) →
                                 (Z,X,Y) so the device-local axes line
                                 up with Rerun's world.
      * ``native_from_capture`` — 3×3 basis change from the raw capture
                                 world used by Godot hand/controller joints
                                 into the native world expected by Pico's
                                 ``head_to_imu`` / camera extrinsics path.
                                 Quest = None (identity).
      * ``camera_view_coord``  — Pinhole's ``camera_xyz``. Quest = RDF
                                 (OpenCV image axes); Pico = UBR (X-up,
                                 Y-back, Z-right).
      * ``camera_from_sensor`` — 3×3 local-frame rotation from the MP4
                                 RGB/depth extrinsic's sensor axes to the
                                 logical camera axes described by
                                 ``camera_view_coord``. Quest's Camera2
                                 writer already uses RDF. Our Pico
                                 XR_PICO_camera_image writer stores the raw
                                 SDK frame (URF), so we normalize it to the
                                 reference viewer's UBR frame here without
                                 moving the optical center.
      * ``image_rdf_from_camera`` — optional 3×3 local-frame mapping used
                                 only by our manual 2D overlay projection.
                                 It must not be applied to the Rerun
                                 Transform3D / Pinhole coordinate chain.
    """
    name: str
    head_is_imu: bool
    head_model_offset: Optional[np.ndarray]
    extrinsic_perm: Optional[np.ndarray]
    native_from_capture: Optional[np.ndarray]
    camera_view_coord: str
    camera_from_sensor: Optional[np.ndarray]
    image_rdf_from_camera: Optional[np.ndarray]


@dataclass(frozen=True)
class Camera2ProjectionCalibration:
    """Quest Camera2 sidecar calibration for accurate 2D RGB overlays.

    The mp4 `ecam` descriptor is suitable for the 3D Rerun camera pose, but
    Quest's Camera2 `lens_pose_*` sidecar needs the OpenQuest conversion used by
    SpatialMP4's reference alignment tools before projecting world points into
    the RGB image plane.
    """
    head_from_camera_unity: np.ndarray
    K_rgb: np.ndarray
    width: int
    height: int


UNITY_FROM_GODOT_3 = np.diag([1.0, 1.0, -1.0])
UNITY_FROM_GODOT_4 = np.diag([1.0, 1.0, -1.0, 1.0])


_PICO_PERM = np.array(
    [
        [0.0, 0.0, 1.0, 0.0],
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ],
    dtype=np.float64,
)

_PICO_NATIVE_FROM_CAPTURE = np.array(
    [
        [0.0, 1.0, 0.0],
        [-1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0],
    ],
    dtype=np.float64,
)

# Our XR_PICO_camera_image side data stores the raw SDK camera local frame:
# X=up, Y=right, Z=forward (URF). The SpatialMP4 Pico reference viewer logs
# the camera as UBR (X=up, Y=back, Z=right). Convert the local basis by
# right-multiplying the raw sensor pose with sensor_from_camera:
#   raw_sensor_from_ubr = [[1, 0, 0], [0, 0, 1], [0, -1, 0]]
# ``camera_from_sensor`` stores the inverse direction for the profile API.
_PICO_UBR_FROM_RAW_SENSOR = np.array(
    [
        [1.0, 0.0, 0.0],
        [0.0, 0.0, -1.0],
        [0.0, 1.0, 0.0],
    ],
    dtype=np.float64,
)

PROFILE_QUEST = DeviceProfile(
    name="quest",
    head_is_imu=True,
    head_model_offset=None,
    extrinsic_perm=None,
    native_from_capture=None,
    camera_view_coord="RDF",
    camera_from_sensor=None,
    image_rdf_from_camera=None,
)

PROFILE_PICO = DeviceProfile(
    name="pico",
    # Per Pico OpenXR XR_PICO_camera_image semantics confirmed for this
    # project: the lens_pose returned by xrGetCameraExtrinsicsPICO is in
    # XR_REFERENCE_SPACE_TYPE_VIEW with OpenXR right-handed convention.
    # That is the same space `XRCamera3D.global_transform` tracks, so the
    # chain collapses to T_W_S = T_W_H @ T_I_S directly with T_H_I = identity.
    # No SDK head_to_imu axis swap is appropriate for this recording.
    head_is_imu=True,
    head_model_offset=None,
    extrinsic_perm=None,
    native_from_capture=None,
    # Pico's T_I_S rotation is R_x(180°), so the sensor's local frame is
    # already RDF (X right, Y down, Z forward) in the head's RUB frame.
    camera_view_coord="RDF",
    camera_from_sensor=None,
    image_rdf_from_camera=None,
)


def detect_device_profile(
    explicit: Optional[str],
    manifest_path: Optional[Path],
) -> DeviceProfile:
    """Resolve which profile to use, with these priorities:
      1. explicit ``--device-type`` CLI value (``quest`` / ``pico``)
      2. manifest's ``device.device_type`` field, normalised
      3. fall back to Quest (the ingest's primary target hardware)
    """
    candidate = (explicit or "").strip().lower()
    if not candidate and manifest_path is not None and manifest_path.exists():
        try:
            mf = json.loads(manifest_path.read_text())
            candidate = str(mf.get("device", {}).get("device_type", "")).strip().lower()
        except (json.JSONDecodeError, OSError) as exc:
            info(f"manifest read failed ({manifest_path}): {exc}; defaulting to quest")
            candidate = ""

    if candidate.startswith("pico"):
        info("device profile: PICO (T_W_S = T_W_H @ T_I_S, sensor RDF, view-space extrinsic)")
        return PROFILE_PICO
    if candidate.startswith("quest"):
        info("device profile: QUEST (head==IMU, RDF camera, no axis perm)")
        return PROFILE_QUEST
    info(f"device profile: defaulting to QUEST (manifest hint='{candidate}')")
    return PROFILE_QUEST


def head_pose_matrix(pose, profile: DeviceProfile) -> np.ndarray:
    """4×4 camera-root pose for a head sample, per device profile.

    Quest: the head mett track already stores the IMU pose, so return
    pose verbatim. Pico: the per-frame pose is mid-eye in the raw
    capture convention, so we apply the SDK's ``head_to_imu`` helper to
    match Pico's axis/quaternion convention. The profile controls the
    translation offset: official SpatialMP4 Pico reference captures use
    ``HEAD_MODEL_OFFSET``; a non-None profile value overrides that for
    explicitly device-relative inputs.
    """
    mat = pose_frame_to_matrix(pose)
    if profile.head_is_imu:
        return mat
    offset = profile.head_model_offset
    if offset is None:
        offset = sm.HEAD_MODEL_OFFSET
    return sm.head_to_imu(mat, offset)


def godot_transform_to_unity(transform_godot: np.ndarray) -> np.ndarray:
    """Convert Godot/OpenXR RUB transform to Unity-style X-right/Y-up/Z-forward."""
    return UNITY_FROM_GODOT_4 @ transform_godot @ UNITY_FROM_GODOT_4


def _camera2_projection_from_characteristics(
    char: Dict[str, Any],
    source_label: str,
) -> Optional[Camera2ProjectionCalibration]:
    try:
        translation = char.get("lens_pose_translation") or [0.0, 0.0, 0.0]
        raw_rotation = char.get("lens_pose_rotation") or [0.0, 0.0, 0.0, 1.0]
        intrinsics = char.get("lens_intrinsic_calibration") or []
        if len(intrinsics) < 4:
            info(f"Camera2 calibration missing intrinsics: {source_label}")
            return None
        fx, fy, cx, cy = (float(v) for v in intrinsics[:4])
        size = char.get("sensor_active_array_size") or char.get("sensor_pixel_array_size") or {}
        width = int(size.get("width") or (int(size["right"]) - int(size.get("left", 0))))
        height = int(size.get("height") or (int(size["bottom"]) - int(size.get("top", 0))))
    except (KeyError, TypeError, ValueError) as exc:
        info(f"Camera2 calibration read failed ({source_label}): {exc}; falling back to mp4 ecam projection")
        return None

    raw_quat = np.asarray(raw_rotation, dtype=np.float64)
    raw_norm = np.linalg.norm(raw_quat)
    if not np.isfinite(raw_norm) or raw_norm <= 0.0:
        info(f"Camera2 calibration has invalid rotation: {source_label}; falling back to mp4 ecam projection")
        return None
    converted_quat = np.array(
        [-raw_quat[0], -raw_quat[1], raw_quat[2], raw_quat[3]],
        dtype=np.float64,
    )
    converted_quat /= max(np.linalg.norm(converted_quat), 1e-12)
    rotation_unity = (
        Rotation.from_quat(converted_quat).as_matrix().T @ np.diag([1.0, -1.0, -1.0])
    )
    head_from_camera_unity = np.eye(4, dtype=np.float64)
    head_from_camera_unity[:3, :3] = rotation_unity
    head_from_camera_unity[:3, 3] = [
        float(translation[0]),
        float(translation[1]),
        -float(translation[2]),
    ]
    K_rgb = np.array(
        [[fx, 0.0, cx], [0.0, fy, cy], [0.0, 0.0, 1.0]],
        dtype=np.float64,
    )
    return Camera2ProjectionCalibration(
        head_from_camera_unity=head_from_camera_unity,
        K_rgb=K_rgb,
        width=width,
        height=height,
    )


def _extract_camera2_characteristics(
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


def load_camera2_projection_calibration(
    input_path: Path,
    profile: DeviceProfile,
    eye: str = "left",
    operator_static: Optional[Dict[str, Any]] = None,
) -> Optional[Camera2ProjectionCalibration]:
    """Load Quest Camera2 calibration for accurate RGB image projection.

    Mirrors SpatialMP4's `godot_depth_rgb_align._openquest_head_from_camera`.
    This is intentionally Quest-only; Pico has different axis conventions and
    currently no validated sidecar path in this web converter.
    """
    if profile.name != "quest":
        return None

    embedded_char = _extract_camera2_characteristics(operator_static, eye)
    if embedded_char is not None:
        projection = _camera2_projection_from_characteristics(
            embedded_char,
            f"MP4 operator_static {eye} Camera2 characteristics",
        )
        if projection is not None:
            info(
                "loaded Quest Camera2 projection calibration from MP4 "
                f"operator_static ({eye})"
            )
            return projection

    sidecar_filename = f"{eye}_camera_characteristics.json"
    sidecar_candidates = [
        # On-device/local layout: <capture_root>/<session>.mp4 plus
        # <capture_root>/<session>/<eye>_camera_characteristics.json.
        input_path.with_suffix("") / sidecar_filename,
        # Uploaded layout: <data>/<session>/media.mp4 plus sidecars stored as
        # sibling artifacts in the same session directory.
        input_path.parent / sidecar_filename,
    ]
    sidecar_path = next((p for p in sidecar_candidates if p.exists()), None)
    if sidecar_path is None:
        return None
    try:
        sidecar_char: Dict[str, Any] = json.loads(sidecar_path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        info(f"Camera2 sidecar read failed ({sidecar_path}): {exc}; falling back to mp4 ecam projection")
        return None
    projection = _camera2_projection_from_characteristics(sidecar_char, str(sidecar_path))
    if projection is None:
        return None
    info(
        f"loaded Quest Camera2 sidecar projection calibration: {sidecar_path} "
        "(RGB hand overlay uses OpenQuest Camera2 conversion)"
    )
    return projection


def device_native_camera_pose(T_W_S: np.ndarray, profile: DeviceProfile) -> np.ndarray:
    """Convert a device-native sensor pose to the logical camera pose.

    ``T_W_S`` comes straight from MP4 extrinsics composed with the device
    camera-root pose. Some providers store a sensor-local frame whose X/Y axes
    are rolled relative to the encoded image. Right-multiplying by
    ``sensor_from_camera`` changes only the camera's local basis; the optical
    center and forward axis stay fixed.
    """
    if profile.camera_from_sensor is None:
        return T_W_S
    sensor_from_camera = profile.camera_from_sensor.T
    T_W_C = np.array(T_W_S, dtype=np.float64, copy=True)
    T_W_C[:3, :3] = T_W_C[:3, :3] @ sensor_from_camera
    return T_W_C


def compose_world_sensor_pose(
    head_pose,
    T_I_S: np.ndarray,
    profile: DeviceProfile,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Compose the projection chain in one place.

    Symbolically this is the chain the RGB hand overlay relies on:

      ``T_W_I = T_W_H @ T_H_I``
      ``T_W_S = T_W_I @ T_I_S``
      ``T_S_hand = inverse(T_W_S) @ T_W_hand``

    For Quest, ``head_pose_matrix`` is the identity interpretation:
    the ``head`` track already stores ``T_W_I``. For Pico, the SpatialMP4
    SDK reference represents the ``T_W_H @ T_H_I`` step with
    ``sm.head_to_imu(T_W_H, HEAD_MODEL_OFFSET)``; that helper also moves
    the pose into the Pico-native axis convention, so Pico hand points must
    be converted into the same native world before projection.

    Returns ``(T_W_I, T_W_S_sensor, T_W_S_camera)``. The ``sensor`` matrix is
    the raw MP4 extrinsic composition. The ``camera`` matrix has only the
    sensor-local axes normalized for the profile's Pinhole/projection
    convention; the optical center is unchanged.
    """
    T_W_I = head_pose_matrix(head_pose, profile)
    T_W_S_sensor = T_W_I @ T_I_S
    T_W_S_camera = device_native_camera_pose(T_W_S_sensor, profile)
    return T_W_I, T_W_S_sensor, T_W_S_camera


def device_logged_camera_pose(T_W_S: np.ndarray, profile: DeviceProfile) -> np.ndarray:
    """The matrix we hand to Rerun for ``world/camera`` Transform3D.

    Pico stores extrinsics in a frame that doesn't line up with Rerun
    world axes; apply the published cyclic permutation before logging
    (see ``pico_pose_to_open3d`` in the reference). Quest is a no-op.

    The camera's local sensor axes are first converted into the profile's
    ``camera_view_coord`` convention. Then Pico's world-axis permutation is a
    left multiply only. Generic capture poses use a full similarity transform
    instead.
    """
    T_W_C = device_native_camera_pose(T_W_S, profile)
    if profile.extrinsic_perm is None:
        return T_W_C
    return profile.extrinsic_perm @ T_W_C


def _matrix4_from_rotation3(rotation: Optional[np.ndarray]) -> Optional[np.ndarray]:
    if rotation is None:
        return None
    mat = np.eye(4, dtype=np.float64)
    mat[:3, :3] = rotation
    return mat


def device_native_capture_points(points: np.ndarray, profile: DeviceProfile) -> np.ndarray:
    """Convert raw capture-world points to the device-native world frame.

    Pico's ``head_to_imu`` changes the raw Godot/OpenXR world basis before
    composing camera extrinsics. Hand joints are still recorded in raw
    capture world, so RGB projection must apply the same basis change first.
    """
    if profile.native_from_capture is None:
        return points
    return points @ profile.native_from_capture.T


def device_logged_native_points(points: np.ndarray, profile: DeviceProfile) -> np.ndarray:
    """Convert device-native world points to the Rerun logged world frame."""
    if profile.extrinsic_perm is None:
        return points
    return points @ profile.extrinsic_perm[:3, :3].T


def device_logged_capture_points(points: np.ndarray, profile: DeviceProfile) -> np.ndarray:
    """Convert raw capture-world points to the Rerun logged world frame."""
    return device_logged_native_points(device_native_capture_points(points, profile), profile)


def project_capture_points_to_image(
    capture_world_pts: np.ndarray,
    T_W_S_camera: np.ndarray,
    K,
    width: int,
    height: int,
    profile: DeviceProfile,
) -> Tuple[np.ndarray, np.ndarray]:
    """Project raw capture-world points through the profile's RGB camera.

    ``capture_world_pts`` are the SDK hand joints (``T_W_hand`` points). Pico
    captures store them in the raw Godot/OpenXR world basis, while
    ``compose_world_sensor_pose`` has already moved the head/camera path into
    Pico-native world through ``sm.head_to_imu``. Applying
    ``device_native_capture_points`` here makes both sides of
    ``T_S_hand = inverse(T_W_S) @ T_W_hand`` live in the same world frame.
    """
    world_pts = device_native_capture_points(capture_world_pts, profile)
    return project_world_points_to_image(
        world_pts,
        T_W_S_camera,
        K,
        width,
        height,
        profile.camera_view_coord,
        image_rdf_from_camera=profile.image_rdf_from_camera,
    )


def device_logged_capture_pose(T_W_A: np.ndarray, profile: DeviceProfile) -> np.ndarray:
    """Convert a raw capture-world pose to the logged Rerun world frame.

    Unlike cameras, generic poses (head marker, controllers) keep their local
    axes in the same named coordinate basis as the world, so they need a basis
    similarity ``M @ T @ M.T``.
    """
    native_from_capture = _matrix4_from_rotation3(profile.native_from_capture)
    logged_from_native = profile.extrinsic_perm
    if native_from_capture is None and logged_from_native is None:
        return T_W_A

    logged_from_capture = np.eye(4, dtype=np.float64)
    if native_from_capture is not None:
        logged_from_capture = native_from_capture @ logged_from_capture
    if logged_from_native is not None:
        logged_from_capture = logged_from_native @ logged_from_capture
    return logged_from_capture @ T_W_A @ logged_from_capture.T


# ---------------------------------------------------------------------------
# OpenXR hand-skeleton metadata (XR_EXT_hand_tracking, 26 joints)
#   Same naming + bone topology as the reference so behaviour matches.
# ---------------------------------------------------------------------------


XR_HAND_JOINT_NAMES: Tuple[str, ...] = (
    "PALM",
    "WRIST",
    "THUMB_METACARPAL", "THUMB_PROXIMAL", "THUMB_DISTAL", "THUMB_TIP",
    "INDEX_METACARPAL", "INDEX_PROXIMAL", "INDEX_INTERMEDIATE",
    "INDEX_DISTAL", "INDEX_TIP",
    "MIDDLE_METACARPAL", "MIDDLE_PROXIMAL", "MIDDLE_INTERMEDIATE",
    "MIDDLE_DISTAL", "MIDDLE_TIP",
    "RING_METACARPAL", "RING_PROXIMAL", "RING_INTERMEDIATE",
    "RING_DISTAL", "RING_TIP",
    "LITTLE_METACARPAL", "LITTLE_PROXIMAL", "LITTLE_INTERMEDIATE",
    "LITTLE_DISTAL", "LITTLE_TIP",
)


# (parent_id, child_id) pairs for each finger chain, rooted at WRIST(1).
XR_HAND_BONES: Tuple[Tuple[int, int], ...] = (
    # Thumb
    (1, 2), (2, 3), (3, 4), (4, 5),
    # Index
    (1, 6), (6, 7), (7, 8), (8, 9), (9, 10),
    # Middle
    (1, 11), (11, 12), (12, 13), (13, 14), (14, 15),
    # Ring
    (1, 16), (16, 17), (17, 18), (18, 19), (19, 20),
    # Little
    (1, 21), (21, 22), (22, 23), (23, 24), (24, 25),
)


HAND_COLORS: Dict[str, Tuple[int, int, int]] = {
    "left_hand": (80, 180, 255),
    "right_hand": (255, 160, 80),
}

# Hands are normally 60-90 Hz while RGB/body/head are lower or similar rate.
# Cap nearest-neighbour matches so a brief hand-tracking gap does not leave
# stale hand positions connected to live body joints.
HAND_FRAME_MATCH_MAX_DT = 0.08


# ---------------------------------------------------------------------------
# BD body-skeleton metadata (PICO XR_BD_body_tracking, 24 joints)
#   Joint ids mirror xr/native/pico_openxr/src/pico_openxr_defs.h
#   (XR_BODY_JOINT_*_BD). The mp4 `mett` track kind is "body_joints" and the
#   payload shares the count-driven HJNT layout with hand joints, so the SDK
#   returns the same HandJointsFrame objects.
# ---------------------------------------------------------------------------


BD_BODY_JOINT_NAMES: Tuple[str, ...] = (
    "PELVIS",
    "LEFT_HIP", "RIGHT_HIP",
    "SPINE1",
    "LEFT_KNEE", "RIGHT_KNEE",
    "SPINE2",
    "LEFT_ANKLE", "RIGHT_ANKLE",
    "SPINE3",
    "LEFT_FOOT", "RIGHT_FOOT",
    "NECK",
    "LEFT_COLLAR", "RIGHT_COLLAR",
    "HEAD",
    "LEFT_SHOULDER", "RIGHT_SHOULDER",
    "LEFT_ELBOW", "RIGHT_ELBOW",
    "LEFT_WRIST", "RIGHT_WRIST",
    "LEFT_HAND", "RIGHT_HAND",
)


# (parent_id, child_id) pairs, SMPL-style topology rooted at PELVIS(0).
BD_BODY_BONES: Tuple[Tuple[int, int], ...] = (
    # Spine chain
    (0, 3), (3, 6), (6, 9), (9, 12), (12, 15),
    # Legs
    (0, 1), (1, 4), (4, 7), (7, 10),
    (0, 2), (2, 5), (5, 8), (8, 11),
    # Arms (collar -> shoulder -> elbow -> wrist -> hand)
    (9, 13), (13, 16), (16, 18), (18, 20), (20, 22),
    (9, 14), (14, 17), (17, 19), (19, 21), (21, 23),
)


BODY_COLOR: Tuple[int, int, int] = (110, 235, 130)
# Body joints carry radius_m=0 (no per-joint radius from the runtime); use a
# larger default than the 4 mm hand fallback so the skeleton reads at room
# scale.
BODY_JOINT_RADIUS_M = 0.02
BODY_HAND_BRIDGE_RADIUS_M = 0.004


# ---------------------------------------------------------------------------
# Godot XRBodyTracker body-skeleton metadata (87 joints, the superset every
# OpenXR humanoid body extension feeds into Godot's XRBodyTracker). Quest
# captures land here when the Meta vendor AAR negotiates either
# XR_FB_body_tracking (~70 upper-body joints active, lower body flagged out)
# or XR_META_body_tracking_full_body (~84 joints active with IK-inferred legs).
# Joint ids mirror the C++ enum at
#   godot/servers/xr/xr_body_tracker.h::XRBodyTracker::Joint
# Names match Godot's enum verbatim — losing the `JOINT_` prefix only.
# ---------------------------------------------------------------------------


GODOT_XR_BODY_JOINT_NAMES: Tuple[str, ...] = (
    "ROOT",                                                    # 0
    # Upper body
    "HIPS", "SPINE", "CHEST", "UPPER_CHEST", "NECK", "HEAD",   # 1..6
    "HEAD_TIP",                                                # 7
    "LEFT_SHOULDER", "LEFT_UPPER_ARM", "LEFT_LOWER_ARM",       # 8..10
    "RIGHT_SHOULDER", "RIGHT_UPPER_ARM", "RIGHT_LOWER_ARM",    # 11..13
    # Lower body
    "LEFT_UPPER_LEG", "LEFT_LOWER_LEG", "LEFT_FOOT", "LEFT_TOES",       # 14..17
    "RIGHT_UPPER_LEG", "RIGHT_LOWER_LEG", "RIGHT_FOOT", "RIGHT_TOES",   # 18..21
    # Left hand
    "LEFT_HAND", "LEFT_PALM", "LEFT_WRIST",                                              # 22..24
    "LEFT_THUMB_METACARPAL", "LEFT_THUMB_PHALANX_PROXIMAL",
    "LEFT_THUMB_PHALANX_DISTAL", "LEFT_THUMB_TIP",                                       # 25..28
    "LEFT_INDEX_METACARPAL", "LEFT_INDEX_PROXIMAL",
    "LEFT_INDEX_INTERMEDIATE", "LEFT_INDEX_DISTAL", "LEFT_INDEX_TIP",                    # 29..33
    "LEFT_MIDDLE_METACARPAL", "LEFT_MIDDLE_PROXIMAL",
    "LEFT_MIDDLE_INTERMEDIATE", "LEFT_MIDDLE_DISTAL", "LEFT_MIDDLE_TIP",                 # 34..38
    "LEFT_RING_METACARPAL", "LEFT_RING_PROXIMAL",
    "LEFT_RING_INTERMEDIATE", "LEFT_RING_DISTAL", "LEFT_RING_TIP",                       # 39..43
    "LEFT_PINKY_METACARPAL", "LEFT_PINKY_PROXIMAL",
    "LEFT_PINKY_INTERMEDIATE", "LEFT_PINKY_DISTAL", "LEFT_PINKY_TIP",                    # 44..48
    # Right hand
    "RIGHT_HAND", "RIGHT_PALM", "RIGHT_WRIST",                                           # 49..51
    "RIGHT_THUMB_METACARPAL", "RIGHT_THUMB_PHALANX_PROXIMAL",
    "RIGHT_THUMB_PHALANX_DISTAL", "RIGHT_THUMB_TIP",                                     # 52..55
    "RIGHT_INDEX_METACARPAL", "RIGHT_INDEX_PROXIMAL",
    "RIGHT_INDEX_INTERMEDIATE", "RIGHT_INDEX_DISTAL", "RIGHT_INDEX_TIP",                 # 56..60
    "RIGHT_MIDDLE_METACARPAL", "RIGHT_MIDDLE_PROXIMAL",
    "RIGHT_MIDDLE_INTERMEDIATE", "RIGHT_MIDDLE_DISTAL", "RIGHT_MIDDLE_TIP",              # 61..65
    "RIGHT_RING_METACARPAL", "RIGHT_RING_PROXIMAL",
    "RIGHT_RING_INTERMEDIATE", "RIGHT_RING_DISTAL", "RIGHT_RING_TIP",                    # 66..70
    "RIGHT_PINKY_METACARPAL", "RIGHT_PINKY_PROXIMAL",
    "RIGHT_PINKY_INTERMEDIATE", "RIGHT_PINKY_DISTAL", "RIGHT_PINKY_TIP",                 # 71..75
    # Extra precision joints (Godot 4.5 added them late so they sit at the tail)
    "LOWER_CHEST",                                                                       # 76
    "LEFT_SCAPULA", "LEFT_WRIST_TWIST",                                                   # 77..78
    "RIGHT_SCAPULA", "RIGHT_WRIST_TWIST",                                                 # 79..80
    "LEFT_FOOT_TWIST", "LEFT_HEEL", "LEFT_MIDDLE_FOOT",                                   # 81..83
    "RIGHT_FOOT_TWIST", "RIGHT_HEEL", "RIGHT_MIDDLE_FOOT",                                # 84..86
)
assert len(GODOT_XR_BODY_JOINT_NAMES) == 87, "Godot XRBodyTracker has 87 joints (id 0..86)"


# Body bone chain for Godot XRBodyTracker — kinematic parent → child pairs.
# Keep HAND/PALM/WRIST as coarse bridge joints so the body skeleton connects
# to the dedicated hand-joint stream. Finger joints are still filtered below;
# drawing the full body-hand fingers on top of the hand_joints stream produced
# two overlapping hand skeletons.
GODOT_XR_BODY_BONES: Tuple[Tuple[int, int], ...] = (
    # Spine
    (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7),
    # Left arm
    (4, 8), (8, 9), (9, 10), (10, 22), (22, 24), (22, 23),
    # Right arm
    (4, 11), (11, 12), (12, 13), (13, 49), (49, 51), (49, 50),
    # Left leg
    (1, 14), (14, 15), (15, 16), (16, 17),
    # Right leg
    (1, 18), (18, 19), (19, 20), (20, 21),
)

# Joint ids that the body track shares with the dedicated hand-joint streams
# (Godot XRBodyTracker enum: hand finger joints under ids 25..48 and 52..75).
# HAND/PALM/WRIST (22..24 and 49..51) stay in the body render as bridge points
# so lower arms visibly connect to the hand stream.
GODOT_XR_BODY_HAND_JOINT_IDS: frozenset[int] = frozenset(
    [*range(25, 49), *range(52, 76)]
)

# Body-track bridge joints to dedicated OpenXR hand-track joints. The body
# endpoints are preserved and rendered; these pairs only add visual connector
# lines to the higher-fidelity hand skeleton.
BodyHandBridgeMap = Dict[str, Tuple[Tuple[int, int], ...]]

GODOT_XR_BODY_TO_HAND_BRIDGES: BodyHandBridgeMap = {
    "left_hand": ((24, 1), (23, 0)),
    "right_hand": ((51, 1), (50, 0)),
}
NO_BODY_TO_HAND_BRIDGES: BodyHandBridgeMap = {}


def _body_skeleton_for_manifest(
    manifest_data: Optional[dict],
) -> Tuple[
    Tuple[str, ...],
    Tuple[Tuple[int, int], ...],
    frozenset[int],
    BodyHandBridgeMap,
]:
    """Pick body render tables that match the manifest's joint set. Falls
    back to BD-24 only when the manifest explicitly says so — anything else
    (Quest, unknown) defaults to the broader Godot/Meta 87-joint set, which is
    what the body_motion_sampler writes when the Meta vendor AAR is the
    runtime.

    `hand_joint_ids` is the set of body-track joints that overlap the
    dedicated hand_joints stream; the per-frame logger drops them so the
    two skeletons never render on top of each other.

    `body_to_hand_bridges` is skeleton-specific. Pico BD-24 joint id 23 is
    RIGHT_HAND, while the Godot/Meta map treats 23 as LEFT_PALM, so Pico must
    not reuse the Quest/Godot bridge map.
    """
    joint_set = ""
    device_type = ""
    if manifest_data:
        sources = manifest_data.get("sources", {}) if isinstance(manifest_data.get("sources"), dict) else {}
        body = sources.get("body_tracking", {}) if isinstance(sources.get("body_tracking"), dict) else {}
        joint_set = str(body.get("joint_set", "")).strip()
        device_type = str(manifest_data.get("device", {}).get("device_type", "")).strip().lower()
    if joint_set == "pico_bd_24" or (joint_set == "" and device_type.startswith("pico")):
        # BD's LEFT_HAND (22) and RIGHT_HAND (23) are coarse end-of-arm
        # markers already covered by the hand stream's wrist/palm — hide them.
        return (
            BD_BODY_JOINT_NAMES,
            BD_BODY_BONES,
            frozenset({22, 23}),
            NO_BODY_TO_HAND_BRIDGES,
        )
    return (
        GODOT_XR_BODY_JOINT_NAMES,
        GODOT_XR_BODY_BONES,
        GODOT_XR_BODY_HAND_JOINT_IDS,
        GODOT_XR_BODY_TO_HAND_BRIDGES,
    )

CONTROLLER_COLORS: Dict[str, Tuple[int, int, int]] = {
    "left_controller": (120, 220, 255),
    "right_controller": (255, 200, 120),
}

CONTROLLER_INPUT_BITS: Tuple[Tuple[str, int], ...] = (
    ("TRIGGER_CLICK", 0), ("TRIGGER_TOUCH", 1),
    ("GRIP_CLICK", 2),
    ("THUMBSTICK_CLICK", 3), ("THUMBSTICK_TOUCH", 4),
    ("A_CLICK", 5), ("A_TOUCH", 6),
    ("B_CLICK", 7), ("B_TOUCH", 8),
    ("X_CLICK", 9), ("X_TOUCH", 10),
    ("Y_CLICK", 11), ("Y_TOUCH", 12),
    ("MENU_CLICK", 13), ("SYSTEM_CLICK", 14),
    ("THUMBREST_TOUCH", 15),
    ("TRACKPAD_CLICK", 16), ("TRACKPAD_TOUCH", 17),
)


# ---------------------------------------------------------------------------
# Per-track loggers
# ---------------------------------------------------------------------------


def log_hand_frame(track_id: str, hand_frame, profile: DeviceProfile) -> None:
    """Log hand joints + bones directly in world coordinates."""
    joints = hand_frame.joints
    if not joints:
        return

    positions = device_logged_capture_points(
        np.array([[j.x, j.y, j.z] for j in joints], dtype=np.float64),
        profile,
    )
    joint_ids = np.array([int(j.joint_id) for j in joints], dtype=np.int32)
    radii = np.array(
        [max(float(j.radius_m), 0.004) for j in joints], dtype=np.float32
    )

    color = HAND_COLORS.get(track_id, (200, 200, 200))
    labels = [
        XR_HAND_JOINT_NAMES[i] if 0 <= i < len(XR_HAND_JOINT_NAMES) else f"J{i}"
        for i in joint_ids
    ]

    rr.log(
        f"world/hands/{track_id}/joints",
        rr.Points3D(
            positions=positions,
            radii=radii,
            colors=[color] * len(joints),
            labels=labels,
            show_labels=False,
        ),
    )

    id_to_idx = {int(jid): i for i, jid in enumerate(joint_ids)}
    strips = [
        np.stack([positions[id_to_idx[p]], positions[id_to_idx[c]]], axis=0)
        for p, c in XR_HAND_BONES
        if p in id_to_idx and c in id_to_idx
    ]
    if strips:
        rr.log(
            f"world/hands/{track_id}/bones",
            rr.LineStrips3D(
                strips=strips, colors=[color] * len(strips), radii=0.0025
            ),
        )


def log_hand_frame_head_relative(track_id: str, hand_frame, head_lookup: PoseLookup) -> None:
    """Log hand joints in the head's local frame so the user can see hand
    motion relative to the head (independent of where the user walked).

    X_H = R^T (X_W - t) where T_W_H = [R | t] is the world-from-head pose.
    """
    joints = hand_frame.joints
    if not joints:
        return
    head = head_lookup.nearest(hand_frame.timestamp)
    if head is None:
        return

    T_W_H = pose_frame_to_matrix(head)
    R = T_W_H[:3, :3]
    t = T_W_H[:3, 3]
    positions_world = np.array([[j.x, j.y, j.z] for j in joints], dtype=np.float64)
    # (p - t) @ R is the per-row equivalent of R^T @ (p - t).
    positions_head = (positions_world - t) @ R

    joint_ids = np.array([int(j.joint_id) for j in joints], dtype=np.int32)
    radii = np.array(
        [max(float(j.radius_m), 0.004) for j in joints], dtype=np.float32
    )
    color = HAND_COLORS.get(track_id, (200, 200, 200))
    labels = [
        XR_HAND_JOINT_NAMES[i] if 0 <= i < len(XR_HAND_JOINT_NAMES) else f"J{i}"
        for i in joint_ids
    ]

    rr.log(
        f"head_relative/hands/{track_id}/joints",
        rr.Points3D(
            positions=positions_head,
            radii=radii,
            colors=[color] * len(joints),
            labels=labels,
            show_labels=False,
        ),
    )

    id_to_idx = {int(jid): i for i, jid in enumerate(joint_ids)}
    strips = [
        np.stack([positions_head[id_to_idx[p]], positions_head[id_to_idx[c]]], axis=0)
        for p, c in XR_HAND_BONES
        if p in id_to_idx and c in id_to_idx
    ]
    if strips:
        rr.log(
            f"head_relative/hands/{track_id}/bones",
            rr.LineStrips3D(
                strips=strips, colors=[color] * len(strips), radii=0.0025
            ),
        )


_body_unknown_joint_warned = False
# The skeleton table is selected once per run from the manifest (see
# _body_skeleton_for_manifest), then read by the per-frame loggers below.
# Defaults to the Godot/Meta superset so a missing/short manifest still draws
# the broader Quest skeleton instead of silently truncating bones.
_BODY_JOINT_NAMES: Tuple[str, ...] = GODOT_XR_BODY_JOINT_NAMES
_BODY_BONES: Tuple[Tuple[int, int], ...] = GODOT_XR_BODY_BONES
# Joint ids the body render should hide because the dedicated hand_joints
# stream already draws them at higher fidelity. PICO BD has only the two
# coarse LEFT_HAND/RIGHT_HAND endpoints (ids 22, 23) — also redundant with
# the hand stream — so it gets its own set.
_BODY_HAND_JOINT_IDS: frozenset[int] = GODOT_XR_BODY_HAND_JOINT_IDS


def _set_body_skeleton(
    joint_names: Tuple[str, ...],
    bones: Tuple[Tuple[int, int], ...],
    hand_joint_ids: frozenset[int],
) -> None:
    global _BODY_JOINT_NAMES, _BODY_BONES, _BODY_HAND_JOINT_IDS, _body_unknown_joint_warned
    _BODY_JOINT_NAMES = joint_names
    _BODY_BONES = bones
    _BODY_HAND_JOINT_IDS = hand_joint_ids
    _body_unknown_joint_warned = False


def _body_positions_and_ids(joints) -> Tuple[np.ndarray, np.ndarray]:
    # Drop hand-region joints up front so neither Points3D nor the bone
    # strips below pick them up. The hand_joints stream owns this region.
    raw_positions: List[List[float]] = []
    raw_ids: List[int] = []
    for j in joints:
        jid = int(j.joint_id)
        if jid in _BODY_HAND_JOINT_IDS:
            continue
        raw_positions.append([j.x, j.y, j.z])
        raw_ids.append(jid)
    positions = np.array(raw_positions, dtype=np.float64) if raw_positions else np.zeros((0, 3), dtype=np.float64)
    joint_ids = np.array(raw_ids, dtype=np.int32)
    global _body_unknown_joint_warned
    if not _body_unknown_joint_warned and joint_ids.size and joint_ids.max() >= len(_BODY_JOINT_NAMES):
        _body_unknown_joint_warned = True
        info(
            f"body track has joint ids up to {int(joint_ids.max())} "
            f"(> active skeleton size {len(_BODY_JOINT_NAMES)}); "
            "unknown joints are drawn as points without bones"
        )
    return positions, joint_ids


def _log_body_points_and_bones(entity_prefix: str, positions: np.ndarray, joint_ids: np.ndarray) -> None:
    if joint_ids.size == 0:
        # Every joint in this frame was filtered out (e.g. PICO BD frame
        # that only carried hand endpoints). Skip the rr.log so we don't
        # blank out the entity that an earlier frame already populated.
        return
    labels = [
        _BODY_JOINT_NAMES[i] if 0 <= i < len(_BODY_JOINT_NAMES) else f"J{i}"
        for i in joint_ids
    ]
    rr.log(
        f"{entity_prefix}/joints",
        rr.Points3D(
            positions=positions,
            radii=BODY_JOINT_RADIUS_M,
            colors=[BODY_COLOR] * len(joint_ids),
            labels=labels,
            show_labels=False,
        ),
    )
    id_to_idx = {int(jid): i for i, jid in enumerate(joint_ids)}
    strips = [
        np.stack([positions[id_to_idx[p]], positions[id_to_idx[c]]], axis=0)
        for p, c in _BODY_BONES
        if p in id_to_idx and c in id_to_idx
    ]
    if strips:
        rr.log(
            f"{entity_prefix}/bones",
            rr.LineStrips3D(
                strips=strips, colors=[BODY_COLOR] * len(strips), radii=0.008
            ),
        )


def log_body_frame(body_frame) -> None:
    """Log body joints + bones directly in world coordinates."""
    joints = body_frame.joints
    if not joints:
        return
    positions, joint_ids = _body_positions_and_ids(joints)
    _log_body_points_and_bones("world/body", positions, joint_ids)


def log_body_frame_head_relative(body_frame, head_lookup: PoseLookup) -> None:
    """Log body joints in the head's local frame, sharing the view (and the
    exact same transform) with the head-relative hand joints so body + hands
    read as one rig."""
    joints = body_frame.joints
    if not joints:
        return
    head = head_lookup.nearest(body_frame.timestamp)
    if head is None:
        return

    T_W_H = pose_frame_to_matrix(head)
    R = T_W_H[:3, :3]
    t = T_W_H[:3, 3]
    positions_world, joint_ids = _body_positions_and_ids(joints)
    # (p - t) @ R is the per-row equivalent of R^T @ (p - t).
    positions_head = (positions_world - t) @ R
    _log_body_points_and_bones("head_relative/body", positions_head, joint_ids)


def log_rigid_pose(
    track_id: str,
    pose,
    profile: DeviceProfile,
    axis_len: float = 0.08,
) -> None:
    mat = device_logged_capture_pose(pose_frame_to_matrix(pose), profile)
    mat[:3, :3] = ensure_right_handed_rotation(mat[:3, :3])
    translation = mat[:3, 3]
    quat = Rotation.from_matrix(mat[:3, :3]).as_quat()
    color = CONTROLLER_COLORS.get(track_id, (220, 220, 220))
    log_transform3d(f"world/rigid/{track_id}", translation, quat, axis_len)
    rr.log(
        f"world/rigid/{track_id}/marker",
        rr.Points3D(positions=[translation], colors=[color], radii=[0.015]),
    )


def format_controller_input(frame) -> str:
    side = "left" if frame.controller == 0 else "right"
    pkt = "SNAPSHOT" if frame.packet_type == 1 else "EVENT"

    def bits(mask: int) -> str:
        return ", ".join(
            name for name, bit in CONTROLLER_INPUT_BITS if (mask >> bit) & 1
        )

    return "\n".join([
        f"[{pkt}] {side} controller @ {frame.timestamp:.3f}s",
        f"pressed: {bits(frame.pressed_mask) or '-'}",
        f"touched: {bits(frame.touched_mask) or '-'}",
        f"changed: {bits(frame.changed_mask) or '-'}",
        f"trigger={frame.trigger_value:.2f} grip={frame.grip_value:.2f}",
        f"thumbstick=({frame.thumbstick_x:+.2f}, {frame.thumbstick_y:+.2f})",
        f"trackpad =({frame.trackpad_x:+.2f}, {frame.trackpad_y:+.2f})",
    ])


# ---------------------------------------------------------------------------
# Track discovery + bulk loggers
# ---------------------------------------------------------------------------


_HJNT_MAGIC = 0x544E4A48
_HJNT_HEADER_BYTES = 8
_HJNT_JOINT_BYTES = 36
_FFPROBE_HEXDUMP_OFFSET_RE = re.compile(r"^\s*[0-9a-fA-F]+$")


@dataclass
class _TimedJoint:
    joint_id: int
    flags: int
    radius_m: float
    x: float
    y: float
    z: float
    qx: float
    qy: float
    qz: float
    qw: float


@dataclass
class _TimedJointFrame:
    timestamp: float
    track_id: str
    joints: List[_TimedJoint]


@dataclass
class _TimedJsonFrame:
    timestamp: float
    track_id: str
    payload: Dict[str, Any]


def _find_ffprobe() -> Optional[str]:
    env = os.environ.get("FFPROBE")
    if env:
        return env
    found = shutil.which("ffprobe")
    if found:
        return found

    repo_root = Path(__file__).resolve().parents[3]
    deps_root = Path(os.environ.get("OPERATOR_DEPS_CACHE_ROOT", repo_root / ".deps")).expanduser()
    candidate = deps_root / "build" / "spatialmp4" / "host_deps" / "ffmpeg" / "ffprobe"
    if candidate.exists():
        return str(candidate)
    return None


def _ffprobe_json(
    ffprobe: str,
    args: Sequence[str],
    input_path: Path,
    context: str = "metadata",
) -> Optional[dict]:
    cmd = [ffprobe, "-v", "error", *args, "-of", "json", str(input_path)]
    try:
        proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        info(f"ffprobe failed while reading {context}: {detail.strip()}")
        return None
    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        info(f"ffprobe returned invalid JSON while reading {context}: {exc}")
        return None


def _bytes_from_ffprobe_hexdump(dump: str) -> bytes:
    raw = bytearray()
    for line in dump.splitlines():
        if ":" not in line:
            continue
        offset, rest = line.split(":", 1)
        if _FFPROBE_HEXDUMP_OFFSET_RE.match(offset) is None:
            continue
        if rest.startswith(" "):
            rest = rest[1:]
        hex_columns = rest.split("  ", 1)[0]
        hex_text = re.sub(r"[^0-9a-fA-F]", "", hex_columns)
        if len(hex_text) % 2 == 1:
            hex_text = hex_text[:-1]
        if hex_text:
            raw.extend(bytes.fromhex(hex_text))
    return bytes(raw)


def _stream_metadata_labels(stream: Dict[str, Any]) -> List[str]:
    labels: List[str] = []
    tags = stream.get("tags", {}) if isinstance(stream.get("tags"), dict) else {}
    for key in (
        "handler_name",
        "metadata_kind",
        "track_id",
        "payload_schema",
        "mime_type",
        "title",
        "comment",
        "tag",
    ):
        value = tags.get(key)
        if value is not None:
            labels.append(str(value))
    for value in tags.values():
        if value is not None:
            labels.append(str(value))
    for key in ("codec_tag_string", "codec_name"):
        value = stream.get(key)
        if value is not None:
            labels.append(str(value))
    return labels


def _looks_like_metadata_stream_kind(stream: Dict[str, Any], kind: str) -> bool:
    needle = kind.strip().lower()
    if not needle:
        return False
    for label in _stream_metadata_labels(stream):
        normalized = label.strip().lower()
        if normalized.startswith(f"spatialmp4:{needle}:"):
            return True
        if normalized == needle:
            return True
        if needle in normalized and ("spatialmp4" in normalized or "operator" in normalized):
            return True
    return False


def _looks_like_operator_static_stream(stream: Dict[str, Any]) -> bool:
    return _looks_like_metadata_stream_kind(stream, "operator_static")


def _decode_json_packet(raw: bytes) -> Optional[Dict[str, Any]]:
    text = raw.decode("utf-8-sig", errors="replace").strip("\x00 \t\r\n")
    if not text:
        return None
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        return None
    try:
        decoded = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return None
    return decoded if isinstance(decoded, dict) else None


def _json_metadata_streams(input_path: Path, kind: str) -> List[Tuple[int, str]]:
    ffprobe = _find_ffprobe()
    if ffprobe is None:
        info(f"ffprobe not found; MP4 {kind} metadata disabled")
        return []

    streams_json = _ffprobe_json(ffprobe, ["-show_streams"], input_path, f"{kind} streams")
    streams = streams_json.get("streams", []) if isinstance(streams_json, dict) else []
    result: List[Tuple[int, str]] = []
    for stream in streams:
        if not isinstance(stream, dict) or not _looks_like_metadata_stream_kind(stream, kind):
            continue
        tags = stream.get("tags", {}) if isinstance(stream.get("tags"), dict) else {}
        handler = str(tags.get("handler_name", ""))
        track_id = kind
        if handler.startswith("spatialmp4:"):
            parts = handler.split(":", 2)
            if len(parts) == 3 and parts[2]:
                track_id = parts[2]
        elif tags.get("track_id") is not None:
            track_id = str(tags.get("track_id"))
        try:
            result.append((int(stream["index"]), track_id))
        except (KeyError, TypeError, ValueError):
            continue
    return result


def load_json_metadata_frames_from_mp4(input_path: Path, kind: str) -> Dict[str, List[_TimedJsonFrame]]:
    """Read Operator JSON `mett` packets by metadata kind.

    This local ffprobe path keeps web ingest compatible with new Operator
    tracks before the external SpatialMP4 Python binding grows first-class
    accessors for every custom metadata stream.
    """
    ffprobe = _find_ffprobe()
    if ffprobe is None:
        info(f"ffprobe not found; MP4 {kind} metadata disabled")
        return {}

    frames_by_track: Dict[str, List[_TimedJsonFrame]] = {}
    for stream_index, track_id in _json_metadata_streams(input_path, kind):
        packets_json = _ffprobe_json(
            ffprobe,
            ["-select_streams", str(stream_index), "-show_packets", "-show_data"],
            input_path,
            f"{kind} packets",
        )
        packets = packets_json.get("packets", []) if isinstance(packets_json, dict) else []
        frames: List[_TimedJsonFrame] = []
        for packet in packets:
            if not isinstance(packet, dict):
                continue
            data = packet.get("data")
            if not isinstance(data, str):
                continue
            decoded = _decode_json_packet(_bytes_from_ffprobe_hexdump(data))
            if decoded is None:
                continue
            try:
                timestamp = float(packet.get("pts_time", "0"))
            except (TypeError, ValueError):
                timestamp = 0.0
            frames.append(_TimedJsonFrame(timestamp=timestamp, track_id=track_id, payload=decoded))
        if frames:
            frames_by_track[track_id] = frames
    if frames_by_track:
        summary = ", ".join(f"{tid}={len(frames)}" for tid, frames in frames_by_track.items())
        info(f"decoded {kind} JSON metadata from MP4 via ffprobe: {summary}")
    return frames_by_track


def load_operator_static_metadata(input_path: Path) -> Optional[Dict[str, Any]]:
    """Read the MP4 operator_static timed-metadata JSON packet, if present."""
    ffprobe = _find_ffprobe()
    if ffprobe is None:
        info("ffprobe not found; MP4 operator_static metadata disabled")
        return None

    streams_json = _ffprobe_json(ffprobe, ["-show_streams"], input_path, "operator_static streams")
    streams = streams_json.get("streams", []) if isinstance(streams_json, dict) else []
    operator_stream_indexes: List[int] = []
    for stream in streams:
        if not isinstance(stream, dict) or not _looks_like_operator_static_stream(stream):
            continue
        try:
            operator_stream_indexes.append(int(stream["index"]))
        except (KeyError, TypeError, ValueError):
            continue

    for stream_index in operator_stream_indexes:
        packets_json = _ffprobe_json(
            ffprobe,
            ["-select_streams", str(stream_index), "-show_packets", "-show_data"],
            input_path,
            "operator_static packets",
        )
        packets = packets_json.get("packets", []) if isinstance(packets_json, dict) else []
        for packet in packets:
            if not isinstance(packet, dict):
                continue
            data = packet.get("data")
            if not isinstance(data, str):
                continue
            decoded = _decode_json_packet(_bytes_from_ffprobe_hexdump(data))
            if decoded is not None:
                info(f"loaded MP4 operator_static metadata from stream {stream_index}")
                return decoded

    if operator_stream_indexes:
        info("MP4 operator_static track found, but no valid JSON packet decoded")
    return None


def _extract_android_timebase(operator_static: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not isinstance(operator_static, dict):
        return None
    for key in ("android_timebase", "timebase"):
        value = operator_static.get(key)
        if isinstance(value, dict):
            return value
    return None


def load_android_timebase_metadata(
    input_path: Path,
    operator_static: Optional[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    embedded = _extract_android_timebase(operator_static)
    if embedded is not None:
        info("loaded android_timebase from MP4 operator_static")
        return embedded

    sidecar_candidates = [
        input_path.with_suffix("") / "android_timebase.json",
        input_path.parent / "android_timebase.json",
    ]
    sidecar_path = next((p for p in sidecar_candidates if p.exists()), None)
    if sidecar_path is None:
        return None
    try:
        decoded = json.loads(sidecar_path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        info(f"android_timebase sidecar read failed ({sidecar_path}): {exc}")
        return None
    if not isinstance(decoded, dict):
        info(f"android_timebase sidecar is not a JSON object: {sidecar_path}")
        return None
    info(f"loaded android_timebase sidecar: {sidecar_path}")
    return decoded


def _parse_hjnt_packet(raw: bytes, timestamp: float, track_id: str) -> Optional[_TimedJointFrame]:
    if len(raw) < _HJNT_HEADER_BYTES:
        return None
    magic, version, joint_count = struct.unpack_from("<IHH", raw, 0)
    if magic != _HJNT_MAGIC or version != 1:
        return None
    expected_size = _HJNT_HEADER_BYTES + int(joint_count) * _HJNT_JOINT_BYTES
    if len(raw) < expected_size:
        return None

    joints: List[_TimedJoint] = []
    offset = _HJNT_HEADER_BYTES
    for _ in range(joint_count):
        joint_id, flags, radius_m, x, y, z, qx, qy, qz, qw = struct.unpack_from(
            "<HHffffffff", raw, offset
        )
        joints.append(
            _TimedJoint(
                joint_id=int(joint_id),
                flags=int(flags),
                radius_m=float(radius_m),
                x=float(x),
                y=float(y),
                z=float(z),
                qx=float(qx),
                qy=float(qy),
                qz=float(qz),
                qw=float(qw),
            )
        )
        offset += _HJNT_JOINT_BYTES
    return _TimedJointFrame(timestamp=timestamp, track_id=track_id, joints=joints)


def load_body_joint_frames_from_mp4(input_path: Path) -> Dict[str, List[_TimedJointFrame]]:
    """Fallback reader for body_joints mett tracks.

    The current SpatialMP4 Python binding exposes hand_joints but not the
    newer body_joints getter. Our writer stores body payloads in the same
    count-driven HJNT v1 binary layout, so we can recover them from the MP4
    data stream until the SDK grows a first-class API.
    """
    ffprobe = _find_ffprobe()
    if ffprobe is None:
        info("ffprobe not found; body_joints MP4 fallback disabled")
        return {}

    streams_json = _ffprobe_json(ffprobe, ["-show_streams"], input_path, "body metadata streams")
    streams = streams_json.get("streams", []) if isinstance(streams_json, dict) else []
    body_streams: List[Tuple[int, str]] = []
    for stream in streams:
        tags = stream.get("tags", {}) if isinstance(stream, dict) else {}
        handler = str(tags.get("handler_name", ""))
        if not handler.startswith("spatialmp4:body_joints:"):
            continue
        try:
            stream_index = int(stream["index"])
        except (KeyError, TypeError, ValueError):
            continue
        track_id = handler.split(":", 2)[2] or f"body_{stream_index}"
        body_streams.append((stream_index, track_id))

    if not body_streams:
        return {}

    frames_by_track: Dict[str, List[_TimedJointFrame]] = {}
    for stream_index, track_id in body_streams:
        packets_json = _ffprobe_json(
            ffprobe,
            ["-select_streams", str(stream_index), "-show_packets", "-show_data"],
            input_path,
            "body metadata packets",
        )
        packets = packets_json.get("packets", []) if isinstance(packets_json, dict) else []
        frames: List[_TimedJointFrame] = []
        for packet in packets:
            if not isinstance(packet, dict):
                continue
            data = packet.get("data")
            if not isinstance(data, str):
                continue
            try:
                timestamp = float(packet.get("pts_time", "0"))
            except (TypeError, ValueError):
                timestamp = 0.0
            frame = _parse_hjnt_packet(
                _bytes_from_ffprobe_hexdump(data),
                timestamp=timestamp,
                track_id=track_id,
            )
            if frame is not None:
                frames.append(frame)
        if frames:
            frames_by_track[track_id] = frames

    if frames_by_track:
        summary = ", ".join(f"{tid}={len(frames)}" for tid, frames in frames_by_track.items())
        info(f"decoded body_joints from MP4 data packets via ffprobe: {summary}")
    return frames_by_track


def _body_frames_for_track(
    reader,
    track_id: str,
    fallback_body_frames: Dict[str, List[_TimedJointFrame]],
):
    if hasattr(reader, "get_body_joint_frames"):
        try:
            sdk_frames = reader.get_body_joint_frames(track_id)
        except Exception as exc:  # pragma: no cover - defensive for SDK drift.
            info(f"SDK get_body_joint_frames({track_id!r}) failed: {exc}")
            sdk_frames = []
        if sdk_frames:
            return sdk_frames
    return fallback_body_frames.get(track_id, [])


def collect_tracks(
    reader,
    fallback_body_frames: Optional[Dict[str, List[_TimedJointFrame]]] = None,
) -> Dict[str, List[str]]:
    fallback_body_frames = fallback_body_frames or {}
    rigid: List[str] = []
    hands: List[str] = []
    bodies: List[str] = []
    inputs: List[str] = []
    for tid in reader.list_timed_metadata_tracks():
        # Prefer typed body-joint reads before rigid-pose reads. The body
        # track id is literally "body", and older SDK builds can expose that
        # same track through get_rigid_pose_frames even though its handler is
        # spatialmp4:body_joints:body.
        if _body_frames_for_track(reader, tid, fallback_body_frames):
            bodies.append(tid)
            continue
        if reader.get_hand_joint_frames(tid):
            hands.append(tid)
            continue
        if reader.get_rigid_pose_frames(tid):
            rigid.append(tid)
            continue
        if reader.get_controller_input_frames(tid):
            inputs.append(tid)
    for tid, frames in fallback_body_frames.items():
        if frames and tid not in bodies:
            bodies.append(tid)
    return {
        "rigid_pose": rigid,
        "hand_joints": hands,
        "body_joints": bodies,
        "controller_input": inputs,
    }


def log_all_rigid_pose_tracks(
    reader,
    track_ids: Sequence[str],
    profile: DeviceProfile,
) -> None:
    for tid in track_ids:
        if tid == "head":
            # head is rendered as world/camera + world/trajectory below.
            continue
        for pose in reader.get_rigid_pose_frames(tid):
            if pose.timestamp <= 0:
                continue
            set_time_seconds("time", pose.timestamp)
            log_rigid_pose(tid, pose, profile)


def log_all_hand_tracks(
    reader,
    track_ids: Sequence[str],
    profile: DeviceProfile,
) -> None:
    for tid in track_ids:
        for frame in reader.get_hand_joint_frames(tid):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            log_hand_frame(tid, frame, profile)


def log_all_hand_tracks_head_relative(
    reader, track_ids: Sequence[str], head_lookup: PoseLookup
) -> None:
    for tid in track_ids:
        for frame in reader.get_hand_joint_frames(tid):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            log_hand_frame_head_relative(tid, frame, head_lookup)


def log_all_body_tracks(
    reader,
    track_ids: Sequence[str],
    fallback_body_frames: Optional[Dict[str, List[_TimedJointFrame]]] = None,
) -> None:
    fallback_body_frames = fallback_body_frames or {}
    for tid in track_ids:
        for frame in _body_frames_for_track(reader, tid, fallback_body_frames):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            log_body_frame(frame)


def log_all_body_tracks_head_relative(
    reader,
    track_ids: Sequence[str],
    head_lookup: PoseLookup,
    fallback_body_frames: Optional[Dict[str, List[_TimedJointFrame]]] = None,
) -> None:
    fallback_body_frames = fallback_body_frames or {}
    for tid in track_ids:
        for frame in _body_frames_for_track(reader, tid, fallback_body_frames):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            log_body_frame_head_relative(frame, head_lookup)


def log_all_controller_input_tracks(reader, track_ids: Sequence[str]) -> None:
    for tid in track_ids:
        for frame in reader.get_controller_input_frames(tid):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            rr.log(
                f"controller_input/{tid}",
                rr.TextLog(format_controller_input(frame)),
            )
            rr.log(f"plots/{tid}/trigger", rr.Scalars(float(frame.trigger_value)))
            rr.log(f"plots/{tid}/grip", rr.Scalars(float(frame.grip_value)))
            rr.log(f"plots/{tid}/thumbstick_x", rr.Scalars(float(frame.thumbstick_x)))
            rr.log(f"plots/{tid}/thumbstick_y", rr.Scalars(float(frame.thumbstick_y)))


def _entity_token(value: Any, fallback: str) -> str:
    raw = str(value if value not in (None, "") else fallback)
    token = re.sub(r"[^A-Za-z0-9_.-]+", "_", raw).strip("_")
    return token or fallback


def _dict_vec3(value: Any) -> Optional[np.ndarray]:
    if not isinstance(value, dict):
        return None
    try:
        return np.array(
            [float(value["x"]), float(value["y"]), float(value["z"])],
            dtype=np.float64,
        )
    except (KeyError, TypeError, ValueError):
        return None


def _dict_quat_xyzw(value: Any) -> Optional[np.ndarray]:
    if not isinstance(value, dict):
        return None
    try:
        quat = np.array(
            [float(value["x"]), float(value["y"]), float(value["z"]), float(value["w"])],
            dtype=np.float64,
        )
    except (KeyError, TypeError, ValueError):
        return None
    norm = float(np.linalg.norm(quat))
    if not np.isfinite(norm) or norm <= 0.0:
        return None
    return quat / norm


def _timed_joint_from_json(record: Dict[str, Any]) -> Optional[_TimedJoint]:
    try:
        position = record.get("position", {})
        rotation = record.get("rotation", {})
        return _TimedJoint(
            joint_id=int(record.get("joint", record.get("joint_id", 0))),
            flags=int(record.get("flags", 0)),
            radius_m=float(record.get("radius_m", 0.0)),
            x=float(position.get("x", 0.0)),
            y=float(position.get("y", 0.0)),
            z=float(position.get("z", 0.0)),
            qx=float(rotation.get("x", 0.0)),
            qy=float(rotation.get("y", 0.0)),
            qz=float(rotation.get("z", 0.0)),
            qw=float(rotation.get("w", 1.0)),
        )
    except (TypeError, ValueError, AttributeError):
        return None


def body_frames_from_json_metadata(
    frames_by_track: Dict[str, List[_TimedJsonFrame]],
) -> Dict[str, List[_TimedJointFrame]]:
    result: Dict[str, List[_TimedJointFrame]] = {}
    for track_id, frames in frames_by_track.items():
        body_frames: List[_TimedJointFrame] = []
        for frame in frames:
            raw_joints = frame.payload.get("joints", [])
            if not isinstance(raw_joints, list):
                continue
            joints = [
                joint
                for joint in (_timed_joint_from_json(item) for item in raw_joints if isinstance(item, dict))
                if joint is not None
            ]
            if joints:
                body_frames.append(_TimedJointFrame(timestamp=frame.timestamp, track_id=track_id, joints=joints))
        if body_frames:
            result[track_id] = body_frames
    if result:
        summary = ", ".join(f"{tid}={len(frames)}" for tid, frames in result.items())
        info(f"decoded body frames from body_frame_meta JSON metadata: {summary}")
    return result


def _motion_tracker_pose_matrix(payload: Dict[str, Any]) -> Optional[np.ndarray]:
    position = _dict_vec3(payload.get("position"))
    rotation = _dict_quat_xyzw(payload.get("rotation"))
    if position is None or rotation is None:
        return None
    mat = np.eye(4, dtype=np.float64)
    mat[:3, :3] = Rotation.from_quat(rotation).as_matrix()
    mat[:3, 3] = position
    return mat


def _motion_tracker_label(track_id: str, payload: Dict[str, Any]) -> str:
    source = payload.get("source")
    tracker_id = payload.get("id")
    tracker_index = payload.get("tracker_index")
    if source not in (None, ""):
        return _entity_token(source, track_id)
    if tracker_id not in (None, ""):
        return _entity_token(f"tracker_{tracker_id}", track_id)
    return _entity_token(f"tracker_{tracker_index}", track_id)


def log_all_motion_tracker_tracks(
    frames_by_track: Dict[str, List[_TimedJsonFrame]],
    profile: DeviceProfile,
) -> None:
    pose_count = 0
    event_count = 0
    for track_id, frames in frames_by_track.items():
        for frame in frames:
            payload = frame.payload
            event_type = payload.get("event_type")
            if event_type is not None:
                set_time_seconds("time", frame.timestamp)
                rr.log(
                    "controller_input/motion_trackers/events",
                    rr.TextLog(json.dumps(payload, sort_keys=True)),
                )
                event_count += 1
                continue
            if not bool(payload.get("tracking_valid", True)):
                continue
            pose = _motion_tracker_pose_matrix(payload)
            if pose is None:
                continue
            label = _motion_tracker_label(track_id, payload)
            logged_pose = device_logged_capture_pose(pose, profile)
            logged_pose[:3, :3] = ensure_right_handed_rotation(logged_pose[:3, :3])
            translation = logged_pose[:3, 3]
            quat = Rotation.from_matrix(logged_pose[:3, :3]).as_quat()
            set_time_seconds("time", frame.timestamp)
            path = f"world/motion_trackers/{label}"
            log_transform3d(path, translation, quat, axis_len=0.08)
            rr.log(
                f"{path}/marker",
                rr.Points3D(
                    positions=[translation],
                    colors=[[190, 120, 255]],
                    radii=[0.018],
                    labels=[label],
                ),
            )
            linear_velocity = _dict_vec3(payload.get("linear_velocity"))
            if linear_velocity is not None:
                logged_velocity = device_logged_capture_points(linear_velocity.reshape(1, 3), profile)[0]
                rr.log(
                    f"{path}/linear_velocity",
                    rr.Arrows3D(
                        origins=[translation],
                        vectors=[logged_velocity],
                        colors=[[190, 120, 255]],
                        radii=0.008,
                    ),
                )
            if payload.get("battery_level") is not None:
                try:
                    rr.log(
                        f"plots/motion_trackers/{label}/battery",
                        rr.Scalars(float(payload["battery_level"])),
                    )
                except (TypeError, ValueError):
                    pass
            pose_count += 1
    if pose_count or event_count:
        info(f"logged motion tracker metadata: poses={pose_count}, events={event_count}")


# ---------------------------------------------------------------------------
# Head trajectory + floor grid (purely visual; matches reference)
# ---------------------------------------------------------------------------


def log_head_pose_track(head_lookup: PoseLookup, profile: DeviceProfile) -> None:
    if head_lookup.empty():
        return

    traj = device_logged_capture_points(head_lookup.trajectory_xyz(), profile)
    rr.log(
        "world/trajectory/head",
        rr.LineStrips3D(strips=[traj], colors=[[255, 215, 0]], radii=0.02),
        static=True,
    )
    rr.log(
        "world/trajectory/head/points",
        rr.Points3D(positions=traj, colors=[[255, 120, 0]], radii=0.008),
        static=True,
    )
    rr.log(
        "world/trajectory/head/start",
        rr.Points3D(
            positions=traj[:1],
            colors=[[0, 255, 0]],
            radii=[0.05],
            labels=["start"],
        ),
        static=True,
    )
    rr.log(
        "world/trajectory/head/end",
        rr.Points3D(
            positions=traj[-1:],
            colors=[[255, 0, 0]],
            radii=[0.05],
            labels=["end"],
        ),
        static=True,
    )

    for f in head_lookup.frames:
        set_time_seconds("time", f.timestamp)
        log_rigid_pose("head", f, profile, axis_len=0.1)
        mat = pose_frame_to_matrix(f)
        # OpenXR head looks down its local -Z axis (RUB convention).
        forward = device_logged_capture_points((-mat[:3, 2]).reshape(1, 3), profile)[0]
        origin = device_logged_capture_points(mat[:3, 3].reshape(1, 3), profile)[0]
        rr.log(
            "world/rigid/head/gaze",
            rr.Arrows3D(
                origins=[origin],
                vectors=[forward * 0.5],
                colors=[[255, 80, 200]],
                radii=0.015,
            ),
        )


def log_floor_grid(
    half_extent_x: float, half_extent_z: float, y: float = 0.0, step: float = 1.0
) -> None:
    nx = int(np.ceil(half_extent_x / step)) + 1
    nz = int(np.ceil(half_extent_z / step)) + 1
    xs = np.arange(-nx, nx + 1) * step
    zs = np.arange(-nz, nz + 1) * step

    strips: List[np.ndarray] = []
    for x in xs:
        strips.append(np.array([[x, y, zs[0]], [x, y, zs[-1]]], dtype=np.float64))
    for z in zs:
        strips.append(np.array([[xs[0], y, z], [xs[-1], y, z]], dtype=np.float64))
    rr.log(
        "world/floor",
        rr.LineStrips3D(strips=strips, colors=[[80, 80, 80]] * len(strips), radii=0.002),
        static=True,
    )


# ---------------------------------------------------------------------------
# Depth helpers (mp4-only, no spool sidecar)
# ---------------------------------------------------------------------------


def depth_colormap_jet(values: np.ndarray, lo: float, hi: float) -> np.ndarray:
    """Map a (N,) float array to RGB uint8 via OpenCV's JET colormap.

    Used to colour the 3D depth point cloud by camera-local Z so the
    gradient reads as ``blue=near, red=far``.
    """
    clipped = np.clip((values - lo) / max(hi - lo, 1e-6), 0.0, 1.0)
    gray = (clipped * 255).astype(np.uint8)
    rgb = cv2.applyColorMap(gray.reshape(-1, 1), cv2.COLORMAP_JET)
    return cv2.cvtColor(rgb, cv2.COLOR_BGR2RGB).reshape(-1, 3)


class HandFrameLookup:
    """Time-sorted hand_joints frames with nearest-by-timestamp lookup.

    Mirrors PoseLookup. Used by the RGB pass to attach each video
    frame to the closest hand sample so we can project joints into
    the image. The XR-side hand tracker typically runs at 60-90 Hz,
    faster than RGB's 50 fps, so "nearest" is well-defined.
    """

    def __init__(self, frames: Sequence) -> None:
        valid = [f for f in frames if f.timestamp > 0]
        valid.sort(key=lambda f: f.timestamp)
        self._ts = [f.timestamp for f in valid]
        self._frames = valid

    def empty(self) -> bool:
        return len(self._frames) == 0

    def nearest_within(self, t: float, max_dt: float):
        """Nearest frame within ``max_dt`` seconds of ``t``, else None.

        Capping by ``max_dt`` keeps stale poses off RGB frames during
        gaps in tracking (the hand vanishes from the camera view, the
        last cached pose becomes meaningless within ~100 ms).
        """
        if not self._frames:
            return None
        idx = bisect.bisect_left(self._ts, t)
        best_i = None
        best_dt = max_dt
        for i in (idx - 1, idx):
            if 0 <= i < len(self._ts):
                dt = abs(self._ts[i] - t)
                if dt <= best_dt:
                    best_dt = dt
                    best_i = i
        return self._frames[best_i] if best_i is not None else None


def _joint_position_by_id(joints) -> Dict[int, np.ndarray]:
    return {
        int(j.joint_id): np.array([j.x, j.y, j.z], dtype=np.float64)
        for j in joints
    }


def _log_body_hand_bridge_strips(
    entity_prefix: str,
    strips: List[np.ndarray],
    colors: List[Tuple[int, int, int]],
) -> None:
    rr.log(
        f"{entity_prefix}/hand_bridge",
        rr.LineStrips3D(
            strips=strips,
            colors=colors,
            radii=BODY_HAND_BRIDGE_RADIUS_M,
        ),
    )


def log_body_hand_bridge_frame(
    body_frame,
    hand_lookups: Dict[str, HandFrameLookup],
    profile: DeviceProfile,
    body_to_hand_bridges: BodyHandBridgeMap,
) -> None:
    if not body_to_hand_bridges or not hand_lookups or not body_frame.joints:
        return

    body_by_id = _joint_position_by_id(body_frame.joints)
    strips: List[np.ndarray] = []
    colors: List[Tuple[int, int, int]] = []
    for track_id, joint_pairs in body_to_hand_bridges.items():
        lookup = hand_lookups.get(track_id)
        if lookup is None:
            continue
        hand_frame = lookup.nearest_within(
            body_frame.timestamp,
            HAND_FRAME_MATCH_MAX_DT,
        )
        if hand_frame is None or not hand_frame.joints:
            continue
        hand_by_id = _joint_position_by_id(hand_frame.joints)
        for body_joint_id, hand_joint_id in joint_pairs:
            body_pos = body_by_id.get(body_joint_id)
            hand_pos_raw = hand_by_id.get(hand_joint_id)
            if body_pos is None or hand_pos_raw is None:
                continue
            hand_pos = device_logged_capture_points(
                hand_pos_raw.reshape(1, 3),
                profile,
            )[0]
            strips.append(np.stack([body_pos, hand_pos], axis=0))
            colors.append(HAND_COLORS.get(track_id, BODY_COLOR))
    _log_body_hand_bridge_strips("world/body", strips, colors)


def log_body_hand_bridge_frame_head_relative(
    body_frame,
    head_lookup: PoseLookup,
    hand_lookups: Dict[str, HandFrameLookup],
    body_to_hand_bridges: BodyHandBridgeMap,
) -> None:
    if not body_to_hand_bridges or not hand_lookups or not body_frame.joints:
        return

    head = head_lookup.nearest(body_frame.timestamp)
    if head is None:
        return
    T_W_H = pose_frame_to_matrix(head)
    R = T_W_H[:3, :3]
    t = T_W_H[:3, 3]

    body_by_id = _joint_position_by_id(body_frame.joints)
    strips: List[np.ndarray] = []
    colors: List[Tuple[int, int, int]] = []
    for track_id, joint_pairs in body_to_hand_bridges.items():
        lookup = hand_lookups.get(track_id)
        if lookup is None:
            continue
        hand_frame = lookup.nearest_within(
            body_frame.timestamp,
            HAND_FRAME_MATCH_MAX_DT,
        )
        if hand_frame is None or not hand_frame.joints:
            continue
        hand_by_id = _joint_position_by_id(hand_frame.joints)
        for body_joint_id, hand_joint_id in joint_pairs:
            body_pos = body_by_id.get(body_joint_id)
            hand_pos = hand_by_id.get(hand_joint_id)
            if body_pos is None or hand_pos is None:
                continue
            points_head = (np.stack([body_pos, hand_pos], axis=0) - t) @ R
            strips.append(points_head)
            colors.append(HAND_COLORS.get(track_id, BODY_COLOR))
    _log_body_hand_bridge_strips("head_relative/body", strips, colors)


def log_all_body_hand_bridges(
    reader,
    track_ids: Sequence[str],
    fallback_body_frames: Dict[str, List[_TimedJointFrame]],
    hand_lookups: Dict[str, HandFrameLookup],
    profile: DeviceProfile,
    body_to_hand_bridges: BodyHandBridgeMap,
) -> None:
    if not body_to_hand_bridges or not hand_lookups:
        return
    for tid in track_ids:
        for frame in _body_frames_for_track(reader, tid, fallback_body_frames):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            log_body_hand_bridge_frame(
                frame,
                hand_lookups,
                profile,
                body_to_hand_bridges,
            )


def log_all_body_hand_bridges_head_relative(
    reader,
    track_ids: Sequence[str],
    fallback_body_frames: Dict[str, List[_TimedJointFrame]],
    head_lookup: PoseLookup,
    hand_lookups: Dict[str, HandFrameLookup],
    body_to_hand_bridges: BodyHandBridgeMap,
) -> None:
    if not body_to_hand_bridges or not hand_lookups:
        return
    for tid in track_ids:
        for frame in _body_frames_for_track(reader, tid, fallback_body_frames):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            log_body_hand_bridge_frame_head_relative(
                frame,
                head_lookup,
                hand_lookups,
                body_to_hand_bridges,
            )


# UBR (X-up, Y-back, Z-right) → RDF (X-right, Y-down, Z-forward) pure
# axis swap. Used to bring Pico's native camera coordinates into the
# OpenCV convention so the same `u = fx*X/Z+cx, v = fy*Y/Z+cy`
# projection formula works for both devices without re-deriving fx/fy.
_RDF_FROM_UBR = np.array(
    [
        [0.0, 0.0, 1.0],   # right(new X)   ←  Z (right, old)
        [-1.0, 0.0, 0.0],  # down (new Y)   ← -X (up,    old)
        [0.0, -1.0, 0.0],  # forward(new Z) ← -Y (back,  old)
    ],
    dtype=np.float64,
)


def project_world_points_to_image(
    world_pts: np.ndarray,
    T_W_S_native: np.ndarray,
    K,
    width: int,
    height: int,
    camera_view_coord: str,
    image_rdf_from_camera: Optional[np.ndarray] = None,
    z_near: float = 0.05,
) -> Tuple[np.ndarray, np.ndarray]:
    """Project world-frame points into a 2D image given the camera
    extrinsic in the **device's native** orientation.

    Returns ``(uv, mask)`` where ``uv`` is (N, 2) image coords (NaN for
    invalid joints, so the array stays addressable by joint index) and
    ``mask`` is (N,) True for joints in front of the camera AND inside
    the image rectangle.

    ``camera_view_coord`` is the Rerun Pinhole coordinate convention. When a
    provider's MP4 camera-local frame needs a different mapping to image pixels
    than Rerun's declared camera frame, ``image_rdf_from_camera`` overrides the
    fallback view-coordinate mapping for this 2D projection only.
    """
    n = world_pts.shape[0]
    nan = np.full((n, 2), np.nan, dtype=np.float64)
    if n == 0:
        return nan, np.zeros((0,), dtype=bool)

    T_S_W = np.linalg.inv(T_W_S_native)
    p_native = (T_S_W[:3, :3] @ world_pts.T).T + T_S_W[:3, 3]

    if image_rdf_from_camera is not None:
        p_rdf = p_native @ image_rdf_from_camera.T
    else:
        coord = camera_view_coord.upper()
        if coord == "RDF":
            p_rdf = p_native
        elif coord == "UBR":
            p_rdf = p_native @ _RDF_FROM_UBR.T
        else:
            info(f"unsupported camera_xyz={coord} for 2D projection; skipping joints")
            return nan, np.zeros((n,), dtype=bool)

    z = p_rdf[:, 2]
    valid_z = z > z_near
    fx, fy = float(K.fx), float(K.fy)
    cx, cy = float(K.cx), float(K.cy)
    with np.errstate(divide="ignore", invalid="ignore"):
        u = p_rdf[:, 0] * fx / z + cx
        v = p_rdf[:, 1] * fy / z + cy
    inside = (u >= 0) & (u < width) & (v >= 0) & (v < height)
    mask = valid_z & inside & np.isfinite(u) & np.isfinite(v)

    uv = nan.copy()
    uv[mask, 0] = u[mask]
    uv[mask, 1] = v[mask]
    return uv, mask


def project_world_points_to_camera2_image(
    world_pts_godot: np.ndarray,
    T_W_H_godot: np.ndarray,
    calibration: Camera2ProjectionCalibration,
    z_near: float = 0.05,
) -> Tuple[np.ndarray, np.ndarray]:
    """Project Godot/OpenXR world points into Quest Camera2 RGB pixels."""
    n = world_pts_godot.shape[0]
    nan = np.full((n, 2), np.nan, dtype=np.float64)
    if n == 0:
        return nan, np.zeros((0,), dtype=bool)

    T_W_H_unity = godot_transform_to_unity(T_W_H_godot)
    T_W_C_unity = T_W_H_unity @ calibration.head_from_camera_unity
    T_C_W_unity = np.linalg.inv(T_W_C_unity)
    pts_unity = (UNITY_FROM_GODOT_3 @ world_pts_godot.T).T
    camera = (T_C_W_unity[:3, :3] @ pts_unity.T).T + T_C_W_unity[:3, 3]

    z = camera[:, 2]
    valid_z = z > z_near
    with np.errstate(divide="ignore", invalid="ignore"):
        u = calibration.K_rgb[0, 0] * camera[:, 0] / z + calibration.K_rgb[0, 2]
        # Unity RGB camera uses Y-up; image coordinates increase downward.
        v = calibration.K_rgb[1, 2] - calibration.K_rgb[1, 1] * camera[:, 1] / z
    inside = (
        (u >= 0)
        & (u < calibration.width)
        & (v >= 0)
        & (v < calibration.height)
    )
    mask = valid_z & inside & np.isfinite(u) & np.isfinite(v)

    uv = nan.copy()
    uv[mask, 0] = u[mask]
    uv[mask, 1] = v[mask]
    return uv, mask


def log_hand_joints_on_image(
    rgb_entity_prefix: str,
    track_id: str,
    hand_frame,
    profile: DeviceProfile,
    T_W_Srgb_camera: np.ndarray,
    K_rgb,
    rgb_w: int,
    rgb_h: int,
    T_W_H_godot: Optional[np.ndarray] = None,
    camera2_projection: Optional[Camera2ProjectionCalibration] = None,
) -> int:
    """Project hand joints + bones into the RGB image and log as
    ``Points2D`` / ``LineStrips2D`` children of the Pinhole entity so
    Rerun's 2D RGB view overlays them on the frame automatically.

    Returns the number of joints actually drawn (those in front of
    the camera and inside the image rectangle).
    """
    joints = hand_frame.joints
    if not joints:
        return 0
    positions = np.array([[j.x, j.y, j.z] for j in joints], dtype=np.float64)
    joint_ids = np.array([int(j.joint_id) for j in joints], dtype=np.int32)
    if camera2_projection is not None and T_W_H_godot is not None:
        uv, mask = project_world_points_to_camera2_image(
            positions, T_W_H_godot, camera2_projection
        )
    else:
        uv, mask = project_capture_points_to_image(
            positions,
            T_W_Srgb_camera,
            K_rgb,
            rgb_w,
            rgb_h,
            profile,
        )
    visible = int(mask.sum())
    color = HAND_COLORS.get(track_id, (200, 200, 200))

    joints_path = f"{rgb_entity_prefix}/hands/{track_id}/joints"
    bones_path = f"{rgb_entity_prefix}/hands/{track_id}/bones"

    if visible == 0:
        # Log an empty entity so any previously-drawn joints from this
        # track get cleared at the current timestamp (Rerun's retention
        # rule keeps the last value otherwise).
        rr.log(joints_path, rr.Points2D(positions=np.zeros((0, 2), dtype=np.float32)))
        rr.log(bones_path, rr.LineStrips2D(strips=[]))
        return 0

    uv_visible = uv[mask].astype(np.float32)
    rr.log(
        joints_path,
        rr.Points2D(
            positions=uv_visible,
            colors=[color] * visible,
            radii=4.0,
        ),
    )

    # Bones: include a segment only if BOTH endpoints projected
    # inside the image. Anything else would draw a half-segment to a
    # NaN, which Rerun rejects.
    id_to_idx = {int(jid): i for i, jid in enumerate(joint_ids)}
    strips = []
    for p, c in XR_HAND_BONES:
        if p in id_to_idx and c in id_to_idx and mask[id_to_idx[p]] and mask[id_to_idx[c]]:
            strips.append(np.stack([uv[id_to_idx[p]], uv[id_to_idx[c]]], axis=0))
    if strips:
        rr.log(
            bones_path,
            rr.LineStrips2D(
                strips=strips,
                colors=[color] * len(strips),
                radii=1.5,
            ),
        )
    else:
        rr.log(bones_path, rr.LineStrips2D(strips=[]))
    return visible


def project_depth_to_points(depth: np.ndarray, K, stride: int = 2) -> np.ndarray:
    """Unproject a (H, W) float32 depth map into the camera's local frame.

    Camera frame convention: X-right, Y-down, Z-forward (OpenCV / RDF).
    Returned (N, 3) array holds points with z > 0 only.
    """
    h, w = depth.shape
    fx, fy, cx, cy = float(K.fx), float(K.fy), float(K.cx), float(K.cy)
    if stride > 1:
        d = depth[::stride, ::stride]
    else:
        d = depth
    rows, cols = np.indices(d.shape, dtype=np.float32)
    cols = cols * stride
    rows = rows * stride
    mask = d > 0
    z = d[mask]
    x = (cols[mask] - cx) / fx * z
    y = (rows[mask] - cy) / fy * z
    return np.stack([x, y, z], axis=-1)


# ---------------------------------------------------------------------------
# RFC-003 H2 robot — drive the URDF visuals from robot_solution.jsonl
# ---------------------------------------------------------------------------
# The on-device retargeter (xr/scripts/retargeting/h2_pinocchio_retargeter.gd)
# writes a per-frame solution stream with ``joint_names`` + ``joint_q`` for
# the 19-joint upper-body chain. We render the H2 URDF visuals next to the
# capture's RGB / depth / hand tracks so the operator can verify the IK
# result against what they were doing at capture time. Legs / fingers are
# skipped — the retargeter doesn't drive them, so unattached meshes would
# just sit at the world origin and look broken.
#
# Optional: enabled only when ``--robot-urdf`` + ``--robot-chain`` resolve
# AND ``<session>/retargeting/robot_solution.jsonl`` exists. Missing inputs
# log a warning and skip the section so a session without retargeting
# still produces a viewable .rrd.


@dataclass
class _RobotVisualMesh:
    link_name: str
    mesh_path: Path
    xyz: np.ndarray
    rpy: np.ndarray


@dataclass
class _RobotJoint:
    name: str
    parent_link: str
    child_link: str
    origin_xyz: np.ndarray
    origin_rpy: np.ndarray
    axis: np.ndarray
    joint_type: str


def _robot_parse_vec3(text: Optional[str]) -> np.ndarray:
    if text is None:
        return np.zeros(3)
    return np.array([float(x) for x in text.split()], dtype=float)


def parse_urdf_visuals(urdf_path: Path) -> Dict[str, _RobotVisualMesh]:
    """Return ``link_name -> first <visual> mesh`` from an URDF.

    50-line ElementTree scan in lieu of a urdfpy / yourdfpy dep — we only
    need the visual blocks for rendering, not the full URDF semantics.
    Mesh ``filename`` paths are resolved against the URDF's own directory.
    """
    import xml.etree.ElementTree as ET

    root = ET.fromstring(urdf_path.read_text())
    out: Dict[str, _RobotVisualMesh] = {}
    for link in root.findall("link"):
        name = link.attrib.get("name", "")
        visual = link.find("visual")
        if visual is None:
            continue
        geom = visual.find("geometry")
        if geom is None:
            continue
        mesh = geom.find("mesh")
        if mesh is None:
            continue
        filename = mesh.attrib.get("filename", "")
        if not filename:
            continue
        if filename.startswith("package://"):
            filename = filename.split("/", 3)[-1]
        mesh_path = (urdf_path.parent / filename).resolve()
        origin = visual.find("origin")
        xyz = _robot_parse_vec3(origin.attrib.get("xyz") if origin is not None else None)
        rpy = _robot_parse_vec3(origin.attrib.get("rpy") if origin is not None else None)
        out[name] = _RobotVisualMesh(name, mesh_path, xyz, rpy)
    return out


def load_robot_chain(chain_json: Path) -> List[_RobotJoint]:
    """Parse ``upper_body.json`` (parent/child/axis/origin per joint).

    The on-device builder reads the SAME file (see
    ``xr/scripts/retargeting/h2_pinocchio_builder.gd``), so the chain
    here stays in lockstep with the IK solver's joint ordering.
    """
    raw = json.loads(chain_json.read_text())
    joints: List[_RobotJoint] = []
    for j in raw.get("joints", []):
        joints.append(
            _RobotJoint(
                name=j["name"],
                parent_link=j["parent"],
                child_link=j["child"],
                origin_xyz=np.array(j["origin_xyz"], dtype=float),
                origin_rpy=np.array(j["origin_rpy"], dtype=float),
                axis=np.array(j["axis"], dtype=float),
                joint_type=j.get("type", "revolute"),
            )
        )
    return joints


def _robot_se3(t: np.ndarray, R: Rotation) -> np.ndarray:
    T = np.eye(4)
    T[:3, :3] = R.as_matrix()
    T[:3, 3] = t
    return T


def _robot_compute_link_transforms(
    joints: List[_RobotJoint],
    joint_q: Dict[str, float],
    root_link: str = "pelvis",
) -> Dict[str, np.ndarray]:
    """Walk parent->child, return ``link_name -> 4x4 T_world_link``."""
    transforms: Dict[str, np.ndarray] = {root_link: np.eye(4)}
    for j in joints:
        # Chain is pre-topo-sorted (upper_body.json's emit order). If a
        # parent hasn't been resolved yet we skip — the FK for that child
        # subtree stays missing rather than crash on a partial dict.
        if j.parent_link not in transforms:
            continue
        T_parent = transforms[j.parent_link]
        T_origin = _robot_se3(
            j.origin_xyz, Rotation.from_euler("xyz", j.origin_rpy)
        )
        if j.joint_type == "fixed":
            T_joint = np.eye(4)
        else:
            theta = float(joint_q.get(j.name, 0.0))
            T_joint = _robot_se3(np.zeros(3), Rotation.from_rotvec(j.axis * theta))
        transforms[j.child_link] = T_parent @ T_origin @ T_joint
    return transforms


# URDF (ROS REP-103) is X-forward, Y-left, Z-up. Rerun world here is
# RUB (X-right, Y-up, Z-back-out-of-page; OpenXR Quest convention). We
# place the robot facing the viewer (its forward axis along +Z_rerun)
# so the on-screen pose mirrors the operator's first-person view.
_ROBOT_ROS_TO_RUB = np.array(
    [
        [0.0, -1.0, 0.0],
        [0.0, 0.0, 1.0],
        [1.0, 0.0, 0.0],
    ]
)


def _robot_ros_to_rerun(T_ros: np.ndarray) -> np.ndarray:
    R_basis = np.eye(4)
    R_basis[:3, :3] = _ROBOT_ROS_TO_RUB
    return R_basis @ T_ros @ R_basis.T


def log_robot_visuals_static(
    visuals: Dict[str, _RobotVisualMesh],
    rendered_links: set,
    entity_prefix: str = "world/robot",
) -> int:
    """One ``rr.Asset3D`` per chain link, with the link's visual offset
    as a static transform under ``<prefix>/<link>/mesh``."""
    logged = 0
    for link_name, vm in visuals.items():
        if link_name not in rendered_links:
            continue
        if not vm.mesh_path.exists():
            info(f"[robot] missing mesh, skipping link: {vm.mesh_path}")
            continue
        path = f"{entity_prefix}/{link_name}/mesh"
        rr.log(
            path,
            rr.Transform3D(
                translation=vm.xyz.tolist(),
                mat3x3=Rotation.from_euler("xyz", vm.rpy).as_matrix().tolist(),
            ),
            static=True,
        )
        rr.log(path, rr.Asset3D(path=str(vm.mesh_path)), static=True)
        logged += 1
    return logged


def log_robot_solution_frames(
    joints: List[_RobotJoint],
    rendered_links: set,
    solution_jsonl: Path,
    entity_prefix: str = "world/robot",
) -> int:
    """Stream per-frame transforms onto every chain link.

    Frames inherit the same ``"time"`` timeline the SpatialMP4 RGB +
    depth + tracks log to, so scrubbing the seekbar moves the robot in
    lockstep with everything else.
    """
    n = 0
    with solution_jsonl.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            frame = json.loads(line)
            joint_names = frame.get("joint_names") or []
            joint_q = frame.get("joint_q") or []
            q_dict = {name: float(q) for name, q in zip(joint_names, joint_q)}
            transforms = _robot_compute_link_transforms(joints, q_dict)
            ts_s = float(frame.get("timestamp_ns", 0)) / 1e9
            set_time_seconds("time", ts_s)
            for link_name in transforms:
                if link_name not in rendered_links:
                    continue
                T_link = _robot_ros_to_rerun(transforms[link_name])
                rr.log(
                    f"{entity_prefix}/{link_name}",
                    rr.Transform3D(
                        translation=T_link[:3, 3].tolist(),
                        mat3x3=T_link[:3, :3].tolist(),
                    ),
                )
            n += 1
    return n


def maybe_log_robot(
    session_dir: Path,
    urdf_path: Optional[Path],
    chain_json: Optional[Path],
    solution_jsonl: Optional[Path],
) -> bool:
    """Best-effort robot pose visualization.

    Returns True iff a robot was rendered. Logs a single info() line and
    bails out without raising on every missing input, so a session
    captured without the retargeting flags still produces a viewable
    .rrd (the worker just skips the robot panel).
    """
    if urdf_path is None or chain_json is None:
        info("[robot] no URDF / chain config — skipping robot visualization")
        return False
    if solution_jsonl is None:
        solution_jsonl = session_dir / "retargeting" / "robot_solution.jsonl"
    if not solution_jsonl.exists() or solution_jsonl.stat().st_size == 0:
        info(f"[robot] no robot_solution.jsonl in {session_dir}/retargeting/ — skipping")
        return False
    if not urdf_path.exists():
        info(f"[robot] urdf not found: {urdf_path} — skipping")
        return False
    if not chain_json.exists():
        info(f"[robot] chain JSON not found: {chain_json} — skipping")
        return False

    visuals = parse_urdf_visuals(urdf_path)
    joints = load_robot_chain(chain_json)
    rendered_links = {"pelvis"} | {j.child_link for j in joints}
    n_meshes = log_robot_visuals_static(visuals, rendered_links)
    n_frames = log_robot_solution_frames(joints, rendered_links, solution_jsonl)
    info(f"[robot] logged {n_meshes} chain meshes + {n_frames} solution frames")
    return True


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------


def build_blueprint(has_depth_panel: bool) -> "rrb.ContainerLike":
    """Reference layout minus the spool-only rgb_depth_overlay tab.

    Originally we restricted the RGB tab to `world/camera/image/rgb`
    because the only other child was the always-empty pinhole gizmo.
    Now we ship two image-plane overlays as additional children
    (`world/camera/image/hands/*` from the RGB pass, and
    `world/camera/image/depth_overlay` from the depth pass), so the
    tab's contents have to be an inclusive glob — `"**"` matches the
    image itself plus every child entity.
    """
    left = rrb.Vertical(
        rrb.Spatial3DView(name="3D World", origin="world"),
        rrb.TextLogView(name="Controller Input", origin="controller_input"),
        row_shares=[7, 3],
    )
    tabs_children = [
        rrb.Spatial2DView(
            name="RGB",
            origin="world/camera/image",
            contents=["world/camera/image/**"],
        ),
    ]
    if has_depth_panel:
        tabs_children.append(
            rrb.Spatial2DView(
                name="Depth",
                origin="depth2d",
                contents="depth2d/depth",
            )
        )
    right = rrb.Vertical(
        rrb.Tabs(*tabs_children),
        rrb.Spatial3DView(name="3D Body+Hands (head-relative)", origin="head_relative"),
        rrb.TimeSeriesView(name="Inputs", origin="plots"),
        name="2D + head-relative",
        row_shares=[3, 3, 2],
    )
    return rrb.Horizontal(left, right, column_shares=[2, 1])


def run(args: argparse.Namespace) -> int:
    input_path = args.input.resolve()
    output_path = args.output.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Resolve device profile early so it can override CLI defaults for
    # camera_xyz. `--manifest` may be explicit, or
    # we look next to the input for the standard ingest layout
    # (data/sessions/<id>/{media.mp4,manifest.json}).
    manifest_path: Optional[Path] = args.manifest.resolve() if args.manifest else None
    if manifest_path is None:
        guess = input_path.parent / "manifest.json"
        if guess.exists():
            manifest_path = guess
    operator_static = load_operator_static_metadata(input_path)
    _android_timebase = load_android_timebase_metadata(input_path, operator_static)
    json_metadata_tracks = {
        kind: load_json_metadata_frames_from_mp4(input_path, kind)
        for kind in ("rgb_frame_index", "depth_frame_meta", "body_frame_meta", "motion_trackers")
    }
    profile = detect_device_profile(args.device_type, manifest_path)
    # Profile wins over CLI default for camera_xyz (the user almost
    # never wants Quest's RDF on a Pico capture); explicit non-default
    # CLI flag still wins over profile.
    if args.camera_coord.upper() == "RDF":  # the parser's default
        args.camera_coord = profile.camera_view_coord

    # Pick the body skeleton table (PICO BD-24 vs Godot/Meta 87) from the
    # manifest's sources.body_tracking.joint_set, falling back to the device
    # type so older recordings without the field still render correctly.
    manifest_data: Optional[dict] = None
    if manifest_path is not None and manifest_path.exists():
        try:
            manifest_data = json.loads(manifest_path.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            info(f"manifest read failed ({manifest_path}): {exc}; body skeleton defaulting to Godot/Meta superset")
    (
        body_joint_names,
        body_bones,
        body_hand_joint_ids,
        body_to_hand_bridges,
    ) = _body_skeleton_for_manifest(manifest_data)
    _set_body_skeleton(body_joint_names, body_bones, body_hand_joint_ids)
    info(
        f"body skeleton: {len(body_joint_names)} joints, {len(body_bones)} bones, "
        f"hiding {len(body_hand_joint_ids)} hand-region joint id(s), "
        f"{sum(len(pairs) for pairs in body_to_hand_bridges.values())} body-hand bridge(s)"
    )

    info(f"opening {input_path}")
    reader = sm.Reader(str(input_path))

    has_rgb = reader.has_rgb()
    has_depth = reader.has_depth() and not args.no_depth
    if not has_depth and not args.no_depth:
        depth_sidecar = input_path.with_suffix("") / "depth" / "frames.jsonl"
        if manifest_path is not None and manifest_path.exists():
            try:
                mf = json.loads(manifest_path.read_text())
                wants_depth = bool(mf.get("capture_options", {}).get("record_depth"))
            except (json.JSONDecodeError, OSError):
                wants_depth = False
            if wants_depth:
                sidecar_note = (
                    f"; sidecar exists but is empty: {depth_sidecar}"
                    if depth_sidecar.exists() and depth_sidecar.stat().st_size == 0
                    else f"; sidecar not found: {depth_sidecar}"
                )
                info(
                    "depth requested in manifest, but this mp4 has no readable "
                    f"depth stream{sidecar_note}. Rerun output will be RGB/pose only."
                )

    if not has_rgb and not has_depth:
        fatal("input has neither RGB nor depth — nothing to visualize")

    body_frames_by_track: Dict[str, List[_TimedJointFrame]] = {}
    tracks = collect_tracks(reader)
    if not tracks["body_joints"]:
        body_frames_by_track = load_body_joint_frames_from_mp4(input_path)
        if not body_frames_by_track:
            body_frames_by_track = body_frames_from_json_metadata(
                json_metadata_tracks.get("body_frame_meta", {})
            )
        if body_frames_by_track:
            tracks = collect_tracks(reader, body_frames_by_track)
    info("timed-metadata tracks: " + ", ".join(
        f"{k}={v}" for k, v in tracks.items()
    ))

    # ---- head pose track --------------------------------------------------
    if "head" in tracks["rigid_pose"]:
        head_frames = reader.get_rigid_pose_frames("head")
    elif reader.has_pose():
        head_frames = reader.get_pose_frames()
    else:
        head_frames = []
    head_lookup = PoseLookup(head_frames)
    if head_lookup.empty():
        fatal("no head pose data — refusing to write a .rrd without it")
    info(f"head pose samples: {len(head_lookup)}")

    hand_lookups: Dict[str, HandFrameLookup] = {
        tid: HandFrameLookup(reader.get_hand_joint_frames(tid))
        for tid in tracks["hand_joints"]
    }
    if hand_lookups:
        info(
            "hand tracks for nearest-frame lookup: "
            + ", ".join(
                f"{tid}={'empty' if hl.empty() else 'ok'}"
                for tid, hl in hand_lookups.items()
            )
        )

    # ---- recording init ---------------------------------------------------
    rec_name = f"spatialmp4_{input_path.stem}"
    rr.init(rec_name, spawn=False)
    rr.save(str(output_path))
    rr.send_blueprint(build_blueprint(has_depth_panel=has_depth))

    # ---- world coord system ----------------------------------------------
    # Device profile selects the camera local frame: Quest uses RDF/OpenCV,
    # while Pico follows the reference viewer's UBR camera and applies
    # pico_pose_to_open3d's left-multiply world-axis permutation before
    # logging camera transforms to Rerun.
    world_view = getattr(rr.ViewCoordinates, args.world_coord.upper())
    camera_xyz = getattr(rr.ViewCoordinates, args.camera_coord.upper())

    rr.log("world", world_view, static=True)
    rr.log(
        "world/xyz",
        rr.Arrows3D(
            vectors=[[0.5, 0, 0], [0, 0.5, 0], [0, 0, 0.5]],
            colors=[[255, 60, 60], [60, 255, 60], [60, 60, 255]],
            labels=["X+", "Y+", "Z+"],
        ),
        static=True,
    )

    # Floor grid keyed off the head trajectory extents so it sits where
    # the user actually walked. ``y = min(traj.y) - 1.2`` is the same
    # rough "ground ≈ 1.2 m below the lowest head sample" heuristic the
    # reference uses (works for standing capture; for floor-level
    # capture the grid sinks correspondingly).
    if not args.no_floor:
        traj = device_logged_capture_points(head_lookup.trajectory_xyz(), profile)
        max_xz = float(np.max(np.abs(np.concatenate([traj[:, 0], traj[:, 2]]))))
        log_floor_grid(
            half_extent_x=max(max_xz, 2.0),
            half_extent_z=max(max_xz, 2.0),
            y=float(traj[:, 1].min()) - 1.2,
            step=1.0,
        )

    # ---- cameras / intrinsics --------------------------------------------
    rgb_w = reader.get_rgb_width() if has_rgb else 0
    rgb_h = reader.get_rgb_height() if has_rgb else 0
    K_rgb = reader.get_rgb_intrinsics_left() if has_rgb else None
    T_I_Srgb = reader.get_rgb_extrinsics_left().as_se3() if has_rgb else None
    camera2_projection = (
        load_camera2_projection_calibration(input_path, profile, "left", operator_static) if has_rgb else None
    )

    depth_w = reader.get_depth_width() if has_depth else 0
    depth_h = reader.get_depth_height() if has_depth else 0
    K_d_raw = reader.get_depth_intrinsics() if has_depth else None
    T_I_Sd = reader.get_depth_extrinsics().as_se3() if has_depth else None

    # Quest's Environment Depth ships row 0 at the bottom of the image
    # (OpenGL convention). For 2D viewing in Rerun we flip rows AND
    # mirror cy. The reference does the same.
    flip_depth_y = True
    K_d = None
    if has_depth:
        K_d = sm.CameraIntrinsics()
        K_d.fx = K_d_raw.fx
        K_d.fy = K_d_raw.fy
        K_d.cx = K_d_raw.cx
        K_d.cy = (depth_h - 1) - K_d_raw.cy if flip_depth_y else K_d_raw.cy

    # Live-writer bug compensation (mirrored from reference): some
    # captures ship identity depth_extrinsics because the writer fails
    # to record per-frame local_from_depth_eye. Substitute the rgb
    # extrinsic's rotation with zero translation so depth sits at the
    # IMU/cyclopean origin rather than at the rgb lens.
    if (
        has_depth
        and has_rgb
        and np.allclose(T_I_Sd[:3, :3], np.eye(3))
        and np.allclose(T_I_Sd[:3, 3], 0.0)
    ):
        T_I_Sd = T_I_Srgb.copy()
        T_I_Sd[:3, 3] = 0.0
        info(
            "detected identity depth_extrinsics; using rgb-rotation with "
            "zero translation (depth eye at IMU origin)"
        )

    info(
        f"RGB {rgb_w}x{rgb_h} @ {reader.get_rgb_fps():.1f}fps  "
        f"Depth {depth_w}x{depth_h} @ {reader.get_depth_fps():.1f}fps  "
        f"duration={reader.get_duration():.2f}s"
    )

    # ---- static pinholes -------------------------------------------------
    if has_rgb:
        rr.log(
            "world/camera/image",
            rr.Pinhole(
                resolution=[rgb_w, rgb_h],
                focal_length=[float(K_rgb.fx), float(K_rgb.fy)],
                principal_point=[float(K_rgb.cx), float(K_rgb.cy)],
                camera_xyz=camera_xyz,
            ),
            static=True,
        )
    if has_depth:
        rr.log(
            "world/depth_camera/image",
            rr.Pinhole(
                resolution=[depth_w, depth_h],
                focal_length=[float(K_d.fx), float(K_d.fy)],
                principal_point=[float(K_d.cx), float(K_d.cy)],
                camera_xyz=camera_xyz,
            ),
            static=True,
        )

    # ---- timed-metadata tracks -------------------------------------------
    log_head_pose_track(head_lookup, profile)
    log_all_rigid_pose_tracks(reader, tracks["rigid_pose"], profile)
    log_all_hand_tracks(reader, tracks["hand_joints"], profile)
    log_all_hand_tracks_head_relative(reader, tracks["hand_joints"], head_lookup)
    log_all_body_tracks(reader, tracks["body_joints"], body_frames_by_track)
    log_all_body_tracks_head_relative(
        reader,
        tracks["body_joints"],
        head_lookup,
        body_frames_by_track,
    )
    log_all_body_hand_bridges(
        reader,
        tracks["body_joints"],
        body_frames_by_track,
        hand_lookups,
        profile,
        body_to_hand_bridges,
    )
    log_all_body_hand_bridges_head_relative(
        reader,
        tracks["body_joints"],
        body_frames_by_track,
        head_lookup,
        hand_lookups,
        body_to_hand_bridges,
    )
    log_all_controller_input_tracks(reader, tracks["controller_input"])
    log_all_motion_tracker_tracks(json_metadata_tracks.get("motion_trackers", {}), profile)

    # ---- RFC-003 H2 robot ------------------------------------------------
    if not args.no_robot:
        # Resolve URDF + chain JSON. Defaults follow the in-repo layout
        # (claw/assets/robots/h2_with_sharpa/) so a session captured from
        # this checkout's APK renders without extra flags. Deploys that
        # ship the worker without that tree can override via
        # ROBOT_URDF_PATH / ROBOT_CHAIN_JSON_PATH env vars.
        urdf_path = args.robot_urdf
        chain_json = args.robot_chain
        solution_path = args.robot_solution or (
            input_path.parent / "retargeting" / "robot_solution.jsonl"
        )
        maybe_log_robot(
            session_dir=input_path.parent,
            urdf_path=urdf_path,
            chain_json=chain_json,
            solution_jsonl=solution_path,
        )

    # Head-relative view origin + axes (head at origin, looks down -Z).
    rr.log("head_relative", rr.ViewCoordinates.RUB, static=True)
    rr.log(
        "head_relative/origin",
        rr.Arrows3D(
            origins=[[0, 0, 0]] * 4,
            vectors=[
                [0.2, 0, 0],   # +X (right)
                [0, 0.2, 0],   # +Y (up)
                [0, 0, 0.2],   # +Z (back)
                [0, 0, -0.3],  # head forward (-Z)
            ],
            colors=[[255, 60, 60], [60, 255, 60], [60, 60, 255], [255, 80, 200]],
            labels=["X", "Y", "Z", "gaze"],
        ),
        static=True,
    )
    rr.log(
        "head_relative/head_marker",
        rr.Points3D(positions=[[0, 0, 0]], colors=[[255, 255, 255]], radii=[0.04]),
        static=True,
    )

    # ---- depth pass ------------------------------------------------------
    if has_depth:
        reader.set_read_mode(sm.ReadMode.DEPTH_ONLY)
        reader.reset()
        processed = 0
        depth_ts_cache: List[float] = []
        while reader.has_next():
            df = reader.load_depth()
            ts = df.timestamp
            depth_raw = df.depth.copy()

            head_pose = head_lookup.nearest(ts)
            if head_pose is None:
                continue
            # Compose T_W_I, T_W_S, and the logical camera-frame pose through
            # the same explicit chain used for RGB hand projection.
            T_W_root, T_W_Sd_sensor, T_W_Sd_camera = compose_world_sensor_pose(
                head_pose,
                T_I_Sd,
                profile,
            )
            T_W_Sd = device_logged_camera_pose(T_W_Sd_sensor, profile)
            T_W_Sd[:3, :3] = ensure_right_handed_rotation(T_W_Sd[:3, :3])

            # Range filter — drop pixels outside [depth_min, depth_max].
            depth_raw[(depth_raw < args.depth_min) | (depth_raw > args.depth_max)] = 0
            depth_for_2d = depth_raw[::-1, :].copy() if flip_depth_y else depth_raw
            depth_ts_cache.append(ts)

            set_time_seconds("time", ts)
            log_transform3d(
                "world/depth_camera",
                T_W_Sd[:3, 3],
                Rotation.from_matrix(T_W_Sd[:3, :3]).as_quat(),
                axis_len=0.0,
            )
            try:
                rr.log(
                    "depth2d/depth",
                    rr.DepthImage(
                        depth_for_2d,
                        meter=1.0,
                        depth_range=(args.depth_min, args.depth_max),
                    ),
                )
            except TypeError:
                rr.log("depth2d/depth", rr.DepthImage(depth_for_2d, meter=1.0))

            # 3D point cloud — standard pinhole unprojection then world
            # transform. We do NOT use the OpenXR
            # ``inverse_projection_view`` matrix the reference uses
            # because that lives in the spool sidecar
            # (``depth/frames.jsonl``) which the ingest doesn't upload.
            #
            # Use the device-native logical camera pose for the math
            # (T_W_Sd_camera expects profile camera-frame input;
            # the permuted matrix above is only for logging the camera
            # Transform3D in Rerun's world frame). For Quest the sensor
            # and logical camera poses are identical. The helper is retained
            # for providers that need a local sensor-frame correction; the
            # Pico reference path leaves it as identity and uses UBR.
            #
            # Pair {depth_for_2d, K_d_raw}: depth_for_2d is the row-
            # flipped buffer (row 0 at top, OpenCV row order — the
            # same buffer the 2D Depth tab gets), and K_d_raw.cy is the
            # SDK calibration in OpenCV convention (cy measured from
            # the top). Naively unprojecting depth_raw (row 0 at the
            # PHYSICAL BOTTOM, OpenGL convention from Quest's
            # Environment Depth) with a cy-from-the-top intrinsic puts
            # the row=0 / physical-bottom pixels at negative y_cam,
            # which an OpenCV-Y-down extrinsic then sends "up" in the
            # world — i.e. the vertically-mirrored point cloud users
            # report. The previous workaround (swap K_d↔K_d_raw) only
            # nudges the principal point by a fraction of a pixel since
            # cy_raw ≈ h/2 ≈ h-1-cy_raw, so it never actually fixed the
            # flip; you have to align the buffer's row order with the
            # intrinsics' cy convention.
            pts_cam = project_depth_to_points(depth_for_2d, K_d_raw, stride=args.depth_pc_stride)
            if pts_cam.size:
                R_native = T_W_Sd_camera[:3, :3]
                t_native = T_W_Sd_camera[:3, 3]
                pts_world = (R_native @ pts_cam.T).T + t_native
                if args.depth_pc_stride > 1:
                    pts_world = pts_world[::args.depth_pc_stride]
                T_Sd_W_native = np.linalg.inv(T_W_Sd_camera)
                z_local = (T_Sd_W_native[:3, :3] @ pts_world.T).T[:, 2] + T_Sd_W_native[2, 3]
                colors = depth_colormap_jet(
                    np.abs(z_local), args.depth_min, args.depth_max
                )
                pts_world_logged = device_logged_native_points(pts_world, profile)
                rr.log(
                    "world/depth_pointcloud",
                    rr.Points3D(positions=pts_world_logged, colors=colors, radii=0.012),
                )

                # ---- depth → RGB overlay ----------------------------
                # Re-project the same world-frame points into the RGB
                # camera plane and log as Points2D under the RGB image
                # entity so they overlay on the live video. We use the
                # head pose interpolated to THIS depth timestamp (same
                # T_W_root we already computed) to build the rgb
                # extrinsic — depth + rgb cameras share the camera root,
                # so a stale rgb pose would shear the overlay during
                # head motion.
                if has_rgb and args.depth_overlay_stride > 0:
                    if args.depth_overlay_stride > 1:
                        pts_world_ov = pts_world[::args.depth_overlay_stride]
                    else:
                        pts_world_ov = pts_world
                    _, _, T_W_Srgb_camera_at_depth_ts = compose_world_sensor_pose(
                        head_pose,
                        T_I_Srgb,
                        profile,
                    )
                    uv_rgb, mask_rgb = project_world_points_to_image(
                        pts_world_ov,
                        T_W_Srgb_camera_at_depth_ts,
                        K_rgb,
                        rgb_w,
                        rgb_h,
                        camera_view_coord=profile.camera_view_coord,
                        image_rdf_from_camera=profile.image_rdf_from_camera,
                    )
                    visible_rgb = int(mask_rgb.sum())
                    if visible_rgb > 0:
                        # Colour by distance in the RGB camera's frame
                        # (not the depth camera's) so blue-near /
                        # red-far reads relative to what the viewer is
                        # actually looking at.
                        T_Srgb_W = np.linalg.inv(T_W_Srgb_camera_at_depth_ts)
                        z_rgb = (T_Srgb_W[:3, :3] @ pts_world_ov.T).T[:, 2] + T_Srgb_W[2, 3]
                        ov_colors = depth_colormap_jet(
                            np.abs(z_rgb[mask_rgb]),
                            args.depth_min,
                            args.depth_max,
                        )
                        rr.log(
                            "world/camera/image/depth_overlay",
                            rr.Points2D(
                                positions=uv_rgb[mask_rgb].astype(np.float32),
                                colors=ov_colors,
                                radii=float(args.depth_overlay_radius),
                            ),
                        )
                    else:
                        # Clear stale splats so a brief tracking gap
                        # doesn't leave the last frame's overlay
                        # frozen on screen.
                        rr.log(
                            "world/camera/image/depth_overlay",
                            rr.Points2D(positions=np.zeros((0, 2), dtype=np.float32)),
                        )

            processed += 1
            if args.topk is not None and processed >= args.topk:
                break

        info(f"logged {processed} depth frames")

    # ---- RGB pass --------------------------------------------------------
    if has_rgb:
        reader.set_read_mode(sm.ReadMode.RGB_ONLY)
        reader.reset()
        processed = 0
        joint_drawn_total = 0
        while reader.has_next():
            frame_rgb = reader.load_rgb()
            ts = frame_rgb.timestamp
            head_pose = head_lookup.nearest(ts)
            if head_pose is None:
                continue
            T_W_root, T_W_Srgb_sensor, T_W_Srgb_camera = compose_world_sensor_pose(
                head_pose,
                T_I_Srgb,
                profile,
            )
            T_W_Srgb = device_logged_camera_pose(T_W_Srgb_sensor, profile)
            T_W_Srgb[:3, :3] = ensure_right_handed_rotation(T_W_Srgb[:3, :3])

            set_time_seconds("time", ts)
            log_transform3d(
                "world/camera",
                T_W_Srgb[:3, 3],
                Rotation.from_matrix(T_W_Srgb[:3, :3]).as_quat(),
                axis_len=0.0,
            )
            rgb_bgr = frame_rgb.left_rgb
            rr.log(
                "world/camera/image/rgb",
                rr.Image(rgb_bgr, color_model="BGR").compress(jpeg_quality=args.jpeg_quality),
            )

            # Hand-joint overlay onto the left RGB image. Hand joints
            # arrive in capture/raw world; log_hand_joints_on_image
            # converts them into the device-native world before using
            # the native RGB camera extrinsic for projection.
            for tid, hl in hand_lookups.items():
                hand_frame = hl.nearest_within(ts, HAND_FRAME_MATCH_MAX_DT)
                if hand_frame is None:
                    continue
                joint_drawn_total += log_hand_joints_on_image(
                    rgb_entity_prefix="world/camera/image",
                    track_id=tid,
                    hand_frame=hand_frame,
                    profile=profile,
                    T_W_Srgb_camera=T_W_Srgb_camera,
                    K_rgb=K_rgb,
                    rgb_w=rgb_w,
                    rgb_h=rgb_h,
                    T_W_H_godot=T_W_root,
                    camera2_projection=camera2_projection,
                )

            processed += 1
            if args.topk is not None and processed >= args.topk:
                break

        info(f"logged {processed} RGB frames")
        if hand_lookups:
            info(f"  + {joint_drawn_total} hand-joint splats on RGB across all frames")

    info(f"wrote {output_path} ({output_path.stat().st_size} bytes)")
    return 0


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert a SpatialMP4 capture to a Rerun .rrd recording.",
    )
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--topk",
        type=int,
        default=int(os.environ.get("RERUN_TOPK_FRAMES", "0")) or None,
        help="Cap the number of RGB / depth frames logged (default: unlimited).",
    )
    parser.add_argument("--depth-min", type=float, default=0.1)
    parser.add_argument("--depth-max", type=float, default=15.0)
    parser.add_argument("--depth-pc-stride", type=int, default=2)
    parser.add_argument(
        "--depth-overlay-stride",
        type=int,
        default=int(os.environ.get("RERUN_DEPTH_OVERLAY_STRIDE", "1")),
        help=(
            "Stride over the 3D depth point cloud when splatting onto the RGB "
            "image (>=1; 4 ≈ 100k splats per 1280x1280 frame). Set to 0 to "
            "disable the overlay entirely."
        ),
    )
    parser.add_argument(
        "--depth-overlay-radius",
        type=float,
        default=float(os.environ.get("RERUN_DEPTH_OVERLAY_RADIUS", "2.0")),
        help="Radius (in pixels) of each splat in the depth-on-RGB overlay.",
    )
    parser.add_argument(
        "--world-coord",
        default="RUB",
        help="Rerun ViewCoordinates for the world entity (default RUB = OpenXR Quest).",
    )
    parser.add_argument(
        "--camera-coord",
        default="RDF",
        help="Rerun ViewCoordinates for the camera Pinhole (default RDF = OpenCV).",
    )
    parser.add_argument("--no-floor", action="store_true", help="Disable floor grid.")
    parser.add_argument(
        "--no-depth", action="store_true", help="Skip depth track even if present."
    )
    parser.add_argument(
        "--jpeg-quality",
        type=int,
        default=int(os.environ.get("RERUN_JPEG_QUALITY", "85")),
        help="JPEG quality for the RGB stream stored in the .rrd (default 85).",
    )
    parser.add_argument(
        "--device-type",
        default=os.environ.get("RERUN_DEVICE_TYPE"),
        help="Override device profile: `quest` or `pico`. Default = read from --manifest, else fall back to quest.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="Path to the session's manifest.json (defaults to <input dir>/manifest.json). Used to auto-detect device_type and other capture options.",
    )
    # RFC-003 robot visualization. Default URDF / chain paths follow the
    # in-repo layout (claw/assets/robots/h2_with_sharpa/), resolved
    # relative to THIS script's location so the worker invocation
    # ``uv run scripts/spatialmp4_to_rrd.py --input ... --output ...``
    # picks them up without extra flags. Override via env vars or CLI
    # for deploys that don't ship the claw/ tree.
    _script_dir = Path(__file__).resolve().parent
    _default_urdf = (
        _script_dir / ".." / ".." / ".." / "claw" / "assets" / "robots" /
        "h2_with_sharpa" / "h2_with_sharpa_wave.urdf"
    ).resolve()
    _default_chain = (
        _script_dir / ".." / ".." / ".." / "claw" / "assets" / "robots" /
        "h2_with_sharpa" / "upper_body.json"
    ).resolve()
    parser.add_argument(
        "--robot-urdf",
        type=Path,
        default=Path(os.environ.get("ROBOT_URDF_PATH", str(_default_urdf))),
        help="URDF describing the robot's visual + kinematic tree (default: claw/assets/robots/h2_with_sharpa/h2_with_sharpa_wave.urdf).",
    )
    parser.add_argument(
        "--robot-chain",
        type=Path,
        default=Path(os.environ.get("ROBOT_CHAIN_JSON_PATH", str(_default_chain))),
        help="upper_body.json describing the per-joint axis/origin (must match the on-device retargeter's chain).",
    )
    parser.add_argument(
        "--robot-solution",
        type=Path,
        default=None,
        help="robot_solution.jsonl path (defaults to <input dir>/retargeting/robot_solution.jsonl).",
    )
    parser.add_argument(
        "--no-robot",
        action="store_true",
        help="Skip the H2 robot visualization even when the URDF + solution stream are available.",
    )
    # Older callers passed `--sample-fps` which we now ignore — kept for
    # CLI compatibility so the Node worker can flip between versions
    # without coordination.
    parser.add_argument("--sample-fps", type=float, default=None, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)
    if not args.input.exists():
        fatal(f"input not found: {args.input}")
    try:
        return run(args)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        import traceback
        traceback.print_exc(file=sys.stderr)
        fatal(f"conversion failed: {exc}", code=1)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
