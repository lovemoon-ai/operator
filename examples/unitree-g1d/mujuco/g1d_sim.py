"""MuJoCo G1 dual-arm plant and controller-relative retargeting.

The plant is Unitree's official 29-DoF G1 model (BSD-3-Clause, see
``assets/g1/LICENSE``) with the floating base removed: the pelvis is fixed to
the world and only the two 7-DoF arm chains are driven, while legs and waist
are held by position actuators.  This sandbox isolates arm IK, gravity
support, and Grip reference behavior before the same logic is exercised on
G1-D hardware.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
import sys
import time
from types import MappingProxyType
from typing import Mapping

import mujoco
import numpy as np

try:
    import mink
    from mink.lie import SE3, SO3
except ImportError:  # pragma: no cover - mink is optional, DLS is the fallback
    mink = None

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
sys.path.insert(0, str(REPO_ROOT / "python"))

from pyoperator import Pose, RobotState  # noqa: E402
from pyoperator.models import XrFrame  # noqa: E402

MODEL_PATH = HERE / "assets" / "g1" / "g1_dual_arm.xml"
SIDES = ("left", "right")
ARM_JOINTS = {
    side: tuple(
        f"{side}_{suffix}_joint"
        for suffix in (
            "shoulder_pitch",
            "shoulder_roll",
            "shoulder_yaw",
            "elbow",
            "wrist_roll",
            "wrist_pitch",
            "wrist_yaw",
        )
    )
    for side in SIDES
}
READY_Q = np.array(
    [0.0, 0.20, 0.0, 0.0, 0.0, 0.0, 0.0,
     0.0, -0.20, 0.0, 0.0, 0.0, 0.0, 0.0],
    dtype=float,
)
INITIAL_Q = np.array(
    [0.0, 0.0, 0.0, math.pi / 2.0, 0.0, 0.0, 0.0,
     0.0, 0.0, 0.0, math.pi / 2.0, 0.0, 0.0, 0.0],
    dtype=float,
)
XR_TO_ROBOT = np.array(
    [[0.0, 0.0, -1.0], [-1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    dtype=float,
)


def _quat_xyzw_to_matrix(quaternion: tuple[float, float, float, float]) -> np.ndarray:
    x, y, z, w = quaternion
    length = math.sqrt(x * x + y * y + z * z + w * w)
    if length <= 1e-12:
        return np.eye(3)
    x, y, z, w = x / length, y / length, z / length, w / length
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ],
        dtype=float,
    )


def _matrix_to_quat_xyzw(rotation: np.ndarray) -> tuple[float, float, float, float]:
    quaternion_wxyz = np.empty(4, dtype=float)
    mujoco.mju_mat2Quat(quaternion_wxyz, np.asarray(rotation, dtype=float).reshape(9))
    w, x, y, z = quaternion_wxyz
    return float(x), float(y), float(z), float(w)


def _rotation_vector(rotation: np.ndarray) -> np.ndarray:
    cosine = float(np.clip((np.trace(rotation) - 1.0) * 0.5, -1.0, 1.0))
    angle = math.acos(cosine)
    skew = np.array(
        [
            rotation[2, 1] - rotation[1, 2],
            rotation[0, 2] - rotation[2, 0],
            rotation[1, 0] - rotation[0, 1],
        ]
    )
    if angle < 1e-7:
        return 0.5 * skew
    sine = math.sin(angle)
    if abs(sine) < 1e-7:
        diagonal = np.maximum(0.0, (np.diag(rotation) + 1.0) * 0.5)
        axis = np.sqrt(diagonal)
        axis *= np.where(skew < 0.0, -1.0, 1.0)
        length = np.linalg.norm(axis)
        return axis * (angle / length) if length > 1e-9 else np.zeros(3)
    return skew * (angle / (2.0 * sine))


def _pose(position: np.ndarray, rotation: np.ndarray, timestamp_ns: int = 0) -> Pose:
    return Pose(
        valid=True,
        sample_timestamp_ns=timestamp_ns,
        position=tuple(float(value) for value in position),
        rotation=_matrix_to_quat_xyzw(rotation),
    )


@dataclass(frozen=True)
class DualArmTarget:
    poses: Mapping[str, Pose]
    triggers: Mapping[str, float]
    timestamp_ns: int = 0


@dataclass
class _GripReference:
    controller: Pose
    robot: Pose
    operator_rotation: np.ndarray


class DualArmRetargeter:
    """Grip-relative, head-yaw-normalized mapping for both controllers."""

    def __init__(self, *, grip_threshold: float = 0.5, translation_scale: float = 1.0) -> None:
        self.grip_threshold = float(grip_threshold)
        self.translation_scale = float(translation_scale)
        self._references: dict[str, _GripReference] = {}

    def reset(self) -> None:
        self._references.clear()

    def release(self, side: str) -> None:
        """Re-anchor one side on the next frame, e.g. after an IK hold."""
        self._references.pop(side, None)

    def _target(self, current: Pose, reference: _GripReference) -> Pose:
        controller_reference = reference.controller
        xr_delta_world = np.asarray(current.position) - np.asarray(controller_reference.position)
        xr_delta_operator = reference.operator_rotation.T @ xr_delta_world
        robot_delta = XR_TO_ROBOT @ xr_delta_operator * self.translation_scale

        xr_now_rotation = _quat_xyzw_to_matrix(current.rotation)
        xr_reference_rotation = _quat_xyzw_to_matrix(controller_reference.rotation)
        xr_rotation_delta_world = xr_now_rotation @ xr_reference_rotation.T
        xr_rotation_delta = (
            reference.operator_rotation.T
            @ xr_rotation_delta_world
            @ reference.operator_rotation
        )
        robot_rotation_delta = XR_TO_ROBOT @ xr_rotation_delta @ XR_TO_ROBOT.T
        robot_reference_rotation = _quat_xyzw_to_matrix(reference.robot.rotation)
        return _pose(
            np.asarray(reference.robot.position) + robot_delta,
            robot_rotation_delta @ robot_reference_rotation,
            current.sample_timestamp_ns,
        )

    @staticmethod
    def _operator_yaw_frame(frame: XrFrame) -> np.ndarray:
        if frame.head is None or not frame.head.valid:
            return np.eye(3)
        rotation = _quat_xyzw_to_matrix(frame.head.rotation)
        forward = rotation @ np.array([0.0, 0.0, -1.0])
        horizontal = math.hypot(float(forward[0]), float(forward[2]))
        if horizontal <= 1e-8:
            return np.eye(3)
        forward = np.array([forward[0] / horizontal, 0.0, forward[2] / horizontal])
        back = -forward
        right = np.array([back[2], 0.0, -back[0]])
        return np.column_stack((right, np.array([0.0, 1.0, 0.0]), back))

    def retarget(self, frame: XrFrame, robot_state: RobotState) -> DualArmTarget | None:
        targets: dict[str, Pose] = {}
        triggers: dict[str, float] = {}
        for side in SIDES:
            controller = getattr(frame.controllers, side)
            active = (
                controller is not None
                and controller.pose.valid
                and controller.input.value("grip") >= self.grip_threshold
            )
            if not active:
                self._references.pop(side, None)
                continue
            link = f"{side}_end_effector"
            measured = robot_state.ee_poses.get(link)
            if measured is None or not measured.valid:
                self._references.pop(side, None)
                continue
            if side not in self._references:
                self._references[side] = _GripReference(
                    controller=controller.pose,
                    robot=measured,
                    operator_rotation=self._operator_yaw_frame(frame),
                )
            targets[side] = self._target(controller.pose, self._references[side])
            triggers[side] = float(np.clip(controller.input.value("trigger"), 0.0, 1.0))
        if not targets:
            return None
        return DualArmTarget(
            poses=MappingProxyType(targets),
            triggers=MappingProxyType(triggers),
            timestamp_ns=frame.timestamp_ns,
        )


class G1DMujocoRobot:
    """A fixed-base G1-D dual-arm MuJoCo plant with local DLS IK."""

    def __init__(
        self,
        model_path: Path = MODEL_PATH,
        *,
        gravity_compensation: bool = True,
        max_joint_velocity_rad_s: float = 2.5,
    ) -> None:
        self.model = mujoco.MjModel.from_xml_path(str(model_path))
        self.data = mujoco.MjData(self.model)
        self._scratch = mujoco.MjData(self.model)
        self._bias = mujoco.MjData(self.model)
        self.gravity_compensation = bool(gravity_compensation)
        self.max_joint_velocity_rad_s = float(max_joint_velocity_rad_s)
        self.connected = False
        self._engaged = {side: False for side in SIDES}
        self._support_offset = {side: np.zeros(7) for side in SIDES}
        self._last_hold_log: dict[str, float] = {}
        self.joint_ids: dict[str, np.ndarray] = {}
        self.qpos_indices: dict[str, np.ndarray] = {}
        self.dof_indices: dict[str, np.ndarray] = {}
        self.actuator_ids: dict[str, np.ndarray] = {}
        self.site_ids: dict[str, int] = {}
        for side in SIDES:
            joint_ids = np.array(
                [mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_JOINT, name)
                 for name in ARM_JOINTS[side]],
                dtype=int,
            )
            actuator_ids = np.array(
                [mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_ACTUATOR, name)
                 for name in ARM_JOINTS[side]],
                dtype=int,
            )
            if np.any(joint_ids < 0) or np.any(actuator_ids < 0):
                raise RuntimeError(f"model is missing {side} arm joints or actuators")
            self.joint_ids[side] = joint_ids
            self.qpos_indices[side] = self.model.jnt_qposadr[joint_ids].astype(int)
            self.dof_indices[side] = self.model.jnt_dofadr[joint_ids].astype(int)
            self.actuator_ids[side] = actuator_ids
            site_id = mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_SITE, f"{side}_ee")
            if site_id < 0:
                raise RuntimeError(f"model is missing {side}_ee site")
            self.site_ids[side] = site_id
        self.arm_dofs = np.concatenate(tuple(self.dof_indices.values()))
        self._mink_config = None
        self._mink_tasks = None
        self._mink_limits = None
        if mink is not None:
            self._mink_config = mink.Configuration(self.model)
            self._mink_limits = [mink.ConfigurationLimit(model=self.model)]
            self._mink_tasks = {}
            for side in SIDES:
                arm = set(int(d) for d in self.dof_indices[side])
                freeze = mink.DofFreezingTask(
                    self.model, [d for d in range(self.model.nv) if d not in arm]
                )
                task = mink.FrameTask(
                    f"{side}_ee", "site", position_cost=1.0, orientation_cost=0.02
                )
                self._mink_tasks[side] = (task, freeze)
        self.reset("ready")

    def connect(self) -> None:
        self.connected = True

    def disconnect(self) -> None:
        self.connected = False

    def reset(self, posture: str = "ready") -> None:
        key_id = mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_KEY, posture)
        if key_id < 0:
            raise ValueError(f"unknown posture {posture!r}")
        mujoco.mj_resetDataKeyframe(self.model, self.data, key_id)
        mujoco.mj_forward(self.model, self.data)
        self._engaged = {side: False for side in SIDES}
        self._support_offset = {side: np.zeros(7) for side in SIDES}

    def set_posture(self, posture: str) -> None:
        targets = READY_Q if posture == "ready" else INITIAL_Q if posture == "initial" else None
        if targets is None:
            raise ValueError(f"unknown posture {posture!r}")
        for index, side in enumerate(SIDES):
            self.data.ctrl[self.actuator_ids[side]] = targets[index * 7 : index * 7 + 7]
        self._engaged = {side: False for side in SIDES}

    def _site_pose(self, side: str, data: mujoco.MjData | None = None) -> Pose:
        data = data or self.data
        site_id = self.site_ids[side]
        return _pose(data.site_xpos[site_id], data.site_xmat[site_id].reshape(3, 3), time.time_ns())

    def read_state(self) -> RobotState:
        mujoco.mj_forward(self.model, self.data)
        joints = np.concatenate(
            tuple(self.data.qpos[self.qpos_indices[side]] for side in SIDES)
        )
        return RobotState(
            timestamp_ns=time.time_ns(),
            joint_positions=tuple(float(value) for value in joints),
            ee_poses=MappingProxyType(
                {f"{side}_end_effector": self._site_pose(side) for side in SIDES}
            ),
        )

    def _ik_dls(
        self,
        side: str,
        target_position: np.ndarray,
        target_rotation: np.ndarray,
        *,
        position_only: bool,
    ) -> tuple[np.ndarray, float, float]:
        """Hand-rolled damped least squares, mirrors the C++ robot IK."""
        qpos_indices = self.qpos_indices[side]
        dof_indices = self.dof_indices[side]
        joint_ids = self.joint_ids[side]
        site_id = self.site_ids[side]
        limits = self.model.jnt_range[joint_ids]
        jacobian_position = np.zeros((3, self.model.nv))
        jacobian_rotation = np.zeros((3, self.model.nv))

        self._scratch.qpos[:] = self.data.qpos
        self._scratch.qvel[:] = 0.0
        step_limit = 0.12 if position_only else 0.16
        for _ in range(80):
            mujoco.mj_forward(self.model, self._scratch)
            current_position = self._scratch.site_xpos[site_id]
            current_rotation = self._scratch.site_xmat[site_id].reshape(3, 3)
            position_error = target_position - current_position
            rotation_error = _rotation_vector(target_rotation @ current_rotation.T)
            position_error_norm = float(np.linalg.norm(position_error))
            rotation_error_norm = float(np.linalg.norm(rotation_error))
            if position_error_norm <= 0.002 and (
                position_only or rotation_error_norm <= 0.10
            ):
                break
            mujoco.mj_jacSite(
                self.model,
                self._scratch,
                jacobian_position,
                jacobian_rotation,
                site_id,
            )
            if position_only:
                jacobian = jacobian_position[:, dof_indices]
                error = position_error
            else:
                jacobian = np.vstack(
                    (
                        jacobian_position[:, dof_indices],
                        0.25 * jacobian_rotation[:, dof_indices],
                    )
                )
                error = np.concatenate((position_error, 0.25 * rotation_error))
            normal = jacobian @ jacobian.T + (0.045**2) * np.eye(jacobian.shape[0])
            step = jacobian.T @ np.linalg.solve(normal, error)
            next_q = self._scratch.qpos[qpos_indices] + np.clip(
                step, -step_limit, step_limit
            )
            self._scratch.qpos[qpos_indices] = np.clip(next_q, limits[:, 0], limits[:, 1])

        mujoco.mj_forward(self.model, self._scratch)
        position_error_norm = float(
            np.linalg.norm(target_position - self._scratch.site_xpos[site_id])
        )
        rotation_error_norm = float(
            np.linalg.norm(
                _rotation_vector(
                    target_rotation @ self._scratch.site_xmat[site_id].reshape(3, 3).T
                )
            )
        )
        return (
            self._scratch.qpos[qpos_indices].copy(),
            position_error_norm,
            rotation_error_norm,
        )

    def _ik_mink(
        self,
        side: str,
        target_position: np.ndarray,
        target_rotation: np.ndarray,
        *,
        position_only: bool,
    ) -> tuple[np.ndarray, float, float]:
        """MuJoCo mink QP IK (daqp), joint limits enforced as constraints."""
        task, freeze = self._mink_tasks[side]
        task.orientation_cost = 0.0 if position_only else 0.02
        task.set_target(
            SE3.from_rotation_and_translation(
                SO3.from_matrix(target_rotation), target_position
            )
        )
        self._mink_config.update(self.data.qpos)
        position_error_norm = rotation_error_norm = math.inf
        for _ in range(20):
            error = task.compute_error(self._mink_config)
            position_error_norm = float(np.linalg.norm(error[:3]))
            rotation_error_norm = float(np.linalg.norm(error[3:]))
            if position_error_norm <= 0.002 and (
                position_only or rotation_error_norm <= 0.10
            ):
                break
            velocity = mink.solve_ik(
                self._mink_config,
                [task, freeze],
                0.05,
                solver="daqp",
                damping=1e-3,
                limits=self._mink_limits,
            )
            self._mink_config.integrate_inplace(velocity, 0.05)
        return (
            self._mink_config.q[self.qpos_indices[side]].copy(),
            position_error_norm,
            rotation_error_norm,
        )

    def _ik_solve(
        self,
        side: str,
        target_position: np.ndarray,
        target_rotation: np.ndarray,
        *,
        position_only: bool,
    ) -> tuple[np.ndarray, float, float]:
        if mink is not None:
            return self._ik_mink(
                side, target_position, target_rotation, position_only=position_only
            )
        return self._ik_dls(
            side, target_position, target_rotation, position_only=position_only
        )

    def _solve_arm(self, side: str, target: Pose) -> tuple[np.ndarray, float, float]:
        site_id = self.site_ids[side]
        target_position = np.asarray(target.position, dtype=float)
        target_rotation = _quat_xyzw_to_matrix(target.rotation)
        initial_position = self.data.site_xpos[site_id].copy()

        solved, position_error_norm, rotation_error_norm = self._ik_solve(
            side, target_position, target_rotation, position_only=False
        )
        if position_error_norm <= 0.005 and rotation_error_norm <= 0.10:
            return solved, position_error_norm, rotation_error_norm
        # One frame rarely closes the last centimetre.  Accept a nearby
        # full-pose solution so teleoperation keeps converging over the next
        # frames instead of dropping the command; the joint rate limit in
        # write() keeps each step small.
        if position_error_norm <= 0.015 and rotation_error_norm <= 0.15:
            return solved, position_error_norm, rotation_error_norm

        # Controller orientation can briefly disagree with the local arm
        # branch.  For a small translation, retry position-only instead of
        # turning a valid hand displacement into a large posture flip.
        translation_norm = float(np.linalg.norm(target_position - initial_position))
        if translation_norm <= 0.12:
            solved, position_error_norm, rotation_error_norm = self._ik_solve(
                side, target_position, target_rotation, position_only=True
            )
            if position_error_norm <= 0.005:
                return solved, position_error_norm, rotation_error_norm
            if position_error_norm <= 0.015:
                return solved, position_error_norm, rotation_error_norm

        raise RuntimeError(
            f"{side} IK did not converge: position={position_error_norm:.6f}m "
            f"rotation={rotation_error_norm:.6f}rad"
        )

    def write(self, command: DualArmTarget, *, dt: float = 1.0 / 72.0) -> tuple[str, ...]:
        """Returns the sides whose IK failed and are holding their last target."""
        if not self.connected:
            raise RuntimeError("simulator is not connected")
        active_sides = set(command.poses)
        max_step = self.max_joint_velocity_rad_s * float(np.clip(dt, 0.001, 0.05))
        failed: list[str] = []
        for side in SIDES:
            if side not in active_sides:
                self._engaged[side] = False
                continue
            qpos_indices = self.qpos_indices[side]
            actuator_ids = self.actuator_ids[side]
            measured = self.data.qpos[qpos_indices].copy()
            if not self._engaged[side]:
                self._support_offset[side] = self.data.ctrl[actuator_ids] - measured
                self._support_offset[side] = np.clip(self._support_offset[side], -0.15, 0.15)
                self._engaged[side] = True
            try:
                solved, _, _ = self._solve_arm(side, command.poses[side])
            except RuntimeError as error:
                # Hard IK failure: hold the previous target for this arm
                # instead of killing the whole teleoperation loop.
                now = time.monotonic()
                if now - self._last_hold_log.get(side, 0.0) >= 1.0:
                    print(f"IK hold: {error}")
                    self._last_hold_log[side] = now
                failed.append(side)
                continue
            supported_measured = measured + self._support_offset[side]
            desired = supported_measured + np.clip(solved - measured, -max_step, max_step)
            limits = self.model.jnt_range[self.joint_ids[side]]
            self.data.ctrl[actuator_ids] = np.clip(desired, limits[:, 0], limits[:, 1])
        return tuple(failed)

    def stop(self, reason: str = "stop") -> None:
        del reason
        self._engaged = {side: False for side in SIDES}

    def advance(self, seconds: float) -> None:
        steps = max(1, int(math.ceil(max(0.0, seconds) / self.model.opt.timestep)))
        for _ in range(steps):
            self.data.qfrc_applied[:] = 0.0
            if self.gravity_compensation:
                self._bias.qpos[:] = self.data.qpos
                self._bias.qvel[:] = 0.0
                mujoco.mj_forward(self.model, self._bias)
                self.data.qfrc_applied[self.arm_dofs] = self._bias.qfrc_bias[self.arm_dofs]
            mujoco.mj_step(self.model, self.data)

    def max_arm_speed(self) -> float:
        return float(np.max(np.abs(self.data.qvel[self.arm_dofs])))


__all__ = [
    "ARM_JOINTS",
    "DualArmRetargeter",
    "DualArmTarget",
    "G1DMujocoRobot",
    "INITIAL_Q",
    "MODEL_PATH",
    "READY_Q",
]
