#!/usr/bin/env python3
"""Tiny stand-in for the LeRobot `vr_operator` teleoperator plugin.

Speaks the `lerobot_link` wire protocol (see
`crates/robot-adapter/src/control/drivers/lerobot_link.rs`) without LeRobot,
placo, or hardware, so the Rust driver's framing and lifecycle can be tested
hermetically.

Unlike the subprocess drivers this replaces, the adapter *listens* and the
plugin *dials in* — so this stub is a client, and the test spawns it rather than
the driver spawning it.

Usage:
    stub_vr_plugin.py --endpoint uds:/tmp/x.sock [--fail-ee] [--delay-ee-ms N]
"""

from __future__ import annotations

import argparse
import json
import socket
import struct
import sys
import time

HOME = [0.0, -90.0, 90.0, 0.0, 0.0, 85.0]
HOME_EE = {"position": [0.25, 0.0, 0.2], "rotation": [0.0, 0.0, 0.0, 1.0]}
NAMES = [
    "shoulder_pan",
    "shoulder_lift",
    "elbow_flex",
    "wrist_flex",
    "wrist_roll",
    "gripper",
]

CONNECT_TIMEOUT_S = 10.0


def connect(endpoint: str) -> socket.socket:
    """Dial `uds:<path>` or `tcp:<host>:<port>`, retrying until the adapter binds."""
    deadline = time.monotonic() + CONNECT_TIMEOUT_S
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            if endpoint.startswith("uds:"):
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(endpoint[len("uds:") :])
            elif endpoint.startswith("tcp:"):
                host, _, port = endpoint[len("tcp:") :].rpartition(":")
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.connect((host, int(port)))
            else:
                raise ValueError(f"bad endpoint {endpoint!r}")
            return sock
        except (OSError, ConnectionError) as e:  # adapter not listening yet
            last_err = e
            time.sleep(0.02)
    raise SystemExit(f"stub_vr_plugin: could not connect to {endpoint}: {last_err}")


def send(sock: socket.socket, obj: dict) -> None:
    payload = json.dumps(obj).encode()
    sock.sendall(struct.pack("<I", len(payload)) + payload)


def recv_exact(sock: socket.socket, n: int) -> bytes | None:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def recv(sock: socket.socket) -> dict | None:
    header = recv_exact(sock, 4)
    if header is None:
        return None
    (length,) = struct.unpack("<I", header)
    body = recv_exact(sock, length)
    if body is None:
        return None
    return json.loads(body)


def snapshot(positions: list[float], ee: dict, ik_error: float = 0.0) -> dict:
    return {
        "type": "State",
        "positions": list(positions),
        "ee": dict(ee),
        "ik_error": ik_error,
        "ts_ns": 0,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--fail-ee", action="store_true")
    parser.add_argument("--delay-ee-ms", type=float, default=0.0)
    args = parser.parse_args()

    sock = connect(args.endpoint)

    pos = list(HOME)
    ee = dict(HOME_EE)
    reset_epoch = 0
    stopped = False

    send(
        sock,
        {"type": "Hello", "joint_names": NAMES, "positions": list(pos), "ee": dict(ee)},
    )

    while True:
        msg = recv(sock)
        if msg is None:
            return  # adapter closed
        kind = msg.get("type")

        if kind == "Control":
            if msg.get("reset_epoch", 0) != reset_epoch:
                reset_epoch = msg.get("reset_epoch", 0)
                pos = list(HOME)
                ee = dict(HOME_EE)
                stopped = False
                send(sock, snapshot(pos, ee))
            was_stopped = stopped
            stopped = bool(msg.get("stopped"))
            if stopped and not was_stopped:
                # Observable e-stop marker so the Rust tests can assert an arm
                # was safed.
                pos[0] = -123.0
                send(sock, snapshot(pos, ee))
            continue

        if kind != "Target":
            send(sock, {"type": "Error", "msg": f"unknown message {kind!r}"})
            continue

        if stopped:
            # Targets and control travel on independent channels, so a target
            # published just before an e-stop can still arrive just after it.
            # A stopped plugin must not act on it — mirrors the real plugin,
            # whose get_action() returns {} while Control.stopped is set.
            continue

        if msg.get("ee_pose") is not None:
            if args.fail_ee:
                send(sock, {"type": "Error", "msg": "forced ee failure"})
                continue
            if args.delay_ee_ms > 0.0:
                time.sleep(args.delay_ee_ms / 1000.0)
            target = msg["ee_pose"]
            pos[0] = float(target["position"][0])
            ee = {
                "position": [float(x) for x in target["position"]],
                "rotation": [float(x) for x in target["rotation"]],
            }

        if msg.get("positions") is not None:
            values = msg["positions"]
            if len(values) != 5:
                send(sock, {"type": "Error", "msg": "positions must contain 5 floats"})
                continue
            pos[:5] = [float(x) for x in values]

        if msg.get("gripper") is not None:
            # Stub mirrors the plugin's 0..1 -> 0..100 RANGE_0_100 mapping.
            pos[5] = float(msg["gripper"]) * 100.0

        send(sock, snapshot(pos, ee))


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, ConnectionResetError):
        sys.exit(0)
