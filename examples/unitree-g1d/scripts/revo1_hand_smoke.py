#!/usr/bin/env python3
"""Bounded Revo-1 DDS smoke test through the G1-D adapter."""

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
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("adapter closed the socket")
        data.extend(chunk)
    return bytes(data)


def receive_frame(sock: socket.socket) -> dict[str, Any]:
    size = struct.unpack("<I", receive_exact(sock, 4))[0]
    return json.loads(receive_exact(sock, size))


def command(side: str | None = None, grasp: float | None = None) -> dict[str, Any]:
    axes: dict[str, float] = {}
    buttons: dict[str, bool] = {}
    if side is not None and grasp is not None:
        buttons[f"{side}_hand_enable"] = True
        axes[f"revo1_{side}_grasp"] = grasp
    return {
        "type": "Command",
        "axes": axes,
        "buttons": buttons,
        "poses": {},
        "timestamp_ns": time.time_ns(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default="/tmp/operator-g1d.sock")
    parser.add_argument("--side", choices=("left", "right"), default="left")
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--open-only", action="store_true")
    parser.add_argument("--rate-hz", type=float, default=72.0)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2.0)
    sock.connect(args.socket)
    send_frame(sock, {"type": "Hello"})
    if receive_frame(sock).get("type") != "Descriptor":
        raise RuntimeError("missing descriptor")
    if receive_frame(sock).get("type") != "Blueprint":
        raise RuntimeError("missing blueprint")

    lock = threading.Lock()
    telemetry: list[dict[str, Any]] = []
    reading = True

    def reader_loop() -> None:
        nonlocal reading
        sock.settimeout(0.5)
        while reading:
            try:
                frame = receive_frame(sock)
            except socket.timeout:
                continue
            except (ConnectionError, OSError):
                return
            if frame.get("type") == "Telemetry":
                with lock:
                    telemetry.append(frame.get("values", {}))

    reader = threading.Thread(target=reader_loop, daemon=True)
    reader.start()

    def latest(timeout_s: float = 2.0) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            with lock:
                if telemetry:
                    return telemetry[-1]
            time.sleep(0.02)
        raise TimeoutError("no telemetry received")

    try:
        initial = latest()
        position_key = f"revo1_{args.side}_position"
        velocity_key = f"revo1_{args.side}_velocity"
        fresh_key = f"{args.side}_hand_fresh"
        positions = [float(value) for value in initial.get(position_key, [])]
        velocities = [float(value) for value in initial.get(velocity_key, [])]
        if not initial.get(fresh_key) or len(positions) != 6 or len(velocities) != 6:
            raise RuntimeError(f"{args.side} Revo-1 feedback is not fresh and complete")
        if max(abs(value) for value in velocities) > 0.10:
            raise RuntimeError(f"{args.side} Revo-1 is not stationary")
        if args.preflight_only:
            print(json.dumps({
                "ok": True,
                "side": args.side,
                "positions": positions,
                "velocities": velocities,
                "feedback_age_ms": initial.get(f"{args.side}_hand_age_ms"),
            }, ensure_ascii=False))
            return 0

        before = positions
        send_frame(sock, {
            "type": "Command",
            "axes": {},
            "buttons": {"reset": True},
            "poses": {},
            "timestamp_ns": time.time_ns(),
        })
        time.sleep(0.15)
        period = 1.0 / args.rate_hz
        if args.open_only:
            for _ in range(max(1, int(args.rate_hz * 2.0))):
                send_frame(sock, command(args.side, 0.0))
                time.sleep(period)
            for _ in range(8):
                send_frame(sock, command())
                time.sleep(period)
            time.sleep(0.5)
            final = latest()
            final_positions = [float(value) for value in final.get(position_key, [])]
            final_velocities = [float(value) for value in final.get(velocity_key, [])]
            active_indices = (0, 2, 3, 4, 5)
            max_position = max(abs(final_positions[index]) for index in active_indices)
            max_velocity = max(abs(value) for value in final_velocities)
            if max_position > 0.03 or max_velocity > 0.10:
                raise RuntimeError(
                    f"Revo-1 did not open and settle: position={max_position}, velocity={max_velocity}"
                )
            print(json.dumps({
                "ok": True,
                "side": args.side,
                "max_abs_position": max_position,
                "final_max_abs_velocity": max_velocity,
            }, ensure_ascii=False))
            return 0

        for _ in range(max(1, int(args.rate_hz * 2.0))):
            send_frame(sock, command(args.side, 1.0))
            time.sleep(period)
        moved = latest()
        moved_positions = [float(value) for value in moved.get(position_key, [])]
        active_indices = (0, 2, 3, 4, 5)
        movement = [moved_positions[index] - before[index] for index in active_indices]
        if max(abs(value) for value in movement) < 0.03:
            raise RuntimeError(f"no measurable Revo-1 response: {movement}")

        for _ in range(max(1, int(args.rate_hz * 2.0))):
            send_frame(sock, command(args.side, 0.0))
            time.sleep(period)
        for _ in range(8):
            send_frame(sock, command())
            time.sleep(period)
        time.sleep(0.5)
        final = latest()
        final_positions = [float(value) for value in final.get(position_key, [])]
        final_velocities = [float(value) for value in final.get(velocity_key, [])]
        max_open_error = max(abs(final_positions[index]) for index in active_indices)
        max_final_velocity = max(abs(value) for value in final_velocities)
        if max_open_error > 0.05:
            raise RuntimeError(f"Revo-1 did not return to open: {max_open_error}")
        if max_final_velocity > 0.10:
            raise RuntimeError(f"Revo-1 did not settle: {max_final_velocity}")
        print(json.dumps({
            "ok": True,
            "side": args.side,
            "movement": movement,
            "max_open_error": max_open_error,
            "final_max_abs_velocity": max_final_velocity,
        }, ensure_ascii=False))
        return 0
    finally:
        try:
            send_frame(sock, command())
            send_frame(sock, {"type": "Stop", "reason": "revo1_hand_smoke_complete"})
        except OSError:
            pass
        reading = False
        reader.join(timeout=1.0)
        sock.close()


if __name__ == "__main__":
    raise SystemExit(main())
