"""IK extension point plus a generic damped-least-squares solver."""

from __future__ import annotations

from typing import Callable, Protocol, Sequence

from .robot import EndEffectorTarget, JointTarget, RobotState


class IKSolver(Protocol):
    def solve(self, target: EndEffectorTarget, state: RobotState) -> JointTarget: ...


class CallableIK:
    def __init__(
        self,
        solve: Callable[[EndEffectorTarget, RobotState], Sequence[float] | JointTarget],
    ) -> None:
        self._solve = solve

    def solve(self, target: EndEffectorTarget, state: RobotState) -> JointTarget:
        result = self._solve(target, state)
        if isinstance(result, JointTarget):
            return result
        return JointTarget.from_sequence(
            result, gripper=target.gripper, timestamp_ns=target.timestamp_ns
        )


class DampedLeastSquaresIK:
    """Generic iterative IK using user-provided pose-error and Jacobian calls.

    The callbacks keep this solver independent of URDF/runtime choice. They can
    wrap Pinocchio, MuJoCo, PyBullet, a vendor SDK, or an analytic model.
    """

    def __init__(
        self,
        error: Callable[[Sequence[float], EndEffectorTarget], Sequence[float]],
        jacobian: Callable[[Sequence[float]], Sequence[Sequence[float]]],
        *,
        damping: float = 1e-3,
        step_size: float = 0.5,
        max_iterations: int = 50,
        tolerance: float = 1e-4,
        joint_limits: Sequence[tuple[float, float]] | None = None,
    ) -> None:
        self.error = error
        self.jacobian = jacobian
        self.damping = float(damping)
        self.step_size = float(step_size)
        self.max_iterations = int(max_iterations)
        self.tolerance = float(tolerance)
        self.joint_limits = tuple(joint_limits) if joint_limits is not None else None

    def solve(self, target: EndEffectorTarget, state: RobotState) -> JointTarget:
        try:
            import numpy as np
        except ImportError as error:
            raise RuntimeError("DampedLeastSquaresIK requires `pip install pyoperator[ik]`") from error
        q = np.asarray(state.joint_positions, dtype=float).copy()
        if q.size == 0:
            raise ValueError("robot state has no joint positions")
        for _ in range(self.max_iterations):
            residual = np.asarray(self.error(q, target), dtype=float)
            if float(np.linalg.norm(residual)) <= self.tolerance:
                break
            jacobian = np.asarray(self.jacobian(q), dtype=float)
            system = jacobian @ jacobian.T + self.damping * np.eye(jacobian.shape[0])
            delta = jacobian.T @ np.linalg.solve(system, residual)
            q += self.step_size * delta
            if self.joint_limits is not None:
                lower = np.asarray([limit[0] for limit in self.joint_limits])
                upper = np.asarray([limit[1] for limit in self.joint_limits])
                q = np.clip(q, lower, upper)
        return JointTarget.from_sequence(
            q.tolist(), gripper=target.gripper, timestamp_ns=target.timestamp_ns
        )
