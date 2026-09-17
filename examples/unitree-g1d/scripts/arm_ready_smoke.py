#!/usr/bin/env python3
"""Bounded G1-D X-ready / Y-initial arm-pose smoke test."""

from __future__ import annotations

import argparse
import json
import math
import socket
import struct
import threading
import time
from typing import Any

READY = (
    0.0, 0.20, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, -0.20, 0.0, 0.0, 0.0, 0.0, 0.0,
)
INITIAL = (
    0.0, 0.0, 0.0, math.pi / 2.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, math.pi / 2.0, 0.0, 0.0, 0.0,
)


def send(sock: socket.socket, message: dict[str, Any]) -> None:
    payload = json.dumps(message, separators=(",", ":")).encode()
    sock.sendall(struct.pack("<I", len(payload)) + payload)


def receive_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("adapter closed")
        data.extend(chunk)
    return bytes(data)


def receive(sock: socket.socket) -> dict[str, Any]:
    size = struct.unpack("<I", receive_exact(sock, 4))[0]
    return json.loads(receive_exact(sock, size))


def command(buttons: dict[str, bool] | None = None) -> dict[str, Any]:
    return {
        "type": "Command",
        "axes": {},
        "buttons": buttons or {},
        "poses": {},
        "timestamp_ns": time.time_ns(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=("ready", "initial"), default="ready")
    args = parser.parse_args()
    target = READY if args.action == "ready" else INITIAL
    button_name = "arm_ready" if args.action == "ready" else "arm_init"
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2.0)
    sock.connect("/tmp/operator-g1d.sock")
    send(sock, {"type": "Hello"})
    if receive(sock).get("type") != "Descriptor" or receive(sock).get("type") != "Blueprint":
        raise RuntimeError("bad adapter handshake")

    lock = threading.Lock()
    telemetry: list[dict[str, Any]] = []
    running = True

    def read_loop() -> None:
        sock.settimeout(0.5)
        while running:
            try:
                frame = receive(sock)
            except (socket.timeout, ConnectionError, OSError):
                continue
            if frame.get("type") == "Telemetry":
                with lock:
                    telemetry.append(frame.get("values", {}))

    thread = threading.Thread(target=read_loop, daemon=True)
    thread.start()

    def latest(timeout: float = 2.0) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with lock:
                if telemetry:
                    return telemetry[-1]
            time.sleep(0.02)
        raise TimeoutError("no telemetry")

    try:
        initial = latest()
        stable_deadline = time.monotonic() + 3.0
        while True:
            joints = initial.get("joint_positions_rad", [])
            velocities = initial.get("joint_velocities_rad_s", [])
            if (len(velocities) == 29 and
                    max(abs(float(velocities[i])) for i in range(15, 29)) <= 0.10):
                break
            if time.monotonic() >= stable_deadline:
                raise RuntimeError("arms are not stationary")
            time.sleep(0.10)
            initial = latest()
        if not initial.get("lowstate_fresh") or len(joints) != 29 or len(velocities) != 29:
            raise RuntimeError("joint feedback is not fresh and complete")
        if int(initial.get("motor_fault_count", -1)) != 0:
            raise RuntimeError("upper-body motor fault")
        if not initial.get("left_hand_fresh") or not initial.get("right_hand_fresh"):
            raise RuntimeError("Revo-1 feedback is not fresh")
        send(sock, command({"reset": True}))
        time.sleep(0.15)
        send(sock, command({button_name: True}))
        deadline = time.monotonic() + 12.0
        final: dict[str, Any] | None = None
        last_observed: dict[str, Any] | None = None
        last_error = float("inf")
        last_hand_error = float("inf")
        last_speed = float("inf")
        while time.monotonic() < deadline:
            send(sock, command())
            time.sleep(1.0 / 72.0)
            sample = latest()
            q = [float(v) for v in sample.get("joint_positions_rad", [])]
            dq = [float(v) for v in sample.get("joint_velocities_rad_s", [])]
            if len(q) != 29 or len(dq) != 29:
                continue
            arm_q = q[15:22] + q[22:29]
            error = max(abs(a - b) for a, b in zip(arm_q, target))
            hand_error = max(
                (abs(float(v))
                for key in ("revo1_left_position", "revo1_right_position")
                for i, v in enumerate(sample.get(key, []))
                if i != 1),
                default=999.0,
            )
            speed = max(abs(dq[i]) for i in range(15, 29))
            last_observed = sample
            last_error = error
            last_hand_error = hand_error
            last_speed = speed
            if error <= 0.04 and hand_error <= 0.03 and speed <= 0.10:
                final = sample
                break
        if final is None:
            observed_q = []
            if last_observed is not None:
                all_q = [float(v) for v in last_observed.get("joint_positions_rad", [])]
                if len(all_q) == 29:
                    observed_q = all_q[15:22] + all_q[22:29]
            raise RuntimeError(
                "ready pose did not converge and settle before timeout: "
                f"arm_positions_rad={observed_q}, max_error_rad={last_error}, "
                f"hand_error={last_hand_error}, max_speed_rad_s={last_speed}"
            )
        q = [float(v) for v in final["joint_positions_rad"]]
        arm_q = q[15:22] + q[22:29]
        print(json.dumps({
            "ok": True,
            "action": args.action,
            "arm_positions_rad": arm_q,
            "max_ready_error_rad": max(abs(a - b) for a, b in zip(arm_q, target)),
            "left_hand": final.get("revo1_left_position"),
            "right_hand": final.get("revo1_right_position"),
        }, ensure_ascii=False))
        return 0
    finally:
        try:
            send(sock, command())
            send(sock, {"type": "Stop", "reason": f"arm_{args.action}_smoke_complete"})
        except OSError:
            pass
        running = False
        thread.join(timeout=1.0)
        sock.close()


if __name__ == "__main__":
    raise SystemExit(main())
