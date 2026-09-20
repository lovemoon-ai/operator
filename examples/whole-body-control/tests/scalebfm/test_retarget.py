"""Conformance of the ported ScaleBridge retargeting against pinned upstream.

Runs the literal upstream XsensProcessor from SCALEBFM_UPSTREAM and compares
outputs with our standalone port. Skips visibly without the upstream source.
"""
import hashlib
import importlib.util
import os
from pathlib import Path
import sys

import numpy as np
import pytest
from scipy.spatial.transform import Rotation

from wbc.controllers.scalebfm.retarget import (
    UPSTREAM_PROCESSOR_PATH,
    UPSTREAM_PROCESSOR_SHA256,
    XSENS_PICK,
    HeadingAlignment,
    heading_rotation,
    process_xsens_body,
)
from wbc.tracking import rotation_wxyz


def xsens_frame(seed=11):
    rng = np.random.default_rng(seed)
    positions = rng.normal(scale=.5, size=(63, 3))
    positions[:, 2] += 1.
    quats = Rotation.random(63, random_state=rng).as_quat()  # xyzw
    return positions, quats[:, [3, 0, 1, 2]]  # wxyz


def test_process_xsens_body_matches_upstream_processor():
    upstream = os.getenv("SCALEBFM_UPSTREAM")
    if not upstream:
        pytest.skip("set SCALEBFM_UPSTREAM to the pinned ScaleBFM source tree")
    path = Path(upstream) / UPSTREAM_PROCESSOR_PATH
    if not path.is_file():
        pytest.skip(f"upstream source missing {UPSTREAM_PROCESSOR_PATH}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != UPSTREAM_PROCESSOR_SHA256:
        pytest.fail(f"upstream processor.py fingerprint changed: {digest}")
    spec = importlib.util.spec_from_file_location("_upstream_xsens_processor", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.pop("_upstream_xsens_processor", None)
    spec.loader.exec_module(module)

    positions, rotations = xsens_frame()
    expected_pos, expected_rot, _ = module.XsensProcessor(scale_factor=.75).process(
        positions, rotations.copy())
    actual_pos, actual_rot = process_xsens_body(positions, rotations, scale_factor=.75)
    np.testing.assert_allclose(actual_pos, expected_pos, atol=1e-6)
    np.testing.assert_allclose(
        rotation_wxyz(actual_rot).as_matrix(), rotation_wxyz(expected_rot).as_matrix(),
        atol=1e-6)


def test_heading_alignment_matches_upstream_formula():
    # quat_offset = target_heading * source_heading^-1, applied as
    # Q * (p - pos_offset) and Q * q, with pos_offset z zeroed.
    source_heading = Rotation.from_euler("z", .7)
    target_heading = Rotation.from_euler("z", -.2)
    source_root = np.array([2., 3., 1.])
    alignment = HeadingAlignment(
        source_root, source_heading.as_quat()[[3, 0, 1, 2]],
        target_heading.as_quat()[[3, 0, 1, 2]])
    np.testing.assert_allclose(alignment.pos_offset, [2., 3., 0.])
    expected_q = target_heading * source_heading.inv()
    assert abs(alignment.quat_offset.magnitude() - expected_q.magnitude()) < 1e-12
    points = np.array([[2., 3., 1.], [2.4, 3., 1.2]])
    rots = np.tile(source_heading.as_quat()[[3, 0, 1, 2]], (2, 1))
    p, q = alignment.apply(points, rots)
    np.testing.assert_allclose(p[0], [0., 0., 1.])
    np.testing.assert_allclose(p[1], expected_q.apply([.4, 0., 1.2]), atol=1e-12)
    np.testing.assert_allclose(
        rotation_wxyz(q).as_matrix(),
        (expected_q * source_heading).as_matrix()[None].repeat(2, axis=0), atol=1e-12)


def test_heading_rotation_is_yaw_of_local_forward_axis():
    yaw = Rotation.from_euler("z", .9)
    tilted = yaw * Rotation.from_euler("x", .3)
    heading = heading_rotation(tilted.as_quat()[[3, 0, 1, 2]])
    forward = heading.apply([1., 0., 0.])
    np.testing.assert_allclose(forward, [np.cos(.9), np.sin(.9), 0.], atol=1e-12)


def test_process_xsens_body_scales_absolute_positions():
    positions, rotations = xsens_frame()
    scaled_pos, _ = process_xsens_body(positions, rotations, scale_factor=.75)
    np.testing.assert_allclose(scaled_pos, positions[XSENS_PICK] * .75, atol=1e-6)
