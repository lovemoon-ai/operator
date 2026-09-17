"""Shared body-pose validation and coordinates, independent of controller.

Each controller chooses its own required named joints. Arrays use metres,
Z up, and wxyz quaternions.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy.spatial.transform import Rotation

from pyoperator.integrations.retargeting import BODY_JOINT_SETS
from pyoperator.models import XrFrame

# Robot Z-up to the Blueprint model asset's XR Y-up coordinate convention.
ROBOT_TO_XR = np.array([[0., -1., 0.], [0., 0., 1.], [-1., 0., 0.]])
# XR SDK mode sends Pico's native 24-joint order, not the Godot order. Keep
# this mapping aligned with xr/scripts/robot_constraint/pico_body_adapter.gd.
PICO_BODY_JOINTS = (
    "hips", "left_upper_leg", "right_upper_leg", "spine", "left_lower_leg",
    "right_lower_leg", "chest", "left_foot", "right_foot", "upper_chest",
    "left_toes", "right_toes", "neck", "left_scapula", "right_scapula", "head",
    "left_shoulder", "right_shoulder", "left_lower_arm", "right_lower_arm",
    "left_wrist", "right_wrist", "left_hand", "right_hand",
)


class TrackingUnavailable(ValueError):
    pass


def rotation_wxyz(quaternions: np.ndarray) -> Rotation:
    return Rotation.from_quat(np.asarray(quaternions)[..., [1, 2, 3, 0]])


def wxyz(rotation: Rotation) -> np.ndarray:
    return rotation.as_quat()[..., [3, 0, 1, 2]]


@dataclass(frozen=True)
class TrackedPoints:
    timestamp_ns: int
    positions: np.ndarray
    rotations: np.ndarray


def extract_points(frame: XrFrame, required_names: tuple[str, ...]) -> TrackedPoints:
    body = frame.body
    if body is None or not body.active:
        raise TrackingUnavailable("Full-body tracking is not active")
    if frame.coordinate_space not in ("godot_world", "xr_origin", "openxr_stage"):
        raise TrackingUnavailable(f"Unsupported coordinate space: {frame.coordinate_space}")
    pico = body.joint_set == "pico_bd_24"
    names = PICO_BODY_JOINTS if pico else BODY_JOINT_SETS.get(body.joint_set)
    if names is None:
        raise TrackingUnavailable(f"Unsupported body joint set: {body.joint_set}")
    by_name = {names[j.joint]: j for j in body.joints if 0 <= j.joint < len(names)}
    positions, rotations = [], []
    for name in required_names:
        joint = by_name.get(name)
        if joint is None or not joint.tracked or not joint.pose.valid:
            raise TrackingUnavailable(f"Missing tracked 6DoF pose: {name}")
        # The sender's broad tracked/valid flags also accept partial poses.
        # Godot and OpenXR/Pico use different bit assignments; require both
        # position and orientation, never treat an identity fallback as 6DoF.
        position_bits, rotation_bits = (0xA, 0x5) if pico else (0xC, 0x3)
        if not joint.flags & position_bits or not joint.flags & rotation_bits:
            raise TrackingUnavailable(f"Missing tracked 6DoF pose: {name} (partial flags)")
        position = np.asarray(joint.pose.position, dtype=float)
        quaternion = np.asarray(joint.pose.rotation, dtype=float)
        quaternion_norm = np.linalg.norm(quaternion)
        if not np.isfinite(position).all() or np.max(np.abs(position)) > 10000 \
                or not np.isfinite(quaternion).all() or not np.isfinite(quaternion_norm) \
                or quaternion_norm < 1e-8:
            raise TrackingUnavailable(f"Invalid pose: {name}")
        positions.append(ROBOT_TO_XR.T @ position)
        rotations.append(wxyz(Rotation.from_matrix(
            ROBOT_TO_XR.T @ Rotation.from_quat(quaternion).as_matrix() @ ROBOT_TO_XR
        )))
    timestamp = body.sample_timestamp_ns or frame.timestamp_ns
    if timestamp <= 0:
        raise TrackingUnavailable("Body sample has no timestamp")
    return TrackedPoints(timestamp, np.asarray(positions), np.asarray(rotations))


def base_pose_to_xr(position: np.ndarray, quaternion_wxyz: np.ndarray) -> list[float]:
    rotation = ROBOT_TO_XR @ rotation_wxyz(quaternion_wxyz).as_matrix() @ ROBOT_TO_XR.T
    return [*(ROBOT_TO_XR @ position).tolist(), *Rotation.from_matrix(rotation).as_quat().tolist()]
