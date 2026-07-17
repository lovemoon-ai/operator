"""Operator IsaacTeleop canonical UDP protocol.

The header is byte-for-byte compatible with Operator's existing pose UDP
header.  CRC-16/CCITT-FALSE covers the payload only, matching xr-bridge.
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from enum import Enum

from .model import (
    CanonicalSample,
    ControllerSample,
    ControlSample,
    JointSample,
    JointSetSample,
    Pose,
)

HEADER = struct.Struct("<QQIHHHBB4s")
HEADER_SIZE = HEADER.size
DESCRIPTOR_VERSION = 1
MAX_PAYLOAD_SIZE = 0xFFFF
POSE = struct.Struct("<B7f")
CONTROLLER_INPUT = struct.Struct("<BBBBffff")
JOINT_COUNT = struct.Struct("<H")
RADIUS = struct.Struct("<f")
CONTROL = struct.Struct("<BBBB")


class Kind(bytes, Enum):
    HEAD = b"HEAD"
    LEFT_CONTROLLER = b"LCTL"
    RIGHT_CONTROLLER = b"RCTL"
    LEFT_HAND = b"LHND"
    RIGHT_HAND = b"RHND"
    BODY = b"BODY"
    CONTROL = b"CTRL"
    ANCHOR = b"ANCH"


POSE_KINDS = frozenset({Kind.HEAD, Kind.ANCHOR})
CONTROLLER_KINDS = frozenset({Kind.LEFT_CONTROLLER, Kind.RIGHT_CONTROLLER})
JOINT_KINDS = frozenset({Kind.LEFT_HAND, Kind.RIGHT_HAND, Kind.BODY})
EXPECTED_JOINT_COUNTS = {
    Kind.LEFT_HAND: 26,
    Kind.RIGHT_HAND: 26,
    Kind.BODY: 24,
}


class ProtocolError(ValueError):
    """Malformed or semantically invalid canonical datagram."""


@dataclass(frozen=True, slots=True)
class WirePacket:
    timestamp_ns: int
    sequence: int
    token: int
    descriptor_version: int
    flags: int
    reserved: int
    kind: Kind
    payload: bytes


def crc16_ccitt_false(data: bytes | bytearray | memoryview) -> int:
    """CRC-16/CCITT-FALSE (poly 0x1021, init 0xffff, xorout 0)."""

    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode_datagram(packet: WirePacket) -> bytes:
    payload = bytes(packet.payload)
    if len(payload) > MAX_PAYLOAD_SIZE:
        raise ProtocolError(f"payload is {len(payload)} bytes; maximum is {MAX_PAYLOAD_SIZE}")
    limits = (
        ("timestamp_ns", packet.timestamp_ns, 0xFFFFFFFFFFFFFFFF),
        ("sequence", packet.sequence, 0xFFFFFFFFFFFFFFFF),
        ("token", packet.token, 0xFFFFFFFF),
        ("descriptor_version", packet.descriptor_version, 0xFFFF),
        ("flags", packet.flags, 0xFF),
        ("reserved", packet.reserved, 0xFF),
    )
    for name, value, maximum in limits:
        if not isinstance(value, int) or not 0 <= value <= maximum:
            raise ProtocolError(f"{name} must be an integer in [0, {maximum}]")
    if not isinstance(packet.kind, Kind):
        raise ProtocolError("kind must be a canonical Kind")
    try:
        header = HEADER.pack(
            packet.timestamp_ns,
            packet.sequence,
            packet.token,
            packet.descriptor_version,
            len(payload),
            crc16_ccitt_false(payload),
            packet.flags,
            packet.reserved,
            packet.kind.value,
        )
    except struct.error as exc:  # Defensive: keep wire errors on one public exception type.
        raise ProtocolError(f"invalid packet header: {exc}") from exc
    return header + payload


def decode_datagram(data: bytes | bytearray | memoryview) -> WirePacket:
    view = memoryview(data)
    if len(view) < HEADER_SIZE:
        raise ProtocolError(f"datagram too short: got {len(view)}, need at least {HEADER_SIZE}")
    timestamp, sequence, token, version, payload_len, expected_crc, flags, reserved, raw_kind = (
        HEADER.unpack_from(view)
    )
    total = HEADER_SIZE + payload_len
    if len(view) != total:
        raise ProtocolError(f"datagram length mismatch: got {len(view)}, header declares {total}")
    try:
        kind = Kind(raw_kind)
    except ValueError as exc:
        raise ProtocolError(f"unknown packet kind {raw_kind!r}") from exc
    payload = bytes(view[HEADER_SIZE:])
    actual_crc = crc16_ccitt_false(payload)
    if actual_crc != expected_crc:
        raise ProtocolError(
            f"payload CRC mismatch: header=0x{expected_crc:04x}, computed=0x{actual_crc:04x}"
        )
    return WirePacket(timestamp, sequence, token, version, flags, reserved, kind, payload)


def _encode_pose(pose: Pose) -> bytes:
    _validate_finite((*pose.position, *pose.orientation_xyzw), "pose")
    return POSE.pack(
        int(pose.valid),
        *pose.position,
        *pose.orientation_xyzw,
    )


def _decode_pose(payload: memoryview, offset: int = 0) -> tuple[Pose, int]:
    if len(payload) - offset < POSE.size:
        raise ProtocolError("truncated pose payload")
    valid, x, y, z, qx, qy, qz, qw = POSE.unpack_from(payload, offset)
    if valid not in (0, 1):
        raise ProtocolError(f"pose valid flag must be 0 or 1, got {valid}")
    _validate_finite((x, y, z, qx, qy, qz, qw), "pose")
    return Pose(bool(valid), (x, y, z), (qx, qy, qz, qw)), offset + POSE.size


def _validate_finite(values, field: str) -> None:
    if not all(math.isfinite(value) for value in values):
        raise ProtocolError(f"{field} contains a non-finite float")


def encode_payload(kind: Kind, value: CanonicalSample) -> bytes:
    if kind in POSE_KINDS:
        if not isinstance(value, Pose):
            raise TypeError(f"{kind.name} requires Pose")
        return _encode_pose(value)
    if kind in CONTROLLER_KINDS:
        if not isinstance(value, ControllerSample):
            raise TypeError(f"{kind.name} requires ControllerSample")
        _validate_finite(
            (value.thumb_x, value.thumb_y, value.squeeze, value.trigger),
            "controller input",
        )
        return b"".join(
            (
                _encode_pose(value.grip),
                _encode_pose(value.aim),
                CONTROLLER_INPUT.pack(
                    int(value.primary),
                    int(value.secondary),
                    int(value.thumb_click),
                    int(value.menu),
                    value.thumb_x,
                    value.thumb_y,
                    value.squeeze,
                    value.trigger,
                ),
            )
        )
    if kind in JOINT_KINDS:
        if not isinstance(value, JointSetSample):
            raise TypeError(f"{kind.name} requires JointSetSample")
        expected_count = EXPECTED_JOINT_COUNTS[kind]
        if len(value.joints) != expected_count:
            raise ProtocolError(
                f"{kind.name} requires exactly {expected_count} joints, got {len(value.joints)}"
            )
        parts = [JOINT_COUNT.pack(len(value.joints))]
        for joint in value.joints:
            if not math.isfinite(joint.radius) or joint.radius < 0.0:
                raise ProtocolError("joint radius must be finite and non-negative")
            parts.extend((_encode_pose(joint.pose), RADIUS.pack(joint.radius)))
        return b"".join(parts)
    if kind is Kind.CONTROL:
        if not isinstance(value, ControlSample):
            raise TypeError("CONTROL requires ControlSample")
        return CONTROL.pack(
            int(value.kill), int(value.run_toggle), int(value.reset), int(value.deadman)
        )
    raise ProtocolError(f"unsupported kind {kind!r}")


def decode_payload(kind: Kind, payload: bytes | bytearray | memoryview) -> CanonicalSample:
    view = memoryview(payload)
    if kind in POSE_KINDS:
        if len(view) != POSE.size:
            raise ProtocolError(f"{kind.name} payload must be {POSE.size} bytes")
        return _decode_pose(view)[0]
    if kind in CONTROLLER_KINDS:
        expected = 2 * POSE.size + CONTROLLER_INPUT.size
        if len(view) != expected:
            raise ProtocolError(f"{kind.name} payload must be {expected} bytes")
        grip, offset = _decode_pose(view)
        aim, offset = _decode_pose(view, offset)
        primary, secondary, thumb_click, menu, tx, ty, squeeze, trigger = (
            CONTROLLER_INPUT.unpack_from(view, offset)
        )
        if any(value not in (0, 1) for value in (primary, secondary, thumb_click, menu)):
            raise ProtocolError("controller button fields must be 0 or 1")
        _validate_finite((tx, ty, squeeze, trigger), "controller input")
        return ControllerSample(
            grip,
            aim,
            bool(primary),
            bool(secondary),
            bool(thumb_click),
            bool(menu),
            tx,
            ty,
            squeeze,
            trigger,
        )
    if kind in JOINT_KINDS:
        if len(view) < JOINT_COUNT.size:
            raise ProtocolError("truncated joint count")
        (count,) = JOINT_COUNT.unpack_from(view)
        expected_count = EXPECTED_JOINT_COUNTS[kind]
        if count != expected_count:
            raise ProtocolError(
                f"{kind.name} requires exactly {expected_count} joints, got {count}"
            )
        expected = JOINT_COUNT.size + count * (POSE.size + RADIUS.size)
        if len(view) != expected:
            raise ProtocolError(
                f"joint payload length mismatch: got {len(view)}, expected {expected}"
            )
        offset = JOINT_COUNT.size
        joints: list[JointSample] = []
        for _ in range(count):
            pose, offset = _decode_pose(view, offset)
            (radius,) = RADIUS.unpack_from(view, offset)
            offset += RADIUS.size
            if not math.isfinite(radius) or radius < 0.0:
                raise ProtocolError("joint radius must be finite and non-negative")
            joints.append(JointSample(pose, radius))
        return JointSetSample(tuple(joints))
    if kind is Kind.CONTROL:
        if len(view) != CONTROL.size:
            raise ProtocolError(f"CONTROL payload must be {CONTROL.size} bytes")
        fields = CONTROL.unpack(view)
        if any(value not in (0, 1) for value in fields):
            raise ProtocolError("control fields must be 0 or 1")
        return ControlSample(*(bool(value) for value in fields))
    raise ProtocolError(f"unsupported kind {kind!r}")
