"""Immutable public data models for atomic XR snapshots."""

from __future__ import annotations

from dataclasses import dataclass, field
import json
from types import MappingProxyType
from typing import Any, Mapping

Vec3 = tuple[float, float, float]
Quaternion = tuple[float, float, float, float]


def _vec3(value: Any) -> Vec3:
    values = value if isinstance(value, (list, tuple)) else (0.0, 0.0, 0.0)
    return (float(values[0]), float(values[1]), float(values[2]))


def _quat(value: Any) -> Quaternion:
    values = value if isinstance(value, (list, tuple)) else (0.0, 0.0, 0.0, 1.0)
    return (float(values[0]), float(values[1]), float(values[2]), float(values[3]))


@dataclass(frozen=True)
class Pose:
    valid: bool = False
    sample_timestamp_ns: int = 0
    position: Vec3 = (0.0, 0.0, 0.0)
    rotation: Quaternion = (0.0, 0.0, 0.0, 1.0)
    linear_velocity: Vec3 | None = None
    angular_velocity: Vec3 | None = None
    confidence: float | None = None


@dataclass(frozen=True)
class ControllerInput:
    sample_timestamp_ns: int = 0
    values: Mapping[str, float] = field(default_factory=lambda: MappingProxyType({}))

    def value(self, name: str, default: float = 0.0) -> float:
        return float(self.values.get(name, default))


@dataclass(frozen=True)
class ControllerState:
    pose: Pose = field(default_factory=Pose)
    input: ControllerInput = field(default_factory=ControllerInput)
    interaction_profile: str = ""


@dataclass(frozen=True)
class ControllerPair:
    left: ControllerState | None = None
    right: ControllerState | None = None


@dataclass(frozen=True)
class Joint:
    joint: int
    flags: int = 0
    tracked: bool = False
    radius_m: float = 0.0
    pose: Pose = field(default_factory=Pose)


@dataclass(frozen=True)
class HandState:
    active: bool = False
    sample_timestamp_ns: int = 0
    joints: tuple[Joint, ...] = ()


@dataclass(frozen=True)
class HandPair:
    left: HandState | None = None
    right: HandState | None = None


@dataclass(frozen=True)
class BodyState:
    active: bool = False
    sample_timestamp_ns: int = 0
    joint_set: str = ""
    body_flags: int = 0
    joints: tuple[Joint, ...] = ()


@dataclass(frozen=True)
class MotionTrackerState:
    id: str
    tracker_index: int = 0
    pose: Pose = field(default_factory=Pose)
    battery_level: float | None = None


@dataclass(frozen=True)
class XrFrame:
    """One atomic headset snapshot; never assembled from separate getters."""

    schema_version: int
    frame_id: int
    timestamp_ns: int
    coordinate_space: str
    head: Pose | None
    controllers: ControllerPair
    hands: HandPair
    body: BodyState | None
    motion_trackers: tuple[MotionTrackerState, ...]


@dataclass(frozen=True)
class BridgeStats:
    running: bool = False
    connected: bool = False
    frames_received: int = 0
    parse_errors: int = 0
    last_frame_id: int = 0
    last_timestamp_ns: int = 0
    last_error: str | None = None


def _pose(data: Mapping[str, Any] | None) -> Pose | None:
    if data is None:
        return None
    linear = data.get("linear_velocity")
    angular = data.get("angular_velocity")
    confidence = data.get("confidence")
    return Pose(
        valid=bool(data.get("valid", False)),
        sample_timestamp_ns=int(data.get("sample_timestamp_ns", 0)),
        position=_vec3(data.get("position")),
        rotation=_quat(data.get("rotation")),
        linear_velocity=_vec3(linear) if linear is not None else None,
        angular_velocity=_vec3(angular) if angular is not None else None,
        confidence=float(confidence) if confidence is not None else None,
    )


def _controller(data: Mapping[str, Any] | None) -> ControllerState | None:
    if not data:
        return None
    input_data = data.get("input") or {}
    values = MappingProxyType(
        {str(key): float(value) for key, value in (input_data.get("values") or {}).items()}
    )
    return ControllerState(
        pose=_pose(data.get("pose") or {}) or Pose(),
        input=ControllerInput(int(input_data.get("sample_timestamp_ns", 0)), values),
        interaction_profile=str(data.get("interaction_profile", "")),
    )


def _joint(data: Mapping[str, Any]) -> Joint:
    return Joint(
        joint=int(data.get("joint", 0)),
        flags=int(data.get("flags", 0)),
        tracked=bool(data.get("tracked", False)),
        radius_m=float(data.get("radius_m", 0.0)),
        pose=_pose(data.get("pose") or {}) or Pose(),
    )


def _hand(data: Mapping[str, Any] | None) -> HandState | None:
    if data is None:
        return None
    return HandState(
        active=bool(data.get("active", False)),
        sample_timestamp_ns=int(data.get("sample_timestamp_ns", 0)),
        joints=tuple(_joint(joint) for joint in data.get("joints", ())),
    )


def frame_from_dict(data: Mapping[str, Any]) -> XrFrame:
    version = int(data.get("schema_version", 0))
    if version != 1:
        raise ValueError(f"unsupported XrStateFrame schema {version}; expected 1")
    controllers = data.get("controllers") or {}
    hands = data.get("hands") or {}
    body_data = data.get("body")
    body = None
    if body_data is not None:
        body = BodyState(
            active=bool(body_data.get("active", False)),
            sample_timestamp_ns=int(body_data.get("sample_timestamp_ns", 0)),
            joint_set=str(body_data.get("joint_set", "")),
            body_flags=int(body_data.get("body_flags", 0)),
            joints=tuple(_joint(joint) for joint in body_data.get("joints", ())),
        )
    trackers = tuple(
        MotionTrackerState(
            id=str(tracker.get("id", "")),
            tracker_index=int(tracker.get("tracker_index", 0)),
            pose=_pose(tracker.get("pose") or {}) or Pose(),
            battery_level=(
                float(tracker["battery_level"])
                if tracker.get("battery_level") is not None
                else None
            ),
        )
        for tracker in data.get("motion_trackers", ())
    )
    return XrFrame(
        schema_version=version,
        frame_id=int(data.get("frame_id", 0)),
        timestamp_ns=int(data.get("timestamp_ns", 0)),
        coordinate_space=str(data.get("coordinate_space", "openxr_stage")),
        head=_pose(data.get("head")),
        controllers=ControllerPair(
            left=_controller(controllers.get("left")),
            right=_controller(controllers.get("right")),
        ),
        hands=HandPair(left=_hand(hands.get("left")), right=_hand(hands.get("right"))),
        body=body,
        motion_trackers=trackers,
    )


def frame_from_json(payload: str | bytes) -> XrFrame:
    return frame_from_dict(json.loads(payload))


def frame_to_dict(frame: XrFrame) -> dict[str, Any]:
    def pose(value: Pose | None) -> dict[str, Any] | None:
        if value is None:
            return None
        result: dict[str, Any] = {
            "valid": value.valid,
            "sample_timestamp_ns": value.sample_timestamp_ns,
            "position": list(value.position),
            "rotation": list(value.rotation),
        }
        if value.linear_velocity is not None:
            result["linear_velocity"] = list(value.linear_velocity)
        if value.angular_velocity is not None:
            result["angular_velocity"] = list(value.angular_velocity)
        if value.confidence is not None:
            result["confidence"] = value.confidence
        return result

    def controller(value: ControllerState | None) -> dict[str, Any] | None:
        if value is None:
            return None
        return {
            "pose": pose(value.pose),
            "input": {
                "sample_timestamp_ns": value.input.sample_timestamp_ns,
                "values": dict(value.input.values),
            },
            "interaction_profile": value.interaction_profile,
        }

    def joint(value: Joint) -> dict[str, Any]:
        return {
            "joint": value.joint,
            "flags": value.flags,
            "tracked": value.tracked,
            "radius_m": value.radius_m,
            "pose": pose(value.pose),
        }

    def hand(value: HandState | None) -> dict[str, Any] | None:
        if value is None:
            return None
        return {
            "active": value.active,
            "sample_timestamp_ns": value.sample_timestamp_ns,
            "joints": [joint(item) for item in value.joints],
        }

    body = None
    if frame.body is not None:
        body = {
            "active": frame.body.active,
            "sample_timestamp_ns": frame.body.sample_timestamp_ns,
            "joint_set": frame.body.joint_set,
            "body_flags": frame.body.body_flags,
            "joints": [joint(item) for item in frame.body.joints],
        }
    return {
        "schema_version": frame.schema_version,
        "frame_id": frame.frame_id,
        "timestamp_ns": frame.timestamp_ns,
        "coordinate_space": frame.coordinate_space,
        "head": pose(frame.head),
        "controllers": {
            "left": controller(frame.controllers.left),
            "right": controller(frame.controllers.right),
        },
        "hands": {"left": hand(frame.hands.left), "right": hand(frame.hands.right)},
        "body": body,
        "motion_trackers": [
            {
                "id": tracker.id,
                "tracker_index": tracker.tracker_index,
                "pose": pose(tracker.pose),
                "battery_level": tracker.battery_level,
            }
            for tracker in frame.motion_trackers
        ],
    }


def frame_to_json(frame: XrFrame) -> str:
    return json.dumps(frame_to_dict(frame), separators=(",", ":"))
