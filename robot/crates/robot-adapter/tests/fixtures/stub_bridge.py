#!/usr/bin/env python3
"""Tiny stand-in for examples/mujuco-arm-so101/sim_so101.py `bridge` mode.

Speaks the same stdin/stdout JSON-line protocol the real MuJoCo bridge does,
but with no MuJoCo dependency — so the driver's framing (ready handshake +
step/reset round-trip) can be tested hermetically without the sim.

Protocol:
  * emit one `{"event":"ready","nq":13,"nu":6,"joint_names":[...]}` line at start
  * per inbound line:
      - `{"reset":true}`            -> reply `{"q":[6 floats home]}`
      - `{"ctrl":[6 floats],...}`   -> reply `{"q":[ctrl echoed back]}`
    so the joint snapshot tracks the commanded ctrl (lets a test assert the
    sim "moved").
"""
import json
import sys

HOME = [0.0, -1.57, 1.57, 0.0, 0.0, 0.0]


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    # argv: stub_bridge.py bridge [extra...]
    emit({
        "event": "ready",
        "nq": 13,
        "nu": 6,
        "joint_names": [
            "shoulder_pan", "shoulder_lift", "elbow_flex",
            "wrist_flex", "wrist_roll", "gripper",
        ],
    })
    last = list(HOME)
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
            last = list(HOME)
            emit({"q": last, "cube": [0.0] * 7, "ts_ns": 0})
        elif isinstance(msg.get("ctrl"), list):
            ctrl = msg["ctrl"]
            if len(ctrl) != 6:
                emit({"error": "ctrl must be list of 6 floats"})
                continue
            # Echo the commanded ctrl as the new joint snapshot so the
            # snapshot tracks input (a test can detect motion this way).
            last = [float(x) for x in ctrl]
            emit({"q": last, "cube": [0.0] * 7, "ts_ns": 0})
        else:
            emit({"error": "unknown message"})


if __name__ == "__main__":
    main()
