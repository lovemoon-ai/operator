#!/usr/bin/env python3
"""Tiny stand-in for scripts/so101_real_bridge.py.

Speaks the real SO-101 JSON-line protocol without hardware so Rust driver
framing can be tested hermetically.
"""

import json
import sys

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


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def snapshot(positions):
    return {
        "positions": list(positions),
        "ee": dict(HOME_EE),
        "currents": {name: 0 for name in NAMES},
        "loads": {name: 0 for name in NAMES},
        "ts_ns": 0,
    }


def main():
    # argv: stub_so101_bridge.py bridge --port <port> [extra...]
    pos = list(HOME)
    emit({"event": "ready", "joint_names": NAMES, **snapshot(pos)})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            emit({"error": f"bad json: {line!r}"})
            continue
        if msg.get("reset"):
            pos = list(HOME)
            emit(snapshot(pos))
        elif msg.get("stop"):
            emit(snapshot(pos))
        elif msg.get("enable"):
            emit(snapshot(pos))
        elif isinstance(msg.get("ee_pose"), dict):
            ee = msg["ee_pose"]
            pos[0] = float(ee.get("position", HOME_EE["position"])[0])
            if msg.get("gripper") is not None:
                pos[5] = 8.0 + float(msg["gripper"]) * (85.0 - 8.0)
            snap = snapshot(pos)
            snap["ee"] = {
                "position": [float(x) for x in ee.get("position", HOME_EE["position"])],
                "rotation": [float(x) for x in ee.get("rotation", HOME_EE["rotation"])],
            }
            snap["ik_error"] = 0.0
            emit(snap)
        elif "positions" in msg or "gripper" in msg:
            if msg.get("positions") is not None:
                values = msg["positions"]
                if len(values) != 5:
                    emit({"error": "positions must contain 5 floats"})
                    continue
                pos[:5] = [float(x) for x in values]
            if msg.get("gripper") is not None:
                pos[5] = 8.0 + float(msg["gripper"]) * (85.0 - 8.0)
            emit(snapshot(pos))
        else:
            emit({"error": "unknown message"})


if __name__ == "__main__":
    main()
