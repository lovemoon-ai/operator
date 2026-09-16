"""Five tracked poses -> calibrated, delayed ScaleBFM references (no solver).

The full skeleton is received by pyoperator, but only pelvis/hands/feet enter
the policy targets. All arrays in this module use metres, Z up, wxyz quaternions.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass

import numpy as np
from scipy.spatial.transform import Rotation, Slerp

from pyoperator.integrations.retargeting import BODY_JOINT_SETS
from pyoperator.models import XrFrame

# Robot Z-up to the Blueprint model asset's XR Y-up coordinate convention.
ROBOT_TO_XR = np.array([[0., -1., 0.], [0., 0., 1.], [-1., 0., 0.]])
FIVE_POINTS = {
    "pelvis": "hips",
    "left_wrist_yaw_link": "left_wrist",
    "right_wrist_yaw_link": "right_wrist",
    "left_ankle_roll_link": "left_foot",
    "right_ankle_roll_link": "right_foot",
}
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
class FivePointFrame:
    timestamp_ns: int
    positions: np.ndarray
    rotations: np.ndarray


def extract_five_points(frame: XrFrame) -> FivePointFrame:
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
    for name in FIVE_POINTS.values():
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
    if np.linalg.norm(np.asarray(positions[3]) - positions[4]) < 0.03:
        raise TrackingUnavailable("Foot poses are collapsed; calibrate full-body tracking")
    timestamp = body.sample_timestamp_ns or frame.timestamp_ns
    if timestamp <= 0:
        raise TrackingUnavailable("Body sample has no timestamp")
    return FivePointFrame(timestamp, np.asarray(positions), np.asarray(rotations))


class Calibration:
    """Map the operator's neutral stance to the displayed robot reference pose.

    Per-link orientation offsets remove vendor-specific joint axes. Position
    offsets map each neutral tracked point to its robot link; subsequent motion
    uses one uniform scale and heading, including pelvis translation.
    """
    def __init__(self, human: FivePointFrame, robot_positions: np.ndarray,
                 robot_rotations: np.ndarray, body_names: list[str], scale: float):
        if not np.isfinite(scale) or scale <= 0:
            raise ValueError("scale must be positive")
        self.indices = np.array([body_names.index(n) for n in FIVE_POINTS])
        self.scale = scale
        left = human.positions[3] - human.positions[4]
        if np.linalg.norm(left[:2]) < 0.08:
            raise TrackingUnavailable("Calibration requires feet apart, facing forward")
        # Human left -> robot +Y, human forward -> robot +X.
        yaw = np.arctan2(-left[0], left[1])
        self.alignment = Rotation.from_euler("z", -yaw)
        self.human_positions = human.positions.copy()
        self.robot_positions = robot_positions.copy()
        self.robot_rotations = robot_rotations.copy()
        aligned = self.alignment * rotation_wxyz(human.rotations)
        self.rotation_offsets = aligned.inv() * rotation_wxyz(robot_rotations[self.indices])

    def apply(self, frame: FivePointFrame) -> tuple[np.ndarray, np.ndarray]:
        positions = self.robot_positions.copy()
        rotations = self.robot_rotations.copy()
        positions[self.indices] += self.scale * self.alignment.apply(
            frame.positions - self.human_positions
        )
        rotations[self.indices] = wxyz(
            self.alignment * rotation_wxyz(frame.rotations) * self.rotation_offsets
        )
        # Other body slots are neutral placeholders; control_mode=4 masks them.
        return positions, rotations


class ReferenceBuffer:
    """Bounded source-clock buffer. Never extrapolate future human movement.

    Like ScaleBridge's Xsens path, delay the reference by last_offset * 20ms;
    the newest real sample becomes the final 'future' target in that window.
    """
    def __init__(self, future_last: int = 10):
        if not 5 <= future_last <= 33:
            raise ValueError("future_last must be between 5 and 33")
        self.offsets = np.array([0, 1, 2, 3, 4, future_last], dtype=np.int64)
        self.samples: deque = deque(maxlen=256)

    def append(self, timestamp_ns: int, positions: np.ndarray, rotations: np.ndarray) -> bool:
        if self.samples and timestamp_ns <= self.samples[-1][0]:
            return False
        self.samples.append((timestamp_ns, positions.copy(), rotations.copy()))
        return True

    def targets(self) -> tuple[np.ndarray, np.ndarray] | None:
        if len(self.samples) < 2:
            return None
        latest = self.samples[-1][0]
        # Work relative to the newest timestamp to retain ns precision.
        times = np.array([(s[0] - latest) * 1e-9 for s in self.samples])
        query = (self.offsets - self.offsets[-1]) * 0.02
        if times[0] > query[0]:
            return None
        positions = np.stack([s[1] for s in self.samples])
        rotations = np.stack([s[2] for s in self.samples])
        result_pos = np.empty((6, positions.shape[1], 3))
        result_rot = np.empty((6, positions.shape[1], 4))
        for body in range(positions.shape[1]):
            for axis in range(3):
                result_pos[:, body, axis] = np.interp(query, times, positions[:, body, axis])
            result_rot[:, body] = wxyz(Slerp(times, rotation_wxyz(rotations[:, body]))(query))
        return result_pos, result_rot


def base_pose_to_xr(position: np.ndarray, quaternion_wxyz: np.ndarray) -> list[float]:
    rotation = ROBOT_TO_XR @ rotation_wxyz(quaternion_wxyz).as_matrix() @ ROBOT_TO_XR.T
    return [*(ROBOT_TO_XR @ position).tolist(), *Rotation.from_matrix(rotation).as_quat().tolist()]
