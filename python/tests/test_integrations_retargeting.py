"""Adapter tests for the retargeting integration.

They need the `retargeting` solver library, which ships from its own repository
(`pip install ./python` there) and is an optional pyoperator extra.
"""

import unittest

from pyoperator.models import Pose, frame_from_dict
from pyoperator.protocol.retargeting import ProtocolError, RetargetingRequest
from pyoperator.robot import RobotState

from test_models import sample_frame

try:
    import retargeting  # noqa: F401
except ImportError:  # pragma: no cover - environment dependent
    retargeting = None

from pyoperator.integrations.retargeting import (
    GODOT_XR_BODY_TRACKER_JOINTS,
    GODOT_XR_BODY_TRACKER_V1,
    PyOperatorRetargeter,
    end_effector_input_from_pose,
    input_from_payload,
    result_to_wire,
    skeleton_input_from_frame,
)

requires_retargeting = unittest.skipIf(
    retargeting is None, "the retargeting solver library is not installed"
)

EEPOSE_PAYLOAD = {
    "position": [0.31, -0.12, 0.24],
    "orientation_wxyz": [1.0, 0.0, 0.0, 0.0],
}


def body_frame(joint_set: str = GODOT_XR_BODY_TRACKER_V1, frame_id: int = 1) -> dict:
    data = sample_frame(frame_id)
    data["body"] = {
        "active": True,
        "sample_timestamp_ns": 2001,
        "joint_set": joint_set,
        "body_flags": 3,
        "joints": [
            {
                "joint": index,
                "flags": 3,
                "tracked": True,
                "pose": {
                    "valid": True,
                    "sample_timestamp_ns": 2001,
                    "position": [0.0, 1.0 + index * 0.01, 0.0],
                    "rotation": [0.0, 0.0, 0.0, 1.0],
                },
            }
            for index in (1, 4, 9, 10, 12, 13, 24, 51)
        ],
    }
    return data


@requires_retargeting
class PayloadAdapterTests(unittest.TestCase):
    def test_end_effector_payload_becomes_a_canonical_target(self) -> None:
        source = input_from_payload(EEPOSE_PAYLOAD, "end_effector_pose_v1", 99)
        self.assertEqual(source.input_type, "end_effector_pose_v1")
        self.assertEqual(source.timestamp_ns, 99)
        self.assertEqual(source.single().position, (0.31, -0.12, 0.24))
        self.assertEqual(source.grippers, {})

    def test_gripper_travels_with_the_target(self) -> None:
        source = input_from_payload({**EEPOSE_PAYLOAD, "gripper": 0.4}, "end_effector_pose_v1")
        self.assertAlmostEqual(source.grippers["end_effector"], 0.4)

    def test_skeleton_payload_accepts_nested_and_bare_frames(self) -> None:
        joints = {
            "hips": {"valid": True, "pose": {"p": [0.0, 1.0, 0.0], "q": [0.0, 0.0, 0.0, 1.0]}},
            "left_wrist": {"valid": True, "pose": {"p": [-0.6, 1.2, -0.1]}},
            "right_wrist": {"valid": False, "pose": {"p": [0.6, 1.2, -0.1]}},
        }
        for payload in ({"frame": {"joints": joints}}, {"joints": joints}):
            source = input_from_payload(payload, "skeleton_frame_v1", 7)
            self.assertEqual(set(source.joints), {"hips", "left_wrist"})
            # xyzw on the wire becomes wxyz in the library.
            self.assertEqual(source.joints["hips"].orientation_wxyz, (1.0, 0.0, 0.0, 0.0))

    def test_invalid_input_is_reported_with_its_reason_code(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            input_from_payload({"position": [float("nan"), 0.0, 0.0]}, "end_effector_pose_v1")
        self.assertEqual(caught.exception.code, "invalid_input")

    def test_structurally_broken_skeleton_payloads_are_rejected(self) -> None:
        for payload in ({}, {"joints": {}}, {"joints": {"hips": {"valid": False}}}):
            with self.assertRaises(ProtocolError) as caught:
                input_from_payload(payload, "skeleton_frame_v1")
            self.assertEqual(caught.exception.code, "invalid_frame")

    def test_unsupported_input_type_is_rejected(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            input_from_payload({}, "hand_frame_v1")
        self.assertEqual(caught.exception.code, "unsupported_input_type")


@requires_retargeting
class ResultAdapterTests(unittest.TestCase):
    def test_transport_identity_is_attached_to_a_solve_result(self) -> None:
        result = retargeting.RetargetingResult(
            profile_id="so101",
            output=retargeting.JointPositionOutput(
                joint_names=("a", "b"), positions=(0.1, 0.2)
            ),
            status="converged",
            iterations=3,
            solve_time_us=1650,
        )
        wire = result_to_wire(result, RetargetingRequest(11, 22, {})).to_wire()
        self.assertEqual(wire["frame_id"], 11)
        self.assertEqual(wire["timestamp_ns"], 22)
        self.assertEqual(wire["profile_id"], "so101")
        self.assertEqual(wire["q"], [0.1, 0.2])
        self.assertEqual(wire["solve_time_us"], 1650)
        self.assertIn("pos_err_m", wire["metrics"])


@requires_retargeting
class XrFrameAdapterTests(unittest.TestCase):
    def test_body_tracking_becomes_named_canonical_joints(self) -> None:
        source = skeleton_input_from_frame(frame_from_dict(body_frame()))
        self.assertEqual(source.timestamp_ns, 2001)
        self.assertIn("hips", source.joints)
        self.assertIn("upper_chest", source.joints)
        self.assertIn("right_wrist", source.joints)
        self.assertEqual(GODOT_XR_BODY_TRACKER_JOINTS[1], "hips")

    def test_frames_without_usable_body_tracking_yield_nothing(self) -> None:
        self.assertIsNone(skeleton_input_from_frame(frame_from_dict(sample_frame())))
        untracked = body_frame()
        for joint in untracked["body"]["joints"]:
            joint["tracked"] = False
        self.assertIsNone(skeleton_input_from_frame(frame_from_dict(untracked)))

    def test_unknown_joint_sets_are_an_error_not_a_guess(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            skeleton_input_from_frame(frame_from_dict(body_frame("pico_bd_24")))
        self.assertEqual(caught.exception.code, "unsupported_joint_set")

    def test_pose_becomes_an_end_effector_target_in_wxyz(self) -> None:
        source = end_effector_input_from_pose(
            Pose(valid=True, position=(0.1, 0.2, 0.3), rotation=(0.0, 0.0, 1.0, 0.0)),
            timestamp_ns=5,
            gripper=0.25,
        )
        self.assertEqual(source.single().orientation_wxyz, (0.0, 0.0, 0.0, 1.0))
        self.assertAlmostEqual(source.grippers["end_effector"], 0.25)


@requires_retargeting
class PyOperatorRetargeterTests(unittest.TestCase):
    """The Outside Python path: XrFrame in, JointTarget out, same profile."""

    def _robot_state(self) -> RobotState:
        """Report the arm at its home pose, so the first target is reachable."""
        from retargeting.lie import mat_to_quat

        robot = self.retargeter.session.robot
        transform = robot.fk(robot.home_q)
        w, x, y, z = mat_to_quat(transform[:3, :3]).tolist()
        return RobotState(
            timestamp_ns=1,
            ee_poses={
                "end_effector": Pose(
                    valid=True,
                    position=tuple(transform[:3, 3].tolist()),
                    rotation=(x, y, z, w),
                )
            },
        )

    def setUp(self) -> None:
        self.retargeter = PyOperatorRetargeter("so101", source="controller")
        self.addCleanup(self.retargeter.close)

    def test_controller_motion_produces_joint_positions(self) -> None:
        target = self.retargeter.retarget(frame_from_dict(sample_frame()), self._robot_state())
        self.assertIsNotNone(target)
        self.assertEqual(len(target.positions), len(self.retargeter.profile.joint_names))
        self.assertAlmostEqual(target.gripper, 0.0)

    def test_unsolvable_frame_holds_the_last_target(self) -> None:
        state = self._robot_state()
        held = self.retargeter.retarget(frame_from_dict(sample_frame()), state)

        unreachable = sample_frame(2)
        unreachable["controllers"]["right"]["pose"]["position"][0] += 5.0
        self.assertIs(self.retargeter.retarget(frame_from_dict(unreachable), state), held)

        self.retargeter.hold_on_failure = False
        self.assertIsNone(self.retargeter.retarget(frame_from_dict(unreachable), state))

    def test_released_deadman_produces_no_command(self) -> None:
        released = sample_frame()
        released["controllers"]["right"]["input"]["values"]["grip"] = 0.0
        self.assertIsNone(
            self.retargeter.retarget(frame_from_dict(released), self._robot_state())
        )

    def test_reset_clears_session_and_anchor(self) -> None:
        self.retargeter.retarget(frame_from_dict(sample_frame()), self._robot_state())
        self.retargeter.reset()
        self.assertIsNone(self.retargeter._last_target)

    def test_body_source_requires_body_tracking(self) -> None:
        retargeter = PyOperatorRetargeter("so101", source="body")
        self.addCleanup(retargeter.close)
        self.assertIsNone(
            retargeter.retarget(frame_from_dict(sample_frame()), self._robot_state())
        )

    def test_unknown_source_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            PyOperatorRetargeter("so101", source="telepathy")
