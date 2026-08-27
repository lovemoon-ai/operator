"""UDP transport adapter for an externally hosted dual Revo2 runtime."""

from __future__ import annotations

from copy import deepcopy
import json
import math
from numbers import Real
import socket
import threading
import time
from typing import Any, Callable, Mapping, Sequence

from ..hosted import make_descriptor
from .revo2 import (
    COMMAND_FLAG_HOLD,
    SIDES,
    command_targets,
    hand_enabled,
    merge_descriptor,
    target_packet_v2,
)


_TELEMETRY_SUFFIXES = ("target", "position", "current", "stall")


def make_revo2_descriptor() -> dict[str, Any]:
    """Build a hand-only descriptor for calibration and isolated tuning."""

    descriptor = make_descriptor(
        name="BrainCo Revo2 Dual Hands",
        device_type="revo2_dual_hand",
        buttons=[
            {
                "name": "left_enable",
                "display": "Left Hand Enable",
                "toggle": False,
                "confirm": False,
            },
            {
                "name": "right_enable",
                "display": "Right Hand Enable",
                "toggle": False,
                "confirm": False,
            },
        ],
        command_timeout_ms=1000,
    )
    descriptor["descriptor_version"] = 2
    descriptor["execution"] = {"kind": "outside", "environment": "real"}
    descriptor["input_mapping"] = [
        {
            "source": f"{side}_hand_clutch",
            "target": f"{side}_enable",
            "scale": 1.0,
            "invert": False,
            "offset": 0.0,
            "mode": "momentary",
        }
        for side in SIDES
    ]
    descriptor["capabilities"] = {
        "teleop": True,
        "emergency_stop": True,
        "deadman": True,
        "dual_arm": False,
        "video": False,
    }
    return merge_descriptor(descriptor)


class Revo2UdpHostedAdapter:
    """Bridge Operator commands to BCH2 and ingest JSON feedback datagrams."""

    def __init__(
        self,
        *,
        command_host: str,
        command_port: int = 19091,
        telemetry_host: str = "0.0.0.0",
        telemetry_port: int = 19092,
        command_speed: float = 0.08,
        max_command_speed: float = 1.0,
        command_catchup_seconds: float = 0.10,
        command_speed_gain: float = 1.0,
        telemetry_timeout_seconds: float = 0.5,
        socket_factory: Callable[..., socket.socket] = socket.socket,
    ) -> None:
        if not 0.0 < command_speed <= max_command_speed <= 1.0:
            raise ValueError("command speeds must satisfy 0 < minimum <= maximum <= 1")
        if command_catchup_seconds <= 0.0:
            raise ValueError("command_catchup_seconds must be positive")
        if command_speed_gain <= 0.0:
            raise ValueError("command_speed_gain must be positive")
        if telemetry_timeout_seconds <= 0.0:
            raise ValueError("telemetry_timeout_seconds must be positive")
        self.command_host = command_host
        self.command_address = (command_host, int(command_port))
        self.telemetry_address = (telemetry_host, int(telemetry_port))
        self.command_speed = command_speed
        self.max_command_speed = max_command_speed
        self.command_catchup_seconds = command_catchup_seconds
        self.command_speed_gain = command_speed_gain
        self.telemetry_timeout_ns = int(telemetry_timeout_seconds * 1_000_000_000)
        self._socket_factory = socket_factory
        self._command_socket: socket.socket | None = None
        self._telemetry_socket: socket.socket | None = None
        self._receiver: threading.Thread | None = None
        self._closed = threading.Event()
        self._lock = threading.Lock()
        self._values: dict[str, Any] = {}
        self._value_received_ns: dict[str, int] = {}
        self._timestamp_ns = 0
        self._allowed_telemetry_sources: set[str] = set()
        self._enabled = {side: False for side in SIDES}
        self._motion_started = {side: False for side in SIDES}
        self._sequence = {side: 0 for side in SIDES}
        self._last_targets: dict[str, tuple[float, ...] | None] = {
            side: None for side in SIDES
        }
        self._last_command_ns: dict[str, int | None] = {side: None for side in SIDES}

    def connect(self) -> None:
        if self._command_socket is not None:
            return
        self._closed.clear()
        self._allowed_telemetry_sources = _resolve_ipv4(self.command_host)
        self._command_socket = self._socket_factory(socket.AF_INET, socket.SOCK_DGRAM)
        telemetry_socket = self._socket_factory(socket.AF_INET, socket.SOCK_DGRAM)
        telemetry_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        telemetry_socket.bind(self.telemetry_address)
        telemetry_socket.settimeout(0.2)
        self._telemetry_socket = telemetry_socket
        self._receiver = threading.Thread(
            target=self._receive_telemetry,
            name="revo2-telemetry",
            daemon=True,
        )
        self._receiver.start()

    def disconnect(self) -> None:
        try:
            self.stop("adapter disconnect")
        except OSError:
            pass
        self._closed.set()
        for active_socket in (self._telemetry_socket, self._command_socket):
            if active_socket is not None:
                active_socket.close()
        self._telemetry_socket = None
        self._command_socket = None
        receiver = self._receiver
        self._receiver = None
        if receiver is not None and receiver is not threading.current_thread():
            receiver.join(timeout=1.0)
        with self._lock:
            self._values.clear()
            self._value_received_ns.clear()
            self._timestamp_ns = 0

    def handle_command(self, command: Mapping[str, Any]) -> None:
        for side in SIDES:
            enabled = hand_enabled(command, side)
            if enabled:
                self._send(side, command_targets(command, side))
                self._motion_started[side] = True
            elif self._motion_started[side]:
                attempts = 3 if self._enabled[side] else 1
                for _attempt in range(attempts):
                    self._send_hold(side)
            self._enabled[side] = enabled

    def telemetry(self) -> Mapping[str, Any]:
        now_ns = time.monotonic_ns()
        with self._lock:
            return {
                "values": deepcopy(
                    {
                        key: value
                        for key, value in self._values.items()
                        if self._value_is_fresh_locked(key, now_ns)
                    }
                ),
                "timestamp_ns": self._timestamp_ns or time.time_ns(),
            }

    def stop(self, _reason: str) -> None:
        for side in SIDES:
            if self._motion_started[side]:
                for _attempt in range(3):
                    self._send_hold(side)
            self._enabled[side] = False
            self._motion_started[side] = False
            self._last_targets[side] = None
            self._last_command_ns[side] = None

    def _send_hold(self, side: str) -> None:
        now_ns = time.monotonic_ns()
        position_key = f"revo2_{side}_position"
        with self._lock:
            position = (
                self._values.get(position_key)
                if self._value_is_fresh_locked(position_key, now_ns)
                else None
            )
        if (
            not isinstance(position, Sequence)
            or isinstance(position, (str, bytes))
            or len(position) != 6
        ):
            position = self._last_targets[side] or (0.0,) * 6
        self._send(
            side,
            position,
            speeds=(0.02,) * 6,
            flags=COMMAND_FLAG_HOLD,
        )

    def _send(
        self,
        side: str,
        targets: Sequence[float],
        *,
        speeds: Sequence[float] | None = None,
        flags: int = 0,
    ) -> None:
        command_socket = self._command_socket
        if command_socket is None:
            return
        target_values = tuple(float(value) for value in targets)
        now_ns = time.monotonic_ns()
        command_speeds = (
            tuple(float(value) for value in speeds)
            if speeds is not None
            else self._adaptive_speeds(side, target_values, now_ns)
        )
        self._sequence[side] = (self._sequence[side] + 1) & 0xFFFFFFFF
        packet = target_packet_v2(
            target_values,
            side,
            self._sequence[side],
            speed=command_speeds,
            timestamp_ns=now_ns,
            flags=flags,
        )
        command_socket.sendto(packet, self.command_address)

    def _adaptive_speeds(
        self,
        side: str,
        targets: Sequence[float],
        now_ns: int,
    ) -> tuple[float, ...]:
        previous = self._last_targets[side]
        previous_ns = self._last_command_ns[side]
        elapsed = (
            max(0.001, (now_ns - previous_ns) / 1_000_000_000.0)
            if previous is not None and previous_ns is not None
            else None
        )
        with self._lock:
            position_key = f"revo2_{side}_position"
            actual_value = (
                self._values.get(position_key)
                if self._value_is_fresh_locked(position_key, now_ns)
                else None
            )
        actual = (
            tuple(float(value) for value in actual_value)
            if isinstance(actual_value, Sequence) and len(actual_value) == 6
            else None
        )
        result = []
        for index, target in enumerate(targets):
            gesture_speed = 0.0
            if elapsed is not None and previous is not None:
                gesture_speed = (
                    abs(target - previous[index]) / 1000.0 / elapsed
                ) * self.command_speed_gain
            catchup_speed = 0.0
            if actual is not None:
                catchup_speed = (
                    abs(target - actual[index])
                    / 1000.0
                    / self.command_catchup_seconds
                )
            elif previous is None:
                catchup_speed = self.max_command_speed
            result.append(
                min(
                    self.max_command_speed,
                    max(self.command_speed, gesture_speed, catchup_speed),
                )
            )
        self._last_targets[side] = tuple(float(value) for value in targets)
        self._last_command_ns[side] = now_ns
        return tuple(result)

    def _receive_telemetry(self) -> None:
        while not self._closed.is_set():
            telemetry_socket = self._telemetry_socket
            if telemetry_socket is None:
                return
            try:
                payload, source = telemetry_socket.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                return
            if source[0] not in self._allowed_telemetry_sources:
                continue
            try:
                message = json.loads(payload)
                if not isinstance(message, Mapping):
                    continue
                values = message.get("values", {})
                if not isinstance(values, Mapping):
                    continue
                values = _validated_telemetry_values(values)
                if not values:
                    continue
                timestamp_ns = int(message.get("timestamp_ns", time.time_ns()))
            except (TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError):
                continue
            received_ns = time.monotonic_ns()
            with self._lock:
                self._values.update(dict(values))
                for key in values:
                    self._value_received_ns[key] = received_ns
                self._timestamp_ns = timestamp_ns

    def _value_is_fresh_locked(self, key: str, now_ns: int) -> bool:
        received_ns = self._value_received_ns.get(key)
        return (
            received_ns is not None
            and now_ns - received_ns <= self.telemetry_timeout_ns
        )


def _resolve_ipv4(host: str) -> set[str]:
    try:
        return {
            str(entry[4][0])
            for entry in socket.getaddrinfo(
                host,
                None,
                family=socket.AF_INET,
                type=socket.SOCK_DGRAM,
            )
        }
    except socket.gaierror:
        return {host}


def _validated_telemetry_values(values: Mapping[str, Any]) -> dict[str, list[float]]:
    validated: dict[str, list[float]] = {}
    for side in SIDES:
        for suffix in _TELEMETRY_SUFFIXES:
            key = f"revo2_{side}_{suffix}"
            value = values.get(key)
            if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
                continue
            if len(value) != 6:
                continue
            if not all(
                isinstance(item, Real)
                and not isinstance(item, bool)
                and math.isfinite(float(item))
                for item in value
            ):
                continue
            validated[key] = [float(item) for item in value]
    return validated
