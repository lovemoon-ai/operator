"""Upstream ScaleBridge retargeting semantics, ported standalone.

ScaleBridge's deployment retargeting (XsensProcessor.process +
MotionTrackingXsensEnv._calibrate) is: uniform absolute scaling of human
positions (xsens_scale_factor, default 0.75), hardcoded arm-link rotation
offsets, thigh-yaw removal relative to the pelvis, and a one-time
heading+XY alignment of the streamed skeleton onto the robot.  This module
ports those semantics so the example's PICO path shares them, and so a
conformance test can compare the literal Xsens port against the pinned
upstream source.
"""
from __future__ import annotations

import numpy as np
from scipy.spatial.transform import Rotation

from ...tracking import rotation_wxyz, wxyz

# Upstream XsensProcessor.POS_PICK/ROT_PICK: Xsens 63-segment indices for the
# 14 policy links (pelvis, legs, torso, arms; see upstream processor.py).
XSENS_PICK = np.array([0, 19, 20, 21, 15, 16, 17, 1, 12, 13, 14, 8, 9, 10])
# Upstream hardcoded "xsens to unitree_g1" arm-link rotation offsets, as
# constant matrices (left/right shoulder, elbow, wrist), applied to links 8:.
XSENS_ARM_LINK_ROT_OFFSET = np.array([
    [[1, 0, 0], [0, 0, -1], [0, 1, 0]],
    [[0, 0, 1], [1, 0, 0], [0, 1, 0]],
    [[0, 0, 1], [1, 0, 0], [0, 1, 0]],
    [[1, 0, 0], [0, 0, 1], [0, -1, 0]],
    [[0, 0, 1], [-1, 0, 0], [0, -1, 0]],
    [[0, 0, 1], [-1, 0, 0], [0, -1, 0]],
], dtype=np.float64)
XSENS_THIGH_LINKS = (1, 4)  # thigh yaw removal targets, relative to pelvis 0

# Fingerprint of the upstream source this port mirrors (ScaleBFM abd6f17).
UPSTREAM_PROCESSOR_PATH = "ScaleBridge/scalebridge/utils/xsens_dataloader/processor.py"
UPSTREAM_PROCESSOR_SHA256 = "520dd73b0df8b6daa336331f287b0bdca63dec64775f38f4d981562028706f1b"


def heading_rotation(quat_wxyz) -> Rotation:
    """Yaw-only rotation of a body quaternion (upstream calc_heading_quat).

    The heading is the body's rotated local +X axis projected onto the XY
    plane; +X is the forward convention for pelvis/root links.
    """
    forward = rotation_wxyz(np.asarray(quat_wxyz, dtype=np.float64)).apply([1., 0., 0.])
    return Rotation.from_euler("z", np.arctan2(forward[..., 1], forward[..., 0]))


def process_xsens_body(positions: np.ndarray, rotations_wxyz: np.ndarray,
                       scale_factor: float = 0.75) -> tuple[np.ndarray, np.ndarray]:
    """XsensProcessor.process() body path, verbatim math on 63-segment input.

    Returns (positions [14,3], rotations wxyz [14,4]): uniform absolute scale,
    hardcoded arm-link offsets, thigh-yaw removal.  Finger retargeting stays
    upstream; the example drives Dex3 through its own bindings.
    """
    positions = np.asarray(positions, dtype=np.float64)
    if positions.ndim != 2 or positions.shape[1] != 3 or positions.shape[0] < 63:
        raise ValueError("Xsens positions must be [63,3]")
    rotations = rotation_wxyz(np.asarray(rotations_wxyz, dtype=np.float64))
    if len(rotations) < 63:
        raise ValueError("Xsens rotations must be [63,4] wxyz")
    if not np.isfinite(scale_factor) or scale_factor <= 0:
        raise ValueError("scale_factor must be finite and positive")

    selected_pos = positions[XSENS_PICK] * scale_factor
    selected_rot = np.empty(14, dtype=object)
    picked = rotations[XSENS_PICK]
    for index in range(14):
        selected_rot[index] = picked[index]

    # Hardcoded arm-link offsets (upstream links 8..13).
    arms = Rotation.concatenate([picked[8:]]) * Rotation.from_matrix(XSENS_ARM_LINK_ROT_OFFSET)
    for offset, index in enumerate(range(8, 14)):
        selected_rot[index] = arms[offset]

    # Thigh yaw removal relative to the pelvis (upstream special_links).
    parents = Rotation.concatenate([picked[0], picked[0]])
    relatives = parents.inv() * Rotation.concatenate([picked[XSENS_THIGH_LINKS[0]],
                                                      picked[XSENS_THIGH_LINKS[1]]])
    euler = relatives.as_euler("YXZ")
    euler[..., -1] *= 0  # remove yaw
    fixed = parents * Rotation.from_euler("YXZ", euler)
    for offset, index in enumerate(XSENS_THIGH_LINKS):
        selected_rot[index] = fixed[offset]

    rotations_out = np.empty((14, 4), dtype=np.float64)
    for index in range(14):
        rotations_out[index] = wxyz(selected_rot[index])
    return (selected_pos.astype(np.float32, copy=False),
            rotations_out.astype(np.float32, copy=False))


class HeadingAlignment:
    """One-time heading+XY alignment (MotionTrackingXsensEnv._calibrate).

    ``pos_offset`` is the source root position at calibration with z zeroed;
    ``quat_offset = target_heading * source_heading^-1``.  Positions must
    already be scaled when they enter/leave this stage, matching upstream
    (the alignment runs on the scaled, buffered stream).
    """

    def __init__(self, source_root_pos: np.ndarray, source_root_quat_wxyz,
                 target_root_quat_wxyz):
        offset = np.asarray(source_root_pos, dtype=np.float64).copy()
        if offset.shape != (3,) or not np.isfinite(offset).all():
            raise ValueError("source root position must be finite [3]")
        offset[2] = 0.0
        self.pos_offset = offset
        source_heading = heading_rotation(source_root_quat_wxyz)
        target_heading = heading_rotation(target_root_quat_wxyz)
        self.quat_offset = target_heading * source_heading.inv()

    def apply(self, positions: np.ndarray, rotations_wxyz: np.ndarray):
        positions = np.asarray(positions, dtype=np.float64)
        aligned_pos = self.quat_offset.apply(positions - self.pos_offset)
        aligned_rot = wxyz(self.quat_offset * rotation_wxyz(rotations_wxyz))
        return aligned_pos, aligned_rot
