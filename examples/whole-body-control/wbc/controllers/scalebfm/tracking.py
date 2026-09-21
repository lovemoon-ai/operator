"""ScaleBFM five-point calibration and delayed reference window."""
from collections import deque
import numpy as np
from scipy.spatial.transform import Rotation, Slerp
from .retarget import HeadingAlignment
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
    """PICO five-point retargeting: heading+XY alignment from upstream, plus a
    per-link Cartesian anchor so the operator's calibration pose maps to the
    robot's reset standing pose.

    Upstream ScaleBridge's Xsens deployment zeroes only ``pos_offset``'s XY
    and lets ``scale * human.hip.z`` drive the target pelvis Z directly, then
    lets the other 13 links ride along at their scaled absolute heights. That
    works only because Xsens skeleton dimensions and ``xsens_scale_factor=0.75``
    together happen to bring an average adult's link heights close to the G1
    training standing pose (pelvis 0.782 m, wrists ~0.70 m, ankles ~0.03 m).

    PICO body tracking measures the operator's actual joint heights in world
    Z. Applying a single absolute scale sends every link to a wrong height:
    a standing operator's wrists land ~7 cm low, ankles ~9 cm off the floor,
    pelvis 5-8 cm low. The policy tracks all of them at once and folds the
    disagreement into a persistent crouch. Even a pelvis-only Z anchor
    leaves the ankles floating and the wrists dragging, so the crouch shrinks
    but does not disappear.

    We anchor every five-point link (pelvis, both wrists, both ankles) on
    the robot's reset pose: at calibration each target lands exactly on the
    corresponding robot body, and subsequent frames apply ``scale`` * the
    heading-aligned displacement of that link from its calibration sample.
    This is the standard robot-anchored delta scheme; upstream's shared
    heading+XY math (``HeadingAlignment``) still supplies the yaw.

    Note the per-link anchor changes the XY reference relative to upstream:
    because the offset cancels the alignment's translation exactly, the
    pelvis is anchored on the robot's *reset pelvis XY*, not on the
    alignment's stage origin. BODY-mode locomotion is therefore shifted by
    the robot's reset pelvis offset when that is not at the origin.
    Per-link rotation offsets measured at calibration are the PICO analogue
    of upstream's hardcoded Xsens->G1 arm offsets; see retarget.py for the
    literal upstream port.
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
        pelvis = body_names.index("pelvis")
        # The alignment stage runs on the scaled stream, as upstream does.
        self.alignment = HeadingAlignment(
            human.positions[0] * scale, human.rotations[0], robot_rotations[pelvis])
        self.robot_positions = robot_positions.copy()
        self.robot_rotations = robot_rotations.copy()
        # Per-link anchor: at calibration each aligned point must land on the
        # robot's reset body position. Store the offset so ``apply`` reduces
        # to identity on the calibration frame and to scaled deltas after.
        aligned_pos, _ = self.alignment.apply(
            self.scale * human.positions, human.rotations)
        self.position_offsets = robot_positions[self.indices] - aligned_pos
        aligned = self.alignment.quat_offset * rotation_wxyz(human.rotations)
        self.rotation_offsets = aligned.inv() * rotation_wxyz(robot_rotations[self.indices])

    def apply(self, frame: FivePointFrame) -> tuple[np.ndarray, np.ndarray]:
        positions = self.robot_positions.copy()
        rotations = self.robot_rotations.copy()
        aligned_pos, aligned_rot = self.alignment.apply(
            self.scale * frame.positions, frame.rotations)
        positions[self.indices] = aligned_pos + self.position_offsets
        rotations[self.indices] = wxyz(rotation_wxyz(aligned_rot) * self.rotation_offsets)
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
