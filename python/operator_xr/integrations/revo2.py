"""BrainCo Revo2 gesture targets and Operator telemetry helpers.

The hardware SDK stays optional. This module defines the data contract shared
by an existing robot backend and the Quest client; the backend can use the
official ``bc_stark_sdk`` to execute the returned 0..1000 targets.
"""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from math import acos, atan2, dist, isfinite, sqrt
import struct
import time
from typing import Any, Mapping, Sequence

from ..models import ControllerState, HandState

CHANNELS = (
    "thumb_aux",
    "thumb_flex",
    "index_flex",
    "middle_flex",
    "ring_flex",
    "pinky_flex",
)
LEGACY_V2_CHANNELS = (
    "thumb_flex",
    "thumb_aux",
    "index_flex",
    "middle_flex",
    "ring_flex",
    "pinky_flex",
)
TACTILE_FINGERS = ("thumb", "index", "middle", "ring", "pinky")
TACTILE_FIELDS = ("normal", "tangential", "direction", "proximity", "status")
SIDES = ("left", "right")
COMMAND_PACKET_MAGIC = b"BCH2"
COMMAND_PACKET_VERSION_V2 = 2
COMMAND_PACKET_VERSION = 3
COMMAND_PACKET_FORMAT = "<4sBBHIQ12f"
COMMAND_FLAG_HOLD = 1 << 0

_CHAINS = (
    (2, 3, 4, 5),
    None,
    (6, 7, 8, 9, 10),
    (11, 12, 13, 14, 15),
    (16, 17, 18, 19, 20),
    (21, 22, 23, 24, 25),
)

_REQUIRED_HAND_JOINTS = frozenset(
    (1,) + tuple(index for chain in _CHAINS if chain for index in chain)
)

THUMB_OPPOSITION_MAX = 0.50
THUMB_FLEX_MAX = 0.87
THUMB_FLEX_OPEN_RAD = 0.10
THUMB_FLEX_CLOSED_RAD = 1.75
THUMB_ABDUCT_OPEN_RAD = 0.35
THUMB_ABDUCT_CLOSED_RAD = 1.65
PINCH_OPPOSITION_MAX = 0.30
PINCH_CLOSED_PALM_RATIO = 0.28
PINCH_OPEN_PALM_RATIO = 0.75


def axis_name(side: str, channel: str) -> str:
    _validate_side(side)
    if channel not in CHANNELS:
        raise ValueError(f"unknown Revo2 channel: {channel}")
    return f"revo2_{side}_{channel}"


def gesture_targets(
    hand: HandState | None,
    controller: ControllerState | None = None,
) -> tuple[float, ...]:
    """Return six normalized Revo2 targets from one XR hand snapshot."""

    points = _tracked_points(hand)
    if _REQUIRED_HAND_JOINTS.issubset(points):
        finger_flex = tuple(_chain_curl(points, chain) for chain in _CHAINS[2:])
        return (
            max(
                _thumb_abduction(points) * THUMB_OPPOSITION_MAX,
                _thumb_pinch_opposition(points, sum(finger_flex) / 4.0),
            ),
            _thumb_flexion(points) * THUMB_FLEX_MAX,
            *finger_flex,
        )

    trigger = _controller_value(controller, "trigger")
    grip = max(
        _controller_value(controller, "grip"),
        _controller_value(controller, "grip_click"),
        _controller_value(controller, "grip_force"),
    )
    return (
        trigger * 0.50,
        trigger * THUMB_FLEX_MAX,
        trigger,
        grip,
        grip,
        grip,
    )


def command_targets(command: Mapping[str, Any], side: str) -> tuple[int, ...]:
    """Extract one hand's descriptor axes as SDK 0..1000 values."""

    return _command_targets(command, side, CHANNELS)


def _command_targets(
    command: Mapping[str, Any], side: str, channels: Sequence[str]
) -> tuple[int, ...]:
    axes = command.get("axes") or {}
    if not isinstance(axes, Mapping):
        axes = {}
    return tuple(
        round(1000.0 * _clamp(float(axes.get(axis_name(side, channel), 0.0))))
        for channel in channels
    )


def hand_enabled(command: Mapping[str, Any], side: str) -> bool:
    """Use the side-specific arm deadman, falling back to shared ``enable``."""

    _validate_side(side)
    buttons = command.get("buttons") or {}
    if not isinstance(buttons, Mapping):
        return False
    return bool(buttons.get(f"{side}_enable", buttons.get("enable", False)))


def command_packet_v2(
    command: Mapping[str, Any],
    side: str,
    sequence: int,
    *,
    speed: float | Sequence[float] = 0.5,
    timestamp_ns: int | None = None,
    flags: int = 0,
) -> bytes:
    """Encode the legacy v2 order: thumb flexion, then thumb opposition."""

    return target_packet_v2(
        _command_targets(command, side, LEGACY_V2_CHANNELS),
        side,
        sequence,
        speed=speed,
        timestamp_ns=timestamp_ns,
        flags=flags,
    )


def target_packet_v2(
    targets: Sequence[float],
    side: str,
    sequence: int,
    *,
    speed: float | Sequence[float] = 0.5,
    timestamp_ns: int | None = None,
    flags: int = 0,
) -> bytes:
    """Encode explicit targets in the legacy v2 channel order."""

    return _target_packet(
        targets,
        side,
        sequence,
        version=COMMAND_PACKET_VERSION_V2,
        speed=speed,
        timestamp_ns=timestamp_ns,
        flags=flags,
    )


def command_packet_v3(
    command: Mapping[str, Any],
    side: str,
    sequence: int,
    *,
    speed: float | Sequence[float] = 0.5,
    timestamp_ns: int | None = None,
    flags: int = 0,
) -> bytes:
    """Encode the canonical v3 order: thumb opposition, then flexion."""

    return target_packet_v3(
        command_targets(command, side),
        side,
        sequence,
        speed=speed,
        timestamp_ns=timestamp_ns,
        flags=flags,
    )


def target_packet_v3(
    targets: Sequence[float],
    side: str,
    sequence: int,
    *,
    speed: float | Sequence[float] = 0.5,
    timestamp_ns: int | None = None,
    flags: int = 0,
) -> bytes:
    """Encode explicit targets in the canonical v3 channel order."""

    return _target_packet(
        targets,
        side,
        sequence,
        version=COMMAND_PACKET_VERSION,
        speed=speed,
        timestamp_ns=timestamp_ns,
        flags=flags,
    )


def _target_packet(
    targets: Sequence[float],
    side: str,
    sequence: int,
    *,
    version: int,
    speed: float | Sequence[float],
    timestamp_ns: int | None,
    flags: int,
) -> bytes:
    """Encode one BCH2 packet after its channel order has been selected."""

    _validate_side(side)
    normalized_targets = tuple(_clamp(value / 1000.0) for value in _six(targets, "targets"))
    if isinstance(speed, (int, float)):
        normalized_speeds = (_clamp(float(speed)),) * 6
    else:
        normalized_speeds = tuple(_clamp(value) for value in _six(speed, "speed"))
    return struct.pack(
        COMMAND_PACKET_FORMAT,
        COMMAND_PACKET_MAGIC,
        version,
        0 if side == "left" else 1,
        int(flags) & 0xFFFF,
        int(sequence) & 0xFFFFFFFF,
        time.monotonic_ns() if timestamp_ns is None else int(timestamp_ns),
        *normalized_targets,
        *normalized_speeds,
    )


@dataclass(frozen=True)
class Revo2HandFeedback:
    target: tuple[float, ...]
    position: tuple[float, ...]
    current: tuple[float, ...]
    stall: tuple[float, ...]

    @classmethod
    def from_sequences(
        cls,
        *,
        target: Sequence[float],
        position: Sequence[float],
        current: Sequence[float],
        states: Sequence[Any],
    ) -> "Revo2HandFeedback":
        return cls(
            _six(target, "target"),
            _six(position, "position"),
            _six(current, "current"),
            tuple(1.0 if _is_stall(state) else 0.0 for state in _six_any(states, "states")),
        )

    @classmethod
    def from_motor_states(
        cls,
        *,
        target: Sequence[float],
        motor_states: Sequence[Any],
    ) -> "Revo2HandFeedback":
        states = tuple(motor_states)
        if len(states) != 6:
            raise ValueError("motor_states must contain six values")
        return cls.from_sequences(
            target=tuple(_as_raw_position(value) for value in target),
            position=tuple(float(getattr(state, "q")) * 1000.0 for state in states),
            current=tuple(float(getattr(state, "tau_est")) * 1000.0 for state in states),
            states=tuple(getattr(state, "mode") for state in states),
        )


@dataclass(frozen=True)
class Revo2TactileFeedback:
    """Raw five-finger tactile values from a Revo2 touch-capable hand."""

    normal: tuple[float, ...]
    tangential: tuple[float, ...]
    direction: tuple[float, ...]
    proximity: tuple[float, ...]
    status: tuple[float, ...]

    @classmethod
    def from_items(cls, items: Sequence[Any]) -> "Revo2TactileFeedback":
        fingers = tuple(items)
        if len(fingers) != len(TACTILE_FINGERS):
            raise ValueError("touch items must contain five fingers")

        normal: list[float] = []
        tangential: list[float] = []
        direction: list[float] = []
        proximity: list[float] = []
        status: list[float] = []
        for item in fingers:
            tangential_values = tuple(
                _numeric_attr(item, f"tangential_force{index}")
                for index in range(1, 4)
            )
            peak_index = max(
                range(len(tangential_values)),
                key=lambda index: abs(tangential_values[index]),
            )
            normal.append(
                max(_numeric_attr(item, f"normal_force{index}") for index in range(1, 4))
            )
            tangential.append(tangential_values[peak_index])
            direction.append(
                _numeric_attr(item, f"tangential_direction{peak_index + 1}")
            )
            proximity.append(
                max(
                    _numeric_attr(item, "self_proximity1"),
                    _numeric_attr(item, "self_proximity2"),
                    _numeric_attr(item, "mutual_proximity"),
                )
            )
            status.append(_numeric_attr(item, "status"))
        return cls(
            tuple(normal),
            tuple(tangential),
            tuple(direction),
            tuple(proximity),
            tuple(status),
        )


class CurrentEma:
    """Small current low-pass filter for stable headset colors."""

    def __init__(self, alpha: float = 0.35) -> None:
        if not 0.0 < alpha <= 1.0:
            raise ValueError("alpha must be in (0, 1]")
        self.alpha = alpha
        self._value: tuple[float, ...] | None = None

    def update(self, current: Sequence[float]) -> tuple[float, ...]:
        sample = _six(current, "current")
        if self._value is None:
            self._value = sample
        else:
            self._value = tuple(
                previous + self.alpha * (value - previous)
                for previous, value in zip(self._value, sample)
            )
        return self._value


def telemetry_values(
    *,
    left: Revo2HandFeedback | None = None,
    right: Revo2HandFeedback | None = None,
    left_touch: Revo2TactileFeedback | None = None,
    right_touch: Revo2TactileFeedback | None = None,
) -> dict[str, list[float]]:
    """Build the flat telemetry keys consumed by the Godot feedback overlay."""

    values: dict[str, list[float]] = {}
    for side, feedback in (("left", left), ("right", right)):
        if feedback is None:
            continue
        values[f"revo2_{side}_target"] = list(feedback.target)
        values[f"revo2_{side}_position"] = list(feedback.position)
        values[f"revo2_{side}_current"] = list(feedback.current)
        values[f"revo2_{side}_stall"] = list(feedback.stall)
    for side, tactile in (("left", left_touch), ("right", right_touch)):
        if tactile is None:
            continue
        values[f"revo2_{side}_touch_normal"] = list(tactile.normal)
        values[f"revo2_{side}_touch_tangential"] = list(tactile.tangential)
        values[f"revo2_{side}_touch_direction"] = list(tactile.direction)
        values[f"revo2_{side}_touch_proximity"] = list(tactile.proximity)
        values[f"revo2_{side}_touch_status"] = list(tactile.status)
    return values


def merge_descriptor(descriptor: Mapping[str, Any]) -> dict[str, Any]:
    """Add dual-hand controls and telemetry definitions to a robot descriptor."""

    merged = deepcopy(dict(descriptor))
    control_schema = merged.setdefault("control_schema", {})
    axes = control_schema.setdefault("axes", [])
    input_mapping = merged.setdefault("input_mapping", [])
    telemetry_schema = merged.setdefault("telemetry_schema", {})
    telemetry = telemetry_schema.setdefault("values", [])

    existing_axes = {str(entry.get("name")) for entry in axes if isinstance(entry, Mapping)}
    existing_mappings = {
        (str(entry.get("source")), str(entry.get("target")))
        for entry in input_mapping
        if isinstance(entry, Mapping)
    }
    existing_telemetry = {
        str(entry.get("name")) for entry in telemetry if isinstance(entry, Mapping)
    }

    for side in SIDES:
        for channel in CHANNELS:
            name = axis_name(side, channel)
            source = f"{side}_hand_{channel}"
            if name not in existing_axes:
                axes.append(
                    {
                        "name": name,
                        "display": f"{side.title()} Revo2 {channel.replace('_', ' ').title()}",
                        "range": [0.0, 1.0],
                        "default": 0.0,
                        "dead_zone": 0.0,
                    }
                )
            if (source, name) not in existing_mappings:
                input_mapping.append(
                    {"source": source, "target": name, "scale": 1.0, "offset": 0.0}
                )
        for suffix, display in (
            ("target", "Target Position"),
            ("position", "Actual Position"),
            ("current", "Motor Current"),
            ("stall", "Stall Contact"),
        ):
            name = f"revo2_{side}_{suffix}"
            if name not in existing_telemetry:
                telemetry.append(
                    {
                        "name": name,
                        "display": f"{side.title()} Revo2 {display}",
                        "unit": "normalized",
                        "type": "array",
                        "length": 6,
                    }
                )
        for suffix, display, unit in (
            ("touch_normal", "Tactile Normal", "sensor_raw"),
            ("touch_tangential", "Tactile Tangential", "sensor_raw"),
            ("touch_direction", "Tactile Direction", "sensor_angle_raw"),
            ("touch_proximity", "Tactile Proximity", "sensor_raw"),
            ("touch_status", "Tactile Sensor Status", "enum"),
        ):
            name = f"revo2_{side}_{suffix}"
            if name not in existing_telemetry:
                telemetry.append(
                    {
                        "name": name,
                        "display": f"{side.title()} Revo2 {display}",
                        "unit": unit,
                        "type": "array",
                        "length": 5,
                    }
                )
    return merged


def _numeric_attr(item: Any, name: str) -> float:
    if not hasattr(item, name):
        raise ValueError(f"touch sample is missing {name}")
    value = getattr(item, name)
    if isinstance(value, bool):
        raise ValueError(f"touch sample {name} must be numeric")
    try:
        numeric = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"touch sample {name} must be numeric") from exc
    if not isfinite(numeric):
        raise ValueError(f"touch sample {name} must be finite")
    return numeric


def _tracked_points(hand: HandState | None) -> dict[int, tuple[float, float, float]]:
    if hand is None or not hand.active:
        return {}
    points: dict[int, tuple[float, float, float]] = {}
    for joint in hand.joints:
        if not joint.tracked or not joint.pose.valid:
            continue
        position = tuple(float(value) for value in joint.pose.position)
        if len(position) == 3 and all(isfinite(value) for value in position):
            points[joint.joint] = position
    return points


def _chain_curl(
    points: Mapping[int, tuple[float, float, float]], chain: Sequence[int] | None
) -> float:
    if chain is None:
        return 0.0
    path = sum(dist(points[first], points[second]) for first, second in zip(chain, chain[1:]))
    if path <= 1e-9:
        return 0.0
    reach_ratio = dist(points[chain[0]], points[chain[-1]]) / path
    return _clamp((0.94 - reach_ratio) / 0.52)


def _thumb_flexion(points: Mapping[int, tuple[float, float, float]]) -> float:
    proximal_axis = _subtract(points[4], points[3])
    bend = _segment_angle(_subtract(points[3], points[2]), proximal_axis)
    bend += _segment_angle(proximal_axis, _subtract(points[5], points[4]))
    return _clamp(
        (bend - THUMB_FLEX_OPEN_RAD)
        / (THUMB_FLEX_CLOSED_RAD - THUMB_FLEX_OPEN_RAD)
    )


def _thumb_abduction(points: Mapping[int, tuple[float, float, float]]) -> float:
    thumbward = _normalized(_subtract(points[6], points[21]))
    if thumbward is None:
        return 0.0
    forward = _subtract(points[11], points[1])
    forward = _subtract(forward, _scale(thumbward, _dot(forward, thumbward)))
    forward = _normalized(forward)
    if forward is None:
        return 0.0
    thumb_axis = _subtract(points[3], points[2])
    lateral_component = _dot(thumb_axis, thumbward)
    forward_component = _dot(thumb_axis, forward)
    if abs(lateral_component) + abs(forward_component) <= 1e-9:
        return 0.0
    angle = atan2(forward_component, lateral_component)
    return _clamp(
        (angle - THUMB_ABDUCT_OPEN_RAD)
        / (THUMB_ABDUCT_CLOSED_RAD - THUMB_ABDUCT_OPEN_RAD)
    )


def _thumb_pinch_opposition(
    points: Mapping[int, tuple[float, float, float]], average_finger_flex: float
) -> float:
    palm_width = dist(points[6], points[21])
    if palm_width <= 1e-4:
        return 0.0
    tip_ratio = dist(points[5], points[10]) / palm_width
    pinch_closeness = _clamp(
        (PINCH_OPEN_PALM_RATIO - tip_ratio)
        / (PINCH_OPEN_PALM_RATIO - PINCH_CLOSED_PALM_RATIO)
    )
    open_finger_weight = 1.0 - _clamp(average_finger_flex / 0.50)
    return pinch_closeness * open_finger_weight * PINCH_OPPOSITION_MAX


def _segment_angle(
    first: tuple[float, float, float], second: tuple[float, float, float]
) -> float:
    first_unit = _normalized(first)
    second_unit = _normalized(second)
    if first_unit is None or second_unit is None:
        return 0.0
    return acos(max(-1.0, min(1.0, _dot(first_unit, second_unit))))


def _subtract(
    first: tuple[float, float, float], second: tuple[float, float, float]
) -> tuple[float, float, float]:
    return tuple(a - b for a, b in zip(first, second))


def _scale(
    vector: tuple[float, float, float], scalar: float
) -> tuple[float, float, float]:
    return tuple(component * scalar for component in vector)


def _dot(
    first: tuple[float, float, float], second: tuple[float, float, float]
) -> float:
    return sum(a * b for a, b in zip(first, second))


def _normalized(
    vector: tuple[float, float, float],
) -> tuple[float, float, float] | None:
    length = sqrt(_dot(vector, vector))
    if length <= 1e-9:
        return None
    return tuple(component / length for component in vector)


def _controller_value(controller: ControllerState | None, name: str) -> float:
    if controller is None:
        return 0.0
    return _clamp(controller.input.value(name))


def _is_stall(state: Any) -> bool:
    if isinstance(state, str):
        return state.upper().endswith("STALL")
    name = getattr(state, "name", None)
    if isinstance(name, str):
        return name.upper().endswith("STALL")
    return int(state) == 2 if isinstance(state, (int, float)) else False


def _six(values: Sequence[float], name: str) -> tuple[float, ...]:
    result = tuple(float(value) for value in values)
    if len(result) != 6:
        raise ValueError(f"{name} must contain six values")
    return result


def _six_any(values: Sequence[Any], name: str) -> tuple[Any, ...]:
    result = tuple(values)
    if len(result) != 6:
        raise ValueError(f"{name} must contain six values")
    return result


def _clamp(value: float) -> float:
    if not isfinite(value):
        return 0.0
    return min(1.0, max(0.0, value))


def _as_raw_position(value: float) -> float:
    numeric = float(value)
    return numeric * 1000.0 if -1.0 <= numeric <= 1.0 else numeric


def _validate_side(side: str) -> None:
    if side not in SIDES:
        raise ValueError(f"side must be one of {SIDES}, got {side!r}")
