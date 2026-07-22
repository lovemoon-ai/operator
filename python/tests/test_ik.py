from __future__ import annotations

import unittest
from types import MappingProxyType
from unittest.mock import patch

from pyoperator.ik import CallableIK, DampedLeastSquaresIK
from pyoperator.models import Pose
from pyoperator.robot import EndEffectorTarget, JointTarget, RobotState

try:
    import numpy  # noqa: F401
except ImportError:
    HAS_NUMPY = False
else:
    HAS_NUMPY = True


def target(*, gripper: float | None = 0.4, timestamp_ns: int = 123) -> EndEffectorTarget:
    return EndEffectorTarget(
        ee_pose=Pose(valid=True, position=(1.0, 0.0, 0.0)),
        gripper=gripper,
        timestamp_ns=timestamp_ns,
    )


def state(*positions: float) -> RobotState:
    return RobotState(
        timestamp_ns=10,
        joint_positions=tuple(positions),
        ee_poses=MappingProxyType({}),
    )


class CallableIKTests(unittest.TestCase):
    def test_sequence_result_becomes_joint_target_with_metadata(self) -> None:
        solver = CallableIK(lambda requested, current: [requested.ee_pose.position[0], current.timestamp_ns])
        result = solver.solve(target(), state(0.0))
        self.assertEqual(result.positions, (1.0, 10.0))
        self.assertEqual(result.gripper, 0.4)
        self.assertEqual(result.timestamp_ns, 123)

    def test_existing_joint_target_is_returned_unchanged(self) -> None:
        expected = JointTarget((0.1, 0.2), gripper=0.3, timestamp_ns=9)
        result = CallableIK(lambda _target, _state: expected).solve(target(), state())
        self.assertIs(result, expected)


@unittest.skipUnless(HAS_NUMPY, "requires the pyoperator[test] numpy dependency")
class DampedLeastSquaresIKTests(unittest.TestCase):
    def test_converges_for_identity_jacobian(self) -> None:
        requested = target()
        solver = DampedLeastSquaresIK(
            lambda q, _target: [1.0 - q[0], -0.5 - q[1]],
            lambda _q: [[1.0, 0.0], [0.0, 1.0]],
            damping=1e-9,
            step_size=1.0,
            max_iterations=5,
            tolerance=1e-8,
        )
        result = solver.solve(requested, state(0.0, 0.0))
        self.assertAlmostEqual(result.positions[0], 1.0, places=6)
        self.assertAlmostEqual(result.positions[1], -0.5, places=6)
        self.assertEqual(result.gripper, requested.gripper)
        self.assertEqual(result.timestamp_ns, requested.timestamp_ns)

    def test_clamps_each_iteration_to_joint_limits(self) -> None:
        solver = DampedLeastSquaresIK(
            lambda q, _target: [10.0 - q[0]],
            lambda _q: [[1.0]],
            damping=0.0,
            step_size=1.0,
            max_iterations=2,
            joint_limits=[(-0.2, 0.2)],
        )
        self.assertEqual(solver.solve(target(), state(0.0)).positions, (0.2,))

    def test_rejects_robot_state_without_joints(self) -> None:
        solver = DampedLeastSquaresIK(lambda _q, _target: [0.0], lambda _q: [[1.0]])
        with self.assertRaisesRegex(ValueError, "no joint positions"):
            solver.solve(target(), state())

    def test_missing_numpy_has_actionable_error(self) -> None:
        solver = DampedLeastSquaresIK(lambda _q, _target: [0.0], lambda _q: [[1.0]])
        real_import = __import__

        def without_numpy(name, *args, **kwargs):
            if name == "numpy":
                raise ImportError("numpy hidden for test")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=without_numpy):
            with self.assertRaisesRegex(RuntimeError, r"pyoperator\[ik\]"):
                solver.solve(target(), state(0.0))
