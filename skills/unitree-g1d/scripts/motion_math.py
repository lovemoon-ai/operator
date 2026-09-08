#!/usr/bin/env python3
"""Geometry only: project measured displacement into the original start frame."""
import argparse
import json
import math

def project(origin, pose, target):
    if len(origin) != 3 or len(pose) != 2:
        raise ValueError("origin=(x0,y0,yaw0), pose=(x,y)")
    values = [*origin, *pose, target]
    if not all(math.isfinite(v) for v in values):
        raise ValueError("All inputs must be finite")
    x0, y0, yaw0 = origin
    x, y = pose
    dx, dy = x - x0, y - y0
    forward = dx * math.cos(yaw0) + dy * math.sin(yaw0)
    lateral = -dx * math.sin(yaw0) + dy * math.cos(yaw0)
    remaining = target - forward
    return {"forward_m": forward, "lateral_m": lateral, "remaining_m": remaining,
            "euclidean_m": math.hypot(dx, dy), "target_m": target,
            "motion_or_stationary_status_assessed": False}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--origin", nargs=3, type=float, required=True, metavar=("X0", "Y0", "YAW0"))
    p.add_argument("--pose", nargs=2, type=float, required=True, metavar=("X", "Y"))
    p.add_argument("--target", type=float, required=True, help="Signed target in original start frame, metres")
    args = p.parse_args()
    try:
        print(json.dumps(project(args.origin, args.pose, args.target), allow_nan=False))
    except ValueError as exc:
        p.error(str(exc))

if __name__ == "__main__":
    main()
