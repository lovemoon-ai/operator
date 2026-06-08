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
  * **Ingest only ships ``media.mp4`` + ``manifest.json``**, no
    ``depth/frames.jsonl`` / ``*_camera_characteristics.json`` spool
    sidecars (see ``xr/scripts/ego_uploader.gd:22-26``). So the
    reference's "depth on RGB overlay via Camera2-to-Unity" path is
    skipped here — we use ``T_W_Srgb = T_W_H @ T_I_Srgb`` straight
    out of the mp4's RGB extrinsics and accept the live-writer's
    documented ~10° X-axis bias rather than reconstruct the
    correction without the sidecar inputs.
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
       must be passed through ``sm.head_to_imu(pose, HEAD_MODEL_OFFSET)``
       before composing with the RGB extrinsic.
    2. **Extrinsic axis convention** — Pico's native axes need a
       cyclic permutation ``[[0,0,1,0],[1,0,0,0],[0,1,0,0],[0,0,0,1]]``
       on the composed ``T_W_S`` before logging.
    3. **Pinhole camera_xyz** — Quest = ``RDF`` (OpenCV); Pico = ``UBR``.
  World coordinate system is ``RUB`` for both — no permutation there.

Coordinate conventions (mirrored from reference):
  * **world**: ``rr.ViewCoordinates.RUB``
      Quest / OpenXR — X-right, Y-up, Z-back-out-of-page. Head pose
      and all mett rigid_pose tracks live here in absolute world
      coordinates.
  * **camera (RGB + depth)**: ``rr.ViewCoordinates.RDF`` on the
      Pinhole — OpenCV image axes, X-right, Y-down, Z-forward. The
      mp4 RGB extrinsics encode IMU → OpenCV camera, so feeding the
      composed ``T_W_S = T_W_H @ T_I_S`` matrix straight into Rerun's
      ``Transform3D`` is correct.
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
import sys
import sysconfig
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple


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
      3. Hardcoded common dev paths.
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
        "check that the autodetect path resolved on the server."
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
                                 Pico's needs ``sm.head_to_imu(pose,
                                 HEAD_MODEL_OFFSET)`` to get an IMU pose
                                 before composing with the RGB / depth
                                 extrinsics.
      * ``extrinsic_perm``     — 4×4 axis swap applied to the composed
                                 ``T_W_S`` for both RGB and depth cameras
                                 before handing it to Rerun. Quest = None
                                 (identity); Pico maps native (X,Y,Z) →
                                 (Z,X,Y) so the device-local axes line
                                 up with Rerun's world.
      * ``camera_view_coord``  — Pinhole's ``camera_xyz``. Quest = RDF
                                 (OpenCV image axes); Pico = UBR (X-up,
                                 Y-back, Z-right). World coord system
                                 is RUB for both.
    """
    name: str
    head_is_imu: bool
    extrinsic_perm: Optional[np.ndarray]
    camera_view_coord: str


_PICO_PERM = np.array(
    [
        [0.0, 0.0, 1.0, 0.0],
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ],
    dtype=np.float64,
)


PROFILE_QUEST = DeviceProfile(
    name="quest",
    head_is_imu=True,
    extrinsic_perm=None,
    camera_view_coord="RDF",
)

PROFILE_PICO = DeviceProfile(
    name="pico",
    head_is_imu=False,
    extrinsic_perm=_PICO_PERM,
    camera_view_coord="UBR",
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
        info("device profile: PICO (head→IMU offset, UBR camera, axis perm)")
        return PROFILE_PICO
    if candidate.startswith("quest"):
        info("device profile: QUEST (head==IMU, RDF camera, no axis perm)")
        return PROFILE_QUEST
    info(f"device profile: defaulting to QUEST (manifest hint='{candidate}')")
    return PROFILE_QUEST


def head_pose_matrix(pose, profile: DeviceProfile) -> np.ndarray:
    """4×4 IMU pose for a head sample, per device profile.

    Quest: the head mett track already stores the IMU pose, so return
    pose verbatim. Pico: the per-frame pose is mid-eye, so we lift it
    to the IMU origin via the SDK's ``head_to_imu`` helper which
    applies the published ``HEAD_MODEL_OFFSET`` translation under the
    Pico-specific quaternion convention.
    """
    mat = pose_frame_to_matrix(pose)
    if profile.head_is_imu:
        return mat
    return sm.head_to_imu(mat, sm.HEAD_MODEL_OFFSET)


def device_logged_camera_pose(T_W_S: np.ndarray, profile: DeviceProfile) -> np.ndarray:
    """The matrix we hand to Rerun for ``world/camera`` Transform3D.

    Pico stores extrinsics in a frame that doesn't line up with Rerun
    world axes; apply the published cyclic permutation before logging
    (see ``pico_pose_to_open3d`` in the reference). Quest is a no-op.

    NOTE on Pico hand / head / point-cloud positions: the same
    world-axis permutation logically applies to any 3-vector we log
    under ``world/*``, not just camera transforms. We haven't wired
    that path yet because the reference Pico viewer doesn't expose
    hand/controller tracks, and we have no Pico capture in CI to
    validate against. If you point this script at a real Pico mp4 and
    the camera frustum sits in the right place but the hands/floor
    grid don't, that's the missing per-point permutation talking —
    fix is to multiply every 3-vector by ``profile.extrinsic_perm[:3, :3]``
    before passing to ``rr.log`` (positions only; rotations need the
    similarity ``perm @ R @ perm.T``).
    """
    if profile.extrinsic_perm is None:
        return T_W_S
    return profile.extrinsic_perm @ T_W_S


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


def log_hand_frame(track_id: str, hand_frame) -> None:
    """Log hand joints + bones directly in world coordinates."""
    joints = hand_frame.joints
    if not joints:
        return

    positions = np.array([[j.x, j.y, j.z] for j in joints], dtype=np.float64)
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


def log_rigid_pose(track_id: str, pose, axis_len: float = 0.08) -> None:
    mat = pose_frame_to_matrix(pose)
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


def collect_tracks(reader) -> Dict[str, List[str]]:
    rigid: List[str] = []
    hands: List[str] = []
    inputs: List[str] = []
    for tid in reader.list_timed_metadata_tracks():
        if reader.get_rigid_pose_frames(tid):
            rigid.append(tid)
            continue
        if reader.get_hand_joint_frames(tid):
            hands.append(tid)
            continue
        if reader.get_controller_input_frames(tid):
            inputs.append(tid)
    return {"rigid_pose": rigid, "hand_joints": hands, "controller_input": inputs}


def log_all_rigid_pose_tracks(reader, track_ids: Sequence[str]) -> None:
    for tid in track_ids:
        if tid == "head":
            # head is rendered as world/camera + world/trajectory below.
            continue
        for pose in reader.get_rigid_pose_frames(tid):
            if pose.timestamp <= 0:
                continue
            set_time_seconds("time", pose.timestamp)
            log_rigid_pose(tid, pose)


def log_all_hand_tracks(reader, track_ids: Sequence[str]) -> None:
    for tid in track_ids:
        for frame in reader.get_hand_joint_frames(tid):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            log_hand_frame(tid, frame)


def log_all_hand_tracks_head_relative(
    reader, track_ids: Sequence[str], head_lookup: PoseLookup
) -> None:
    for tid in track_ids:
        for frame in reader.get_hand_joint_frames(tid):
            if frame.timestamp <= 0:
                continue
            set_time_seconds("time", frame.timestamp)
            log_hand_frame_head_relative(tid, frame, head_lookup)


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


# ---------------------------------------------------------------------------
# Head trajectory + floor grid (purely visual; matches reference)
# ---------------------------------------------------------------------------


def log_head_pose_track(head_lookup: PoseLookup) -> None:
    if head_lookup.empty():
        return

    traj = head_lookup.trajectory_xyz()
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
        log_rigid_pose("head", f, axis_len=0.1)
        mat = pose_frame_to_matrix(f)
        # OpenXR head looks down its local -Z axis (RUB convention).
        forward = -mat[:3, 2]
        origin = mat[:3, 3]
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
    z_near: float = 0.05,
) -> Tuple[np.ndarray, np.ndarray]:
    """Project world-frame points into a 2D image given the camera
    extrinsic in the **device's native** orientation.

    Returns ``(uv, mask)`` where ``uv`` is (N, 2) image coords (NaN for
    invalid joints, so the array stays addressable by joint index) and
    ``mask`` is (N,) True for joints in front of the camera AND inside
    the image rectangle.

    Why pass ``camera_view_coord``: Quest's mp4 extrinsic puts world
    points into an RDF-style frame so the standard OpenCV pinhole
    formula applies directly. Pico's puts them into UBR; we permute
    UBR→RDF first so the same formula keeps working. This way the
    Pinhole entity stays in the device's native convention (matching
    what the reference scripts log) while the projection math stays
    in one canonical place.
    """
    n = world_pts.shape[0]
    nan = np.full((n, 2), np.nan, dtype=np.float64)
    if n == 0:
        return nan, np.zeros((0,), dtype=bool)

    T_S_W = np.linalg.inv(T_W_S_native)
    p_native = (T_S_W[:3, :3] @ world_pts.T).T + T_S_W[:3, 3]

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


def log_hand_joints_on_image(
    rgb_entity_prefix: str,
    track_id: str,
    hand_frame,
    T_W_Srgb_native: np.ndarray,
    K_rgb,
    rgb_w: int,
    rgb_h: int,
    camera_view_coord: str,
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
    uv, mask = project_world_points_to_image(
        positions, T_W_Srgb_native, K_rgb, rgb_w, rgb_h, camera_view_coord
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
        rrb.Spatial3DView(name="3D Hand (head-relative)", origin="head_relative"),
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
    # camera_xyz (Quest=RDF, Pico=UBR). `--manifest` may be explicit, or
    # we look next to the input for the standard ingest layout
    # (data/sessions/<id>/{media.mp4,manifest.json}).
    manifest_path: Optional[Path] = args.manifest.resolve() if args.manifest else None
    if manifest_path is None:
        guess = input_path.parent / "manifest.json"
        if guess.exists():
            manifest_path = guess
    profile = detect_device_profile(args.device_type, manifest_path)
    # Profile wins over CLI default for camera_xyz (the user almost
    # never wants Quest's RDF on a Pico capture); explicit non-default
    # CLI flag still wins over profile.
    if args.camera_coord.upper() == "RDF":  # the parser's default
        args.camera_coord = profile.camera_view_coord

    info(f"opening {input_path}")
    reader = sm.Reader(str(input_path))

    has_rgb = reader.has_rgb()
    has_depth = reader.has_depth() and not args.no_depth

    if not has_rgb and not has_depth:
        fatal("input has neither RGB nor depth — nothing to visualize")

    tracks = collect_tracks(reader)
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

    # ---- recording init ---------------------------------------------------
    rec_name = f"spatialmp4_{input_path.stem}"
    rr.init(rec_name, spawn=False)
    rr.save(str(output_path))
    rr.send_blueprint(build_blueprint(has_depth_panel=has_depth))

    # ---- world coord system ----------------------------------------------
    # Captures follow OpenXR Quest convention: world is RUB
    # (X-right, Y-up, Z-back-out-of-page); camera local frame is RDF
    # (X-right, Y-down, Z-forward, OpenCV image axes). Feeding the mp4
    # extrinsics directly to Rerun lines everything up because the
    # extrinsics were authored against the same convention.
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
        traj = head_lookup.trajectory_xyz()
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
    log_head_pose_track(head_lookup)
    log_all_rigid_pose_tracks(reader, tracks["rigid_pose"])
    log_all_hand_tracks(reader, tracks["hand_joints"])
    log_all_hand_tracks_head_relative(reader, tracks["hand_joints"], head_lookup)
    log_all_controller_input_tracks(reader, tracks["controller_input"])

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
            # Quest: head_pose IS the IMU pose. Pico: convert mid-eye →
            # IMU via the SDK helper before composing.
            T_W_I = head_pose_matrix(head_pose, profile)
            T_W_Sd_native = T_W_I @ T_I_Sd
            T_W_Sd = device_logged_camera_pose(T_W_Sd_native, profile)
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
            # Use the **native** extrinsic for the math (pts_cam are
            # OpenCV-style; the permuted matrix above is only for
            # logging the camera Transform3D in Rerun's world frame).
            # For Quest this is the same matrix; for Pico keeping them
            # separated prevents the cloud from rotating off the
            # camera.
            #
            # Use K_d_raw, NOT K_d: depth_raw is the un-flipped sensor
            # buffer, and K_d's cy was inverted to match the (flipped)
            # 2D depth image we hand to Rerun. Pairing one with the
            # other mirrors Y in the unprojection, which then puts the
            # 3D point cloud upside-down in the world view.
            pts_cam = project_depth_to_points(depth_raw, K_d_raw, stride=args.depth_pc_stride)
            if pts_cam.size:
                R_native = T_W_Sd_native[:3, :3]
                t_native = T_W_Sd_native[:3, 3]
                pts_world = (R_native @ pts_cam.T).T + t_native
                if args.depth_pc_stride > 1:
                    pts_world = pts_world[::args.depth_pc_stride]
                T_Sd_W_native = np.linalg.inv(T_W_Sd_native)
                z_local = (T_Sd_W_native[:3, :3] @ pts_world.T).T[:, 2] + T_Sd_W_native[2, 3]
                colors = depth_colormap_jet(
                    np.abs(z_local), args.depth_min, args.depth_max
                )
                rr.log(
                    "world/depth_pointcloud",
                    rr.Points3D(positions=pts_world, colors=colors, radii=0.012),
                )

                # ---- depth → RGB overlay ----------------------------
                # Re-project the same world-frame points into the RGB
                # camera plane and log as Points2D under the RGB image
                # entity so they overlay on the live video. We use the
                # head pose interpolated to THIS depth timestamp (same
                # T_W_I we already computed) to build the rgb
                # extrinsic — depth + rgb cameras share the IMU root,
                # so a stale rgb pose would shear the overlay during
                # head motion.
                if has_rgb and args.depth_overlay_stride > 0:
                    if args.depth_overlay_stride > 1:
                        pts_world_ov = pts_world[::args.depth_overlay_stride]
                    else:
                        pts_world_ov = pts_world
                    T_W_Srgb_native_at_depth_ts = T_W_I @ T_I_Srgb
                    uv_rgb, mask_rgb = project_world_points_to_image(
                        pts_world_ov,
                        T_W_Srgb_native_at_depth_ts,
                        K_rgb,
                        rgb_w,
                        rgb_h,
                        camera_view_coord=profile.camera_view_coord,
                    )
                    visible_rgb = int(mask_rgb.sum())
                    if visible_rgb > 0:
                        # Colour by distance in the RGB camera's frame
                        # (not the depth camera's) so blue-near /
                        # red-far reads relative to what the viewer is
                        # actually looking at.
                        T_Srgb_W = np.linalg.inv(T_W_Srgb_native_at_depth_ts)
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
        # Pre-build per-hand-track timestamp lookups so each RGB frame
        # can pick up its nearest hand sample for the 2D overlay.
        hand_lookups: Dict[str, HandFrameLookup] = {
            tid: HandFrameLookup(reader.get_hand_joint_frames(tid))
            for tid in tracks["hand_joints"]
        }
        if hand_lookups:
            info(
                "hand tracks for RGB overlay: "
                + ", ".join(f"{tid}={'empty' if hl.empty() else 'ok'}" for tid, hl in hand_lookups.items())
            )
        # Tolerance for matching a hand frame to an RGB frame. RGB is
        # ~50 fps (20 ms cadence), hands are ~60-90 Hz; 80 ms keeps
        # stale joints off the image during brief tracking gaps.
        HAND_MATCH_MAX_DT = 0.08

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
            T_W_I = head_pose_matrix(head_pose, profile)
            T_W_Srgb_native = T_W_I @ T_I_Srgb
            T_W_Srgb = device_logged_camera_pose(T_W_Srgb_native, profile)
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

            # Hand-joint overlay onto the left RGB image. We project
            # in the **native** (un-permuted) camera frame because the
            # extrinsic K K_rgb encodes IMU → native sensor; the
            # projection helper handles the UBR→RDF axis swap when the
            # device requires it.
            for tid, hl in hand_lookups.items():
                hand_frame = hl.nearest_within(ts, HAND_MATCH_MAX_DT)
                if hand_frame is None:
                    continue
                joint_drawn_total += log_hand_joints_on_image(
                    rgb_entity_prefix="world/camera/image",
                    track_id=tid,
                    hand_frame=hand_frame,
                    T_W_Srgb_native=T_W_Srgb_native,
                    K_rgb=K_rgb,
                    rgb_w=rgb_w,
                    rgb_h=rgb_h,
                    camera_view_coord=profile.camera_view_coord,
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
        default=int(os.environ.get("RERUN_DEPTH_OVERLAY_STRIDE", "4")),
        help=(
            "Stride over the 3D depth point cloud when splatting onto the RGB "
            "image (>=1; 4 ≈ 100k splats per 1280x1280 frame). Set to 0 to "
            "disable the overlay entirely."
        ),
    )
    parser.add_argument(
        "--depth-overlay-radius",
        type=float,
        default=float(os.environ.get("RERUN_DEPTH_OVERLAY_RADIUS", "1.5")),
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
