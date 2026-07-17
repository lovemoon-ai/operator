"""Dependency-free canonical values shared by transport and adapters."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, TypeAlias

if TYPE_CHECKING:
    from .protocol import Kind

Vec3: TypeAlias = tuple[float, float, float]
QuatXyzw: TypeAlias = tuple[float, float, float, float]


@dataclass(frozen=True, slots=True)
class Pose:
    """Pose in metres with an ``xyzw`` quaternion."""

    valid: bool
    position: Vec3
    orientation_xyzw: QuatXyzw


@dataclass(frozen=True, slots=True)
class ControllerSample:
    grip: Pose
    aim: Pose
    primary: bool = False
    secondary: bool = False
    thumb_click: bool = False
    menu: bool = False
    thumb_x: float = 0.0
    thumb_y: float = 0.0
    squeeze: float = 0.0
    trigger: float = 0.0


@dataclass(frozen=True, slots=True)
class JointSample:
    pose: Pose
    radius: float = 0.0


@dataclass(frozen=True, slots=True)
class JointSetSample:
    joints: tuple[JointSample, ...]


@dataclass(frozen=True, slots=True)
class ControlSample:
    kill: bool = False
    run_toggle: bool = False
    reset: bool = False
    deadman: bool = True


CanonicalSample: TypeAlias = Pose | ControllerSample | JointSetSample | ControlSample


@dataclass(frozen=True, slots=True)
class TimedSample:
    kind: Kind
    value: CanonicalSample
    raw_sample_time_ns: int
    common_sample_time_ns: int
    available_time_ns: int
    sequence: int
    token: int
    descriptor_version: int

    def age_ns(self, now_ns: int) -> int:
        """Age of the measurement, not merely time since network arrival."""

        return max(0, now_ns - self.common_sample_time_ns)


@dataclass(frozen=True, slots=True)
class ExternalInputBundle:
    """One latest-only snapshot suitable for an IsaacTeleop step."""

    samples: dict[Kind, TimedSample] = field(default_factory=dict)
    graph_time_ns: int = 0

    def get(self, kind: Kind) -> TimedSample | None:
        return self.samples.get(kind)

    @property
    def empty(self) -> bool:
        return not self.samples
