"""Versioned retargeting wire contract between the Operator XR app and a host.

This module is the whole contract: message envelopes, the request/result DTOs
the app sees, and the error vocabulary. It has no dependency on any solver —
what a payload *means* is decided by the profile's ``input_type`` and resolved
in :mod:`pyoperator.integrations.retargeting`.

Message flow on one connection::

    client -> hello{protocol_version, profile_id, input_type, model_hash}
    server -> hello_ack{protocol_version, profile}
    client -> frame{frame_id, timestamp_ns, payload}      (latest-only)
    server -> result{frame_id, profile_id, output_type, q, joint_names, ...}
    client -> reset            server -> reset_ack
    server -> error{code, message, frame_id?}             (at any point)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Mapping, Sequence

PROTOCOL_VERSION = 1

HELLO_TYPE = "hello"
HELLO_ACK_TYPE = "hello_ack"
FRAME_TYPE = "frame"
RESULT_TYPE = "result"
RESET_TYPE = "reset"
RESET_ACK_TYPE = "reset_ack"
ERROR_TYPE = "error"


class ProtocolError(ValueError):
    """A peer message does not satisfy the negotiated wire contract."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def error_message(code: str, message: str, frame_id: int | None = None) -> dict[str, Any]:
    """An error envelope; ``frame_id`` scopes it to one in-flight frame."""
    out: dict[str, Any] = {"type": ERROR_TYPE, "code": code, "message": message}
    if frame_id is not None:
        out["frame_id"] = frame_id
    return out


def require_mapping(value: Any, field_name: str = "message") -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ProtocolError("invalid_message", f"{field_name} must be an object")
    return value


def require_string(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ProtocolError("invalid_message", f"{field_name} must be a non-empty string")
    return value.strip()


def require_int(value: Any, field_name: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ProtocolError(
            "invalid_message", f"{field_name} must be an integer >= {minimum}"
        )
    return value


@dataclass(frozen=True)
class Hello:
    """What a client must agree with the host before any frame is accepted."""

    protocol_version: int
    profile_id: str
    input_type: str
    model_hash: str = ""


@dataclass(frozen=True)
class RetargetingRequest:
    """One frame to retarget. ``payload`` is shaped by the profile input type."""

    frame_id: int
    timestamp_ns: int
    payload: Mapping[str, Any]
    profile_id: str = ""


@dataclass(frozen=True)
class RetargetingResult:
    """One solved frame, in the shape the XR client applies.

    ``positions`` is the robot configuration vector the profile defines (full
    ``qpos`` for MuJoCo humanoid profiles); it is sent as ``q`` on the wire.
    """

    frame_id: int
    timestamp_ns: int
    profile_id: str
    output_type: str
    positions: Sequence[float]
    joint_names: Sequence[str] = ()
    status: str = "converged"
    iterations: int = 0
    solve_time_us: int = 0
    metrics: Mapping[str, Any] = field(default_factory=dict)
    degradation: Mapping[str, Any] = field(default_factory=dict)

    def to_wire(self) -> dict[str, Any]:
        return {
            "type": RESULT_TYPE,
            "frame_id": int(self.frame_id),
            "timestamp_ns": int(self.timestamp_ns),
            "profile_id": self.profile_id,
            "output_type": self.output_type,
            "q": [float(value) for value in self.positions],
            "joint_names": [str(name) for name in self.joint_names],
            "status": self.status,
            "iterations": int(self.iterations),
            "solve_time_us": int(self.solve_time_us),
            "metrics": dict(self.metrics),
            "degradation": dict(self.degradation),
        }


def parse_hello(message: Any) -> Hello:
    raw = require_mapping(message)
    if raw.get("type") != HELLO_TYPE:
        raise ProtocolError("hello_required", "first message must have type 'hello'")
    version = require_int(raw.get("protocol_version"), "protocol_version", 1)
    if version != PROTOCOL_VERSION:
        raise ProtocolError(
            "unsupported_protocol",
            f"protocol_version {version} is unsupported; expected {PROTOCOL_VERSION}",
        )
    return Hello(
        protocol_version=version,
        profile_id=require_string(raw.get("profile_id"), "profile_id"),
        input_type=require_string(raw.get("input_type"), "input_type"),
        model_hash=str(raw.get("model_hash", "")).strip(),
    )


def parse_frame_envelope(message: Any) -> RetargetingRequest:
    raw = require_mapping(message)
    if raw.get("type") != FRAME_TYPE:
        raise ProtocolError("invalid_message", "expected message type 'frame'")
    return RetargetingRequest(
        frame_id=require_int(raw.get("frame_id"), "frame_id"),
        timestamp_ns=require_int(raw.get("timestamp_ns"), "timestamp_ns"),
        payload=require_mapping(raw.get("payload"), "payload"),
    )


def frame_id_of(message: Any) -> int | None:
    """The frame id of a raw message, when it has a usable one."""
    if not isinstance(message, Mapping):
        return None
    value = message.get("frame_id")
    return value if isinstance(value, int) and not isinstance(value, bool) else None
