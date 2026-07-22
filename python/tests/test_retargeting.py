import unittest
from types import MappingProxyType

from pyoperator.models import Pose, frame_from_dict
from pyoperator.retargeting import PoseDeltaRetargeter
from pyoperator.robot import RobotState

from test_models import sample_frame


class RetargetingTests(unittest.TestCase):
    @staticmethod
    def _state(*, valid: bool = True) -> RobotState:
        return RobotState(
            timestamp_ns=1,
            ee_poses=MappingProxyType(
                {"end_effector": Pose(valid=valid, position=(0.3, 0.0, 0.2))}
            ),
        )

    def test_deadman_captures_reference_then_maps_delta(self) -> None:
        state = self._state()
        retargeter = PoseDeltaRetargeter(translation_scale=2.0)
        first = retargeter.retarget(frame_from_dict(sample_frame(1)), state)
        self.assertEqual(first.ee_pose.position, (0.3, 0.0, 0.2))

        moved = sample_frame(2)
        moved["controllers"]["right"]["pose"]["position"][0] += 0.1
        target = retargeter.retarget(frame_from_dict(moved), state)
        self.assertAlmostEqual(target.ee_pose.position[0], 0.5)

    def test_deadman_release_returns_none_and_resets(self) -> None:
        data = sample_frame()
        data["controllers"]["right"]["input"]["values"]["grip"] = 0.0
        self.assertIsNone(PoseDeltaRetargeter().retarget(frame_from_dict(data), self._state()))

    def test_invalid_or_missing_tracking_does_not_emit_command(self) -> None:
        invalid = sample_frame()
        invalid["controllers"]["right"]["pose"]["valid"] = False
        retargeter = PoseDeltaRetargeter()
        self.assertIsNone(retargeter.retarget(frame_from_dict(invalid), self._state()))

        missing = sample_frame()
        missing["controllers"]["right"] = None
        self.assertIsNone(retargeter.retarget(frame_from_dict(missing), self._state()))
        self.assertIsNone(
            retargeter.retarget(
                frame_from_dict(sample_frame()),
                RobotState(timestamp_ns=1, ee_poses=MappingProxyType({})),
            )
        )
        self.assertIsNone(retargeter.retarget(frame_from_dict(sample_frame()), self._state(valid=False)))

    def test_left_hand_and_disabled_gripper_are_supported(self) -> None:
        data = sample_frame()
        data["controllers"]["left"] = data["controllers"]["right"]
        data["controllers"]["right"] = None
        command = PoseDeltaRetargeter(hand="left", gripper_input=None).retarget(
            frame_from_dict(data), self._state()
        )
        self.assertIsNotNone(command)
        self.assertIsNone(command.gripper)

    def test_rotation_delta_is_applied_and_normalized(self) -> None:
        retargeter = PoseDeltaRetargeter()
        retargeter.retarget(frame_from_dict(sample_frame(1)), self._state())
        moved = sample_frame(2)
        moved["controllers"]["right"]["pose"]["rotation"] = [0.0, 0.0, 1.0, 0.0]
        command = retargeter.retarget(frame_from_dict(moved), self._state())
        self.assertAlmostEqual(sum(value * value for value in command.ee_pose.rotation), 1.0)
        self.assertEqual(command.ee_pose.rotation, (0.0, 0.0, 1.0, 0.0))

    def test_constructor_rejects_unknown_hand(self) -> None:
        with self.assertRaisesRegex(ValueError, "hand must"):
            PoseDeltaRetargeter(hand="middle")
