"""Small, implementation-neutral contracts for user-owned robots."""

from __future__ import annotations

from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Mapping, Protocol, Sequence, Union, runtime_checkable

from .models import Pose


@dataclass(frozen=True)
class RobotState:
    timestamp_ns: int
    joint_positions: tuple[float, ...] = ()
    ee_poses: Mapping[str, Pose] = field(default_factory=lambda: MappingProxyType({}))
    values: Mapping[str, float] = field(default_factory=lambda: MappingProxyType({}))


@dataclass(frozen=True)
class EndEffectorTarget:
    """A retargeted robot target, distinct from a raw controller pose."""

    ee_pose: Pose
    link: str = "end_effector"
    gripper: float | None = None
    timestamp_ns: int = 0


@dataclass(frozen=True)
class JointTarget:
    positions: tuple[float, ...]
    gripper: float | None = None
    timestamp_ns: int = 0

    @classmethod
    def from_sequence(
        cls, positions: Sequence[float], *, gripper: float | None = None, timestamp_ns: int = 0
    ) -> "JointTarget":
        return cls(tuple(float(value) for value in positions), gripper, timestamp_ns)


RobotCommand = Union[EndEffectorTarget, JointTarget]


@runtime_checkable
class Robot(Protocol):
    """Implement this protocol around any Python robot SDK."""

    def connect(self) -> None: ...

    def disconnect(self) -> None: ...

    def read_state(self) -> RobotState: ...

    def write(self, command: RobotCommand) -> None: ...

    def stop(self, reason: str = "pyoperator stop") -> None: ...
