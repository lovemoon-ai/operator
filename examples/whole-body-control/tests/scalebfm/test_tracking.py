"""Host-side math/contract tests; these do not replace headset coverage."""
from dataclasses import replace

import numpy as np
import pytest
from scipy.spatial.transform import Rotation

from pyoperator import BodyState, ControllerPair, HandPair, Joint, Pose, XrFrame
from pyoperator.integrations.retargeting import GODOT_XR_BODY_TRACKER_JOINTS
from wbc.controllers.scalebfm.tracking import (Calibration, FIVE_POINTS, FivePointFrame, ReferenceBuffer,
                      ROBOT_TO_XR, TrackingUnavailable, base_pose_to_xr,
                      extract_five_points, rotation_wxyz, wxyz)
from wbc.controllers.scalebfm.tracking import PICO_BODY_JOINTS


@pytest.mark.parametrize("joint_set,names", [("godot_xr_body_tracker_v1", GODOT_XR_BODY_TRACKER_JOINTS),
                                             ("pico_bd_24", PICO_BODY_JOINTS)])
def test_extract_uses_five_named_body_joints_not_head_or_joint_order(joint_set, names):
    joints = tuple(Joint(joint=names.index(name), tracked=True, flags=15,
                         pose=Pose(valid=True, position=(2 if name == "right_foot" else 1, 2, 3)))
                   for name in reversed(list(FIVE_POINTS.values())))
    body = BodyState(active=True, sample_timestamp_ns=123, joint_set=joint_set, joints=joints)
    frame = XrFrame(1, 1, 123, "godot_world", None, ControllerPair(), HandPair(), body, ())
    result = extract_five_points(frame)
    assert result.timestamp_ns == 123
    expected = np.tile([-3., -1, 2], (5, 1))
    expected[4, 1] = -2
    np.testing.assert_allclose(result.positions, expected)
    np.testing.assert_allclose(result.rotations, np.tile([1, 0, 0, 0], (5, 1)))
    with pytest.raises(TrackingUnavailable, match="Missing tracked"):
        extract_five_points(replace(frame, body=replace(body, joints=joints[:-1])))
    with pytest.raises(TrackingUnavailable, match="joint set"):
        extract_five_points(replace(frame, body=replace(body, joint_set="unknown")))
    invalid = replace(joints[0], pose=Pose(valid=True, rotation=(0, 0, 0, 0)))
    with pytest.raises(TrackingUnavailable, match="Invalid pose"):
        extract_five_points(replace(frame, body=replace(body, joints=(invalid, *joints[1:]))))
    partial = replace(joints[0], flags=8)
    with pytest.raises(TrackingUnavailable, match="partial flags"):
        extract_five_points(replace(frame, body=replace(body, joints=(partial, *joints[1:]))))


def test_calibration_scales_absolute_positions_and_aligns_heading():
    # PICO port semantics: upstream heading+XY alignment plus a per-link
    # Cartesian anchor. At calibration each of the five points lands exactly
    # on the corresponding robot reset body; subsequent motion is the
    # heading-aligned scaled delta of each link from its calibration sample.
    neutral = np.array([[0, 0, 1], [-.2, .4, 1.2], [-.2, -.4, 1.2], [.1, .15, 0], [.1, -.15, 0.]])
    heading = Rotation.from_euler("z", .8)
    human = FivePointFrame(1, heading.apply(neutral) + [2, 3, 0], np.tile(wxyz(heading), (5, 1)))
    robot = neutral * .75
    robot_q = np.tile([1., 0, 0, 0], (5, 1))
    calibration = Calibration(human, robot, robot_q, list(FIVE_POINTS), .75)
    p, q = calibration.apply(human)
    # Every five-point link lands exactly on the robot's reset pose.
    np.testing.assert_allclose(p, robot, atol=1e-12)
    np.testing.assert_allclose(rotation_wxyz(q).as_matrix(), rotation_wxyz(robot_q).as_matrix(), atol=1e-12)
    # Any subsequent motion applies a heading-aligned scaled delta uniformly
    # to all five links.
    moved = replace(human, positions=human.positions + heading.apply([.2, 0, .1]),
                    rotations=wxyz(heading * Rotation.from_euler("z", np.full((5, 1), .3))))
    p, q = calibration.apply(moved)
    np.testing.assert_allclose(p - calibration.apply(human)[0],
                               np.tile([.15, 0, .075], (5, 1)), atol=1e-12)
    np.testing.assert_allclose(rotation_wxyz(q).as_euler("xyz")[:, 2], .3)


def test_calibration_anchors_every_five_point_to_robot_reset_pose():
    # Regression: a single pelvis-Z anchor still left the wrists and ankles
    # tracking scaled human-absolute Z, which for a standing PICO operator
    # sends the ankles ~9 cm off the floor and the wrists ~7 cm below the
    # trained standing pose (training G1 ankles ~0.03m, wrists ~0.70m).
    # The policy folded the disagreement into a persistent crouch. Anchoring
    # every five-point link removes it.
    neutral = np.array([[0, 0, .95], [0, .2, .75], [0, -.2, .75], [0, .1, 0.06], [0, -.1, 0.06]])
    human = FivePointFrame(1, neutral, np.tile([1., 0, 0, 0], (5, 1)))
    robot_positions = np.array([[0, 0, .793], [0, .2, .70], [0, -.2, .70], [0, .1, 0.034], [0, -.1, 0.034]])
    robot_rotations = np.tile([1., 0, 0, 0], (5, 1))
    calibration = Calibration(human, robot_positions, robot_rotations, list(FIVE_POINTS), .75)
    p, _ = calibration.apply(human)
    np.testing.assert_allclose(p, robot_positions, atol=1e-9)
    # The calibration-frame identity above holds for any scale, so it cannot on
    # its own show that each link tracks its *own* scaled delta. Pin motion too:
    # a 10 cm human squat must drop every link 7.5 cm from its robot reset
    # height, rather than falling back to scaled human-absolute Z (which would
    # put the ankles at .75 * -.04 = -.03 m, through the floor).
    squat = replace(human, positions=human.positions + [0, 0, -.10])
    np.testing.assert_allclose(
        calibration.apply(squat)[0], robot_positions + [0, 0, -.075], atol=1e-9
    )
    # ...and that the delta really is scaled: a different scale must move it.
    half = Calibration(human, robot_positions, robot_rotations, list(FIVE_POINTS), .5)
    np.testing.assert_allclose(
        half.apply(squat)[0], robot_positions + [0, 0, -.05], atol=1e-9
    )


def test_reference_buffer_delays_without_predicting_and_slerps():
    buffer = ReferenceBuffer(10)
    p = np.zeros((14, 3))
    assert buffer.targets() is None
    for i in range(21):
        q = np.tile(wxyz(Rotation.from_euler("z", i / 100)), (14, 1))
        assert buffer.append(1_000_000_000 + i * 10_000_000, p + i / 100, q)
    assert not buffer.append(1_200_000_000, p, q)
    positions, rotations = buffer.targets()
    np.testing.assert_allclose(positions[:, 0, 0], [0, .02, .04, .06, .08, .2], atol=1e-12)
    np.testing.assert_allclose(rotation_wxyz(rotations[:, 0]).as_euler("xyz")[:, 2],
                               [0, .02, .04, .06, .08, .2], atol=1e-12)
    for i in range(300):
        buffer.append(2_000_000_000 + i, p, q)
    assert len(buffer.samples) == 256


def test_base_pose_conversion_round_trip():
    rotation = Rotation.from_euler("xyz", [.4, .2, -.7])
    pose = base_pose_to_xr(np.array([1, 2, 3]), wxyz(rotation))
    np.testing.assert_allclose(pose[:3], [-2, 3, -1])
    np.testing.assert_allclose(ROBOT_TO_XR.T @ Rotation.from_quat(pose[3:]).as_matrix() @ ROBOT_TO_XR,
                               rotation.as_matrix(), atol=1e-12)
