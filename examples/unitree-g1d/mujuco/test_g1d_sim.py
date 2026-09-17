from __future__ import annotations

from types import MappingProxyType
import math
import unittest

import numpy as np

from g1d_sim import DualArmRetargeter, G1DMujocoRobot
from pyoperator.models import (
    ControllerInput,
    ControllerPair,
    ControllerState,
    HandPair,
    Pose,
    XrFrame,
)


def frame(
    frame_id: int,
    *,
    left_position=(0.0, 1.2, -0.4),
    right_position=(0.0, 1.2, -0.4),
    left_grip=0.0,
    right_grip=0.0,
    head_rotation=(0.0, 0.0, 0.0, 1.0),
) -> XrFrame:
    def controller(position, grip):
        return ControllerState(
            pose=Pose(valid=True, position=position),
            input=ControllerInput(values=MappingProxyType({"grip": grip, "trigger": 0.0})),
        )

    return XrFrame(
        schema_version=1,
        frame_id=frame_id,
        timestamp_ns=frame_id,
        coordinate_space="openxr_stage",
        head=Pose(valid=True, rotation=head_rotation),
        controllers=ControllerPair(
            left=controller(left_position, left_grip),
            right=controller(right_position, right_grip),
        ),
        hands=HandPair(),
        body=None,
        motion_trackers=(),
    )


class G1DSimulationTests(unittest.TestCase):
    def test_model_has_two_seven_dof_arms(self) -> None:
        robot = G1DMujocoRobot()
        self.assertEqual(robot.model.nq, 29)
        self.assertEqual(robot.model.nv, 29)
        self.assertEqual(robot.model.nu, 29)
        self.assertEqual(len(robot.read_state().joint_positions), 14)

    def test_ready_pose_really_places_forearms_forward(self) -> None:
        robot = G1DMujocoRobot()
        ready = robot.read_state()
        robot.reset("initial")
        initial = robot.read_state()
        for side in ("left", "right"):
            ready_position = ready.ee_poses[f"{side}_end_effector"].position
            initial_position = initial.ee_poses[f"{side}_end_effector"].position
            self.assertGreater(ready_position[0], initial_position[0] + 0.08)
            self.assertGreater(ready_position[2], initial_position[2] + 0.05)

    def test_grip_reference_maps_openxr_axes_to_robot_axes(self) -> None:
        robot = G1DMujocoRobot()
        state = robot.read_state()
        retargeter = DualArmRetargeter()
        baseline = retargeter.retarget(frame(1, left_grip=1.0), state)
        self.assertIsNotNone(baseline)
        reference = np.asarray(state.ee_poses["left_end_effector"].position)

        moved = retargeter.retarget(
            frame(2, left_grip=1.0, left_position=(0.03, 1.24, -0.45)),
            state,
        )
        delta = np.asarray(moved.poses["left"].position) - reference
        np.testing.assert_allclose(delta, (0.05, -0.03, 0.04), atol=1e-9)

    def test_regrip_recaptures_without_pose_jump(self) -> None:
        robot = G1DMujocoRobot()
        retargeter = DualArmRetargeter()
        state = robot.read_state()
        self.assertIsNotNone(retargeter.retarget(frame(1, right_grip=1.0), state))
        self.assertIsNone(retargeter.retarget(frame(2), state))
        recaptured = retargeter.retarget(
            frame(3, right_grip=1.0, right_position=(0.4, 1.0, -0.2)), state
        )
        np.testing.assert_allclose(
            recaptured.poses["right"].position,
            state.ee_poses["right_end_effector"].position,
            atol=1e-12,
        )

    def test_head_yaw_normalizes_controller_direction(self) -> None:
        robot = G1DMujocoRobot()
        state = robot.read_state()
        retargeter = DualArmRetargeter()
        half_sqrt = math.sqrt(0.5)
        baseline_frame = frame(
            1,
            left_grip=1.0,
            head_rotation=(0.0, half_sqrt, 0.0, half_sqrt),
        )
        retargeter.retarget(baseline_frame, state)
        moved = retargeter.retarget(
            frame(
                2,
                left_grip=1.0,
                left_position=(-0.05, 1.2, -0.4),
                head_rotation=(0.0, half_sqrt, 0.0, half_sqrt),
            ),
            state,
        )
        reference = np.asarray(state.ee_poses["left_end_effector"].position)
        delta = np.asarray(moved.poses["left"].position) - reference
        np.testing.assert_allclose(delta, (0.05, 0.0, 0.0), atol=1e-9)

    def test_zero_delta_grip_preserves_pd_support_without_gravity_feedforward(self) -> None:
        robot = G1DMujocoRobot(gravity_compensation=False)
        robot.connect()
        robot.advance(1.0)
        before_q = robot.data.qpos.copy()
        before_ctrl = robot.data.ctrl.copy()
        retargeter = DualArmRetargeter()
        target = retargeter.retarget(
            frame(1, left_grip=1.0, right_grip=1.0), robot.read_state()
        )
        robot.write(target)
        np.testing.assert_allclose(robot.data.ctrl, before_ctrl, atol=2e-4)
        for _ in range(100):
            robot.write(target)
            robot.advance(0.01)
        self.assertLess(float(np.max(np.abs(robot.data.qpos - before_q))), 0.01)

    def test_both_arms_follow_forward_controller_motion(self) -> None:
        robot = G1DMujocoRobot(gravity_compensation=True)
        robot.connect()
        robot.advance(0.25)
        retargeter = DualArmRetargeter()
        state = robot.read_state()
        baseline = {
            side: np.asarray(state.ee_poses[f"{side}_end_effector"].position)
            for side in ("left", "right")
        }
        first = retargeter.retarget(frame(1, left_grip=1.0, right_grip=1.0), state)
        robot.write(first)
        moved_frame = frame(
            2,
            left_grip=1.0,
            right_grip=1.0,
            left_position=(0.0, 1.2, -0.45),
            right_position=(0.0, 1.2, -0.45),
        )
        for _ in range(180):
            target = retargeter.retarget(moved_frame, robot.read_state())
            robot.write(target, dt=0.01)
            robot.advance(0.01)
        final = robot.read_state()
        for side in ("left", "right"):
            displacement = (
                np.asarray(final.ee_poses[f"{side}_end_effector"].position) - baseline[side]
            )
            self.assertGreater(displacement[0], 0.035)
            self.assertLess(abs(displacement[1]), 0.012)
            self.assertLess(abs(displacement[2]), 0.012)

    def test_unreachable_target_holds_instead_of_raising(self) -> None:
        robot = G1DMujocoRobot()
        robot.connect()
        robot.advance(0.25)
        retargeter = DualArmRetargeter()
        retargeter.retarget(frame(1, left_grip=1.0), robot.read_state())
        moved = frame(2, left_grip=1.0, left_position=(2.0, 1.2, -0.4))
        target = retargeter.retarget(moved, robot.read_state())
        self.assertIsNotNone(target)
        before_ctrl = robot.data.ctrl.copy()
        self.assertEqual(robot.write(target), ("left",))
        np.testing.assert_allclose(robot.data.ctrl, before_ctrl)

    def test_single_grip_does_not_move_other_arm(self) -> None:
        robot = G1DMujocoRobot(gravity_compensation=True)
        robot.connect()
        robot.advance(0.25)
        retargeter = DualArmRetargeter()
        state = robot.read_state()
        right_before = np.asarray(state.ee_poses["right_end_effector"].position)
        retargeter.retarget(frame(1, left_grip=1.0), state)
        moved_frame = frame(2, left_grip=1.0, left_position=(0.0, 1.25, -0.4))
        for _ in range(250):
            target = retargeter.retarget(moved_frame, robot.read_state())
            robot.write(target, dt=0.01)
            robot.advance(0.01)
        final = robot.read_state()
        left_delta_z = (
            final.ee_poses["left_end_effector"].position[2]
            - state.ee_poses["left_end_effector"].position[2]
        )
        right_delta = np.asarray(final.ee_poses["right_end_effector"].position) - right_before
        self.assertGreater(left_delta_z, 0.035)
        self.assertLess(float(np.linalg.norm(right_delta)), 0.003)


if __name__ == "__main__":
    unittest.main()
