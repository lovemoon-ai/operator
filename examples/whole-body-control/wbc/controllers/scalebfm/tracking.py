"""ScaleBFM five-point calibration and delayed reference window."""
from collections import deque
import numpy as np
from scipy.spatial.transform import Rotation, Slerp
from ...tracking import (
    TrackedPoints as FivePointFrame, TrackingUnavailable, extract_points,
    ROBOT_TO_XR, PICO_BODY_JOINTS, rotation_wxyz, wxyz, base_pose_to_xr,
)

FIVE_POINTS = {
    "pelvis": "hips",
    "left_wrist_yaw_link": "left_wrist",
    "right_wrist_yaw_link": "right_wrist",
    "left_ankle_roll_link": "left_foot",
    "right_ankle_roll_link": "right_foot",
}


def extract_five_points(frame):
    points = extract_points(frame, tuple(FIVE_POINTS.values()))
    if np.linalg.norm(points.positions[3] - points.positions[4]) < 0.03:
        raise TrackingUnavailable("Foot poses are collapsed; calibrate full-body tracking")
    return points


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
