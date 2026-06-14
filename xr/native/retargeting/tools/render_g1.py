#!/usr/bin/env python3
"""Render a G1 robot_solution.jsonl (per-frame joint_q) to an MP4.

Visualization side of the offline spatialmp4 -> retarget -> G1 pipeline. Uses
MuJoCo's offscreen renderer + the g1_mocap_29dof model. The base (qpos[0:7]) is
frozen at the model rest pose; qpos[7:36] are the 29 actuated joints in order.

Usage:
  render_g1.py <robot_solution.jsonl> --out g1.mp4 \
      [--model <g1_mocap_29dof.xml>] [--fps 30] [--width 640] [--height 480]

Run with the GMR venv python (has mujoco + imageio):
  ~/.cache/install-x/GMR/.venv/bin/python render_g1.py ...
"""
import argparse
import json
import os
import sys

import numpy as np


def load_solution(path):
    qs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                qs.append(np.asarray(json.loads(line)["joint_q"], dtype=float))
    return qs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("solution_jsonl")
    ap.add_argument("--model", default=os.path.expanduser(
        "~/.cache/install-x/GMR/assets/unitree_g1/g1_mocap_29dof.xml"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--max_frames", type=int, default=0)
    args = ap.parse_args()

    import mujoco
    import imageio.v2 as imageio

    model = mujoco.MjModel.from_xml_path(args.model)
    data = mujoco.MjData(model)
    mujoco.mj_resetData(model, data)
    base_qpos = data.qpos.copy()  # rest config; base at [0:7]

    sols = load_solution(args.solution_jsonl)
    if args.max_frames > 0:
        sols = sols[: args.max_frames]
    if not sols:
        sys.exit("no frames in solution jsonl")

    n_joints = model.nq - 7
    renderer = mujoco.Renderer(model, height=args.height, width=args.width)
    cam = mujoco.MjvCamera()
    cam.lookat[:] = [0.0, 0.0, 0.9]
    cam.distance = 2.6
    cam.azimuth = 150.0
    cam.elevation = -10.0

    frames = []
    for i, jq in enumerate(sols):
        qpos = base_qpos.copy()
        m = min(n_joints, len(jq))
        qpos[7 : 7 + m] = jq[:m]
        data.qpos[:] = qpos
        mujoco.mj_forward(model, data)
        renderer.update_scene(data, camera=cam)
        frames.append(renderer.render())
    imageio.mimsave(args.out, frames, fps=args.fps)
    print(f"wrote {len(frames)} frames -> {args.out} ({args.width}x{args.height} @ {args.fps}fps)")


if __name__ == "__main__":
    main()
