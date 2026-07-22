"""Retargeting contracts and a controller-delta implementation."""

from __future__ import annotations

import math
from typing import Protocol

from .models import Pose, Quaternion, XrFrame
from .robot import EndEffectorTarget, RobotCommand, RobotState


class Retargeter(Protocol):
    def reset(self) -> None: ...

    def retarget(self, frame: XrFrame, robot_state: RobotState) -> RobotCommand | None: ...


def _mul(a: Quaternion, b: Quaternion) -> Quaternion:
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def _inverse(q: Quaternion) -> Quaternion:
    norm = sum(value * value for value in q)
    if norm <= 1e-12:
        return (0.0, 0.0, 0.0, 1.0)
    return (-q[0] / norm, -q[1] / norm, -q[2] / norm, q[3] / norm)


def _normalized(q: Quaternion) -> Quaternion:
    length = math.sqrt(sum(value * value for value in q))
    if length <= 1e-12:
        return (0.0, 0.0, 0.0, 1.0)
    return tuple(value / length for value in q)  # type: ignore[return-value]


class PoseDeltaRetargeter:
    """Maps deadman-held controller motion onto a robot EE reference pose."""

    def __init__(
        self,
        *,
        hand: str = "right",
        link: str = "end_effector",
        deadman_input: str = "grip",
        deadman_threshold: float = 0.5,
        translation_scale: float = 1.0,
        gripper_input: str | None = "trigger",
    ) -> None:
        if hand not in {"left", "right"}:
            raise ValueError("hand must be 'left' or 'right'")
        self.hand = hand
        self.link = link
        self.deadman_input = deadman_input
        self.deadman_threshold = float(deadman_threshold)
        self.translation_scale = float(translation_scale)
        self.gripper_input = gripper_input
        self._controller_reference: Pose | None = None
        self._robot_reference: Pose | None = None

    def reset(self) -> None:
        self._controller_reference = None
        self._robot_reference = None

    def retarget(self, frame: XrFrame, robot_state: RobotState) -> EndEffectorTarget | None:
        controller = getattr(frame.controllers, self.hand)
        if controller is None or not controller.pose.valid:
            self.reset()
            return None
        if controller.input.value(self.deadman_input) < self.deadman_threshold:
            self.reset()
            return None
        measured = robot_state.ee_poses.get(self.link)
        if measured is None or not measured.valid:
            return None
        if self._controller_reference is None or self._robot_reference is None:
            self._controller_reference = controller.pose
            self._robot_reference = measured

        source = self._controller_reference
        target_reference = self._robot_reference
        delta = tuple(
            (controller.pose.position[index] - source.position[index]) * self.translation_scale
            for index in range(3)
        )
        position = tuple(target_reference.position[index] + delta[index] for index in range(3))
        rotation_delta = _mul(controller.pose.rotation, _inverse(source.rotation))
        rotation = _normalized(_mul(rotation_delta, target_reference.rotation))
        gripper = (
            controller.input.value(self.gripper_input)
            if self.gripper_input is not None
            else None
        )
        return EndEffectorTarget(
            ee_pose=Pose(
                valid=True,
                sample_timestamp_ns=frame.timestamp_ns,
                position=position,  # type: ignore[arg-type]
                rotation=rotation,
            ),
            link=self.link,
            gripper=gripper,
            timestamp_ns=frame.timestamp_ns,
        )
