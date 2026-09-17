#!/usr/bin/env python3
"""Run one bounded G1-D arm IK smoke move through the adapter protocol."""

from __future__ import annotations

import argparse
import json
import socket
import struct
import threading
import time
from typing import Any


def send_frame(sock: socket.socket, message: dict[str, Any]) -> None:
    payload = json.dumps(message, separators=(",", ":")).encode()
    sock.sendall(struct.pack("<I", len(payload)) + payload)


def receive_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = sock.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("adapter closed the socket")
        chunks.extend(chunk)
    return bytes(chunks)


def receive_frame(sock: socket.socket) -> dict[str, Any]:
    size = struct.unpack("<I", receive_exact(sock, 4))[0]
    return json.loads(receive_exact(sock, size))


def command(
    side: str | None = None,
    position: tuple[float, float, float] = (0.0, 0.0, 0.0),
    reset: bool = False,
) -> dict[str, Any]:
    buttons: dict[str, bool] = {}
    poses: dict[str, Any] = {}
    if side:
        buttons[f"{side}_enable"] = True
        poses[f"{side}_end_effector"] = {
            "position": list(position),
            "rotation": [0.0, 0.0, 0.0, 1.0],
        }
    if reset:
        buttons["reset"] = True
    return {
        "type": "Command",
        "axes": {},
        "buttons": buttons,
        "poses": poses,
        "timestamp_ns": time.time_ns(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default="/tmp/operator-g1d.sock")
    parser.add_argument("--side", choices=("left", "right"), default="left")
    parser.add_argument("--axis", choices=("forward", "left", "up"), default="up")
    parser.add_argument("--displacement-m", type=float, default=0.01)
    parser.add_argument("--duration-s", type=float, default=2.0)
    parser.add_argument("--rate-hz", type=float, default=72.0)
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument(
        "--hold-only",
        action="store_true",
        help="engage Grip with zero pose delta and fail if the arm drops",
    )
    args = parser.parse_args()
    if args.hold_only:
        args.displacement_m = 0.0
    elif not 0.0 < args.displacement_m <= 0.02:
        parser.error("displacement must be in (0, 0.02] metres")
    if not 0.5 <= args.duration_s <= 5.0:
        parser.error("duration must be in [0.5, 5.0] seconds")

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2.0)
    sock.connect(args.socket)
    send_frame(sock, {"type": "Hello"})
    descriptor = receive_frame(sock)
    blueprint = receive_frame(sock)
    if descriptor.get("type") != "Descriptor" or blueprint.get("type") != "Blueprint":
        raise RuntimeError("adapter handshake did not return Descriptor + Blueprint")

    lock = threading.Lock()
    telemetry: list[dict[str, Any]] = []
    reader_error: list[BaseException] = []
    reading = True

    def read_loop() -> None:
        nonlocal reading
        sock.settimeout(0.5)
        while reading:
            try:
                frame = receive_frame(sock)
            except socket.timeout:
                continue
            except BaseException as error:  # preserve cleanup on any reader failure
                if reading:
                    reader_error.append(error)
                return
            if frame.get("type") == "Telemetry":
                with lock:
                    telemetry.append(frame.get("values", {}))

    reader = threading.Thread(target=read_loop, daemon=True)
    reader.start()

    def latest_telemetry(timeout_s: float = 2.0) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            with lock:
                if telemetry:
                    return telemetry[-1]
            time.sleep(0.02)
        raise TimeoutError("no telemetry received")

    try:
        initial = latest_telemetry()
        positions = initial.get("joint_positions_rad", [])
        velocities = initial.get("joint_velocities_rad_s", [])
        if not initial.get("connected") or not initial.get("lowstate_fresh"):
            raise RuntimeError("lowstate is not connected and fresh")
        if int(initial.get("motor_fault_count", -1)) != 0:
            raise RuntimeError(f"upper-body motor faults: {initial.get('motor_fault_count')}")
        if len(positions) != 29 or len(velocities) != 29:
            raise RuntimeError("expected 29 joint positions and velocities")
        max_arm_velocity = max(abs(float(velocities[index])) for index in range(15, 29))
        if max_arm_velocity > 0.10:
            raise RuntimeError(
                f"arm is not stationary before the smoke move: "
                f"max_velocity={max_arm_velocity}, left_q={positions[15:22]}, "
                f"right_q={positions[22:29]}"
            )
        before = [float(value) for value in positions]
        if args.preflight_only:
            print(json.dumps({
                "ok": True,
                "connected": initial.get("connected"),
                "lowstate_age_ms": initial.get("lowstate_age_ms"),
                "motor_fault_count": initial.get("motor_fault_count"),
                "mode_machine": initial.get("mode_machine"),
                "max_abs_arm_velocity_rad_s": max(
                    abs(float(velocities[index])) for index in range(15, 29)
                ),
                "left_arm_positions_rad": before[15:22],
                "right_arm_positions_rad": before[22:29],
            }, ensure_ascii=False))
            return 0

        send_frame(sock, command(reset=True))
        time.sleep(0.15)
        period = 1.0 / args.rate_hz
        axis_vector = {
            "forward": (0.0, 0.0, -1.0),
            "left": (-1.0, 0.0, 0.0),
            "up": (0.0, 1.0, 0.0),
        }[args.axis]
        offset = 15 if args.side == "left" else 22
        peak_joint_delta = 0.0

        def sample_peak_delta() -> None:
            nonlocal peak_joint_delta
            sample_positions = latest_telemetry().get("joint_positions_rad", [])
            if len(sample_positions) != 29:
                return
            peak_joint_delta = max(
                peak_joint_delta,
                *(abs(float(sample_positions[index]) - before[index])
                  for index in range(offset, offset + 7)),
            )

        start = time.monotonic()
        while time.monotonic() - start < args.duration_s:
            phase = min(1.0, (time.monotonic() - start) / args.duration_s)
            position = tuple(value * args.displacement_m * phase for value in axis_vector)
            send_frame(sock, command(args.side, position))
            time.sleep(period)
            sample_peak_delta()
        for _ in range(max(1, int(args.rate_hz * 0.4))):
            position = tuple(value * args.displacement_m for value in axis_vector)
            send_frame(sock, command(args.side, position))
            time.sleep(period)
            sample_peak_delta()
        for _ in range(8):
            send_frame(sock, command())
            time.sleep(period)
        time.sleep(0.8)

        final = latest_telemetry()
        after = [float(value) for value in final.get("joint_positions_rad", [])]
        final_velocity = [float(value) for value in final.get("joint_velocities_rad_s", [])]
        deltas = [after[index] - before[index] for index in range(offset, offset + 7)]
        max_velocity = max(abs(final_velocity[index]) for index in range(offset, offset + 7))
        if args.hold_only and peak_joint_delta > 0.03:
            raise RuntimeError(
                f"arm moved while Grip pose was stationary; peak_joint_delta={peak_joint_delta}, "
                f"final_joint_delta={deltas}"
            )
        if not args.hold_only and max(abs(value) for value in deltas) < 0.002:
            raise RuntimeError(f"no measurable arm response; joint delta={deltas}")
        if max_velocity > 0.10:
            raise RuntimeError(f"arm did not settle; max velocity={max_velocity}")
        if reader_error:
            raise reader_error[0]
        print(json.dumps({
            "ok": True,
            "side": args.side,
            "hold_only": args.hold_only,
            "axis": args.axis,
            "cartesian_displacement_m": args.displacement_m,
            "peak_abs_joint_delta_rad": peak_joint_delta,
            "joint_delta_rad": deltas,
            "final_max_abs_velocity_rad_s": max_velocity,
            "control_mode": final.get("control_mode"),
            "stop_reason": final.get("stop_reason"),
        }, ensure_ascii=False))
        return 0
    finally:
        try:
            send_frame(sock, command())
            send_frame(sock, {"type": "Stop", "reason": "arm_ik_smoke_complete"})
        except OSError:
            pass
        reading = False
        reader.join(timeout=1.0)
        sock.close()


if __name__ == "__main__":
    raise SystemExit(main())
