"""Operator's raw PICO/OpenXR records -> the official XRT body-pose array.

The legacy XRT body wire and Operator's pico_bd_24 wire contain the same raw
PICO pose (see xr/scripts/compat/xrobot_toolkit/xrt_tracking_encoder.gd).
Do not apply Operator's robot-axis transform here: upstream does its own
transform and, crucially, the per-joint OFFSETS before pelvis normalization.
"""
from dataclasses import dataclass
import numpy as np
from pyoperator.models import XrFrame
from ...tracking import TrackingUnavailable

# Upstream _process_3pt_pose selects [0,22,23,12], not [20,21,15].
# 22/23 are the PICO hand points which its streamer labels "wrists".
REQUIRED_IDS = (0, 22, 23, 12)


@dataclass(frozen=True)
class PicoSample:
    timestamp_ns: int
    body_poses_np: np.ndarray
    valid_6dof: np.ndarray
    frame: XrFrame


def extract_pico_sample(frame: XrFrame) -> PicoSample:
    body = frame.body
    if body is None or not body.active or body.joint_set != "pico_bd_24":
        raise TrackingUnavailable("Official SONIC VR_3PT requires PICO's pico_bd_24 body stream")
    if frame.coordinate_space not in ("godot_world", "openxr_stage", "xr_origin"):
        raise TrackingUnavailable(f"Unsupported PICO coordinate space: {frame.coordinate_space}")
    records = {joint.joint: joint for joint in body.joints}
    if set(records) != set(range(24)):
        raise TrackingUnavailable("Official PICO body sample must contain all 24 named joint IDs")
    result = np.empty((24, 7), dtype=np.float64)
    valid = np.zeros(24, dtype=bool)
    for index in range(24):
        joint = records[index]
        valid[index] = bool(joint.pose.valid and joint.tracked
                            and joint.flags & 0xA and joint.flags & 0x5)
        if index in REQUIRED_IDS and not valid[index]:
            raise TrackingUnavailable(f"Missing PICO 6DoF point {index} (pelvis/hands/neck required)")
        values = np.asarray((*joint.pose.position, *joint.pose.rotation), dtype=np.float64)
        if not np.isfinite(values).all() or np.linalg.norm(values[3:]) < 1e-8:
            raise TrackingUnavailable(f"Invalid PICO joint {index}")
        result[index] = values
    timestamp = body.sample_timestamp_ns or frame.timestamp_ns
    if timestamp <= 0:
        raise TrackingUnavailable("PICO body sample has no timestamp")
    return PicoSample(timestamp, result, valid, frame)


def require_full_body(sample: PicoSample) -> None:
    """Reject partial PICO skeletons before the SMPL/POSE encoder sees them."""
    missing = np.flatnonzero(~sample.valid_6dof)
    if missing.size:
        raise TrackingUnavailable(
            "SONIC BODY requires all PICO 6DoF joints; missing "
            + ",".join(map(str, missing.tolist()))
        )


class OfficialThreePoint:
    """Delegate preprocessing/calibration to the actual pinned upstream class."""
    def __init__(self, upstream):
        from .official import load_vr_algorithms, make_robot_model
        self.algorithms = load_vr_algorithms(upstream)
        self.robot_model = make_robot_model(upstream)
        self.processor = self.algorithms.ThreePointPose(robot_model=self.robot_model, log_prefix="SONIC")

    def calibrate_full(self, sample: PicoSample):
        # Called only on OFF -> PLANNER, against all-zero *body* joint angles.
        if not self.processor.calibrate_now(sample.body_poses_np):
            raise TrackingUnavailable("Official SONIC CALIB_FULL failed")

    def calibrate_wrists(self, measured_body_q):
        # Entering VR_3PT keeps the neck reference but captures the current
        # measured robot pose. Do not reset MuJoCo here.
        self.processor.reset_with_measured_q(np.asarray(measured_body_q).copy())

    def process(self, sample: PicoSample):
        result = self.processor.process_smpl_pose(sample.body_poses_np)
        return result[:, :3].copy(), result[:, 3:].copy()
