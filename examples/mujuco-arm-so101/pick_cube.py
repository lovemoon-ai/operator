"""Scripted pick-up of the red cube on the SO-101 arm.

Pipeline
--------
1.  Load `scene_pickplace.xml`, reset to keyframe `home`.
2.  Locate the red_cube body and the `gripperframe` site (jaw tip).
3.  Solve damped-least-squares IK for 3 Cartesian waypoints:
        - APPROACH   : ~10 cm above the cube
        - GRASP      : at cube center
        - LIFT       : 20 cm above the cube
    Each IK is warm-started from the previous solution so the arm keeps
    a smooth posture (no flips).
4.  Track the resulting joint targets with the existing <position>
    actuators using a smoothstep ease in joint space.
5.  Open / close the gripper at the right phases.
6.  Save snapshot PNGs of every camera at the lift apex.

Run:
    make pick
or:
    python pick_cube.py --out renders
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import mujoco
import numpy as np

HERE = Path(__file__).resolve().parent
MODEL_PATH = HERE / "assets" / "so101" / "scene_pickplace.xml"

ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll"]
GRIPPER_ACT = "gripper"
GRIPPER_OPEN = 0.8       # rad (positive -> jaw open)
GRIPPER_CLOSED = -0.10   # rad (slightly past 0 to grip)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_indices(model: mujoco.MjModel) -> dict:
    arm_jids = [mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, n) for n in ARM_JOINTS]
    return {
        "arm_jids": arm_jids,
        "arm_qadr": [model.jnt_qposadr[j] for j in arm_jids],
        "arm_dofadr": [model.jnt_dofadr[j] for j in arm_jids],
        "arm_actids": [mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_ACTUATOR, n)
                       for n in ARM_JOINTS],
        "grip_actid": mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_ACTUATOR, GRIPPER_ACT),
        "site_id": mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_SITE, "gripperframe"),
        "cube_id": mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_BODY, "red_cube"),
    }


def ik_pose(model, data, idx, target_pos, target_axis_world=None,
            ori_weight: float = 1.5,
            max_iters: int = 800, tol: float = 1.0e-3,
            lam: float = 0.05, step: float = 0.4) -> tuple[np.ndarray, float]:
    """Damped LS IK on the 5 arm joints.

    target_pos          : 3D world target for the `gripperframe` site.
    target_axis_world   : if given, the world unit vector that the site's
                          *outward* axis (-Z of the gripper body, i.e. the
                          direction from gripper body toward jaw tips) should
                          be aligned with. Use (0,0,-1) for "jaws pointing
                          straight down".

    Returns (q_arm, final_pos_error_norm).
    """
    jacp = np.zeros((3, model.nv))
    jacr = np.zeros((3, model.nv))
    last_err = np.inf
    for _ in range(max_iters):
        mujoco.mj_forward(model, data)
        site_xmat = data.site_xmat[idx["site_id"]].reshape(3, 3)

        # Position error.
        pos_err = target_pos - data.site_xpos[idx["site_id"]]

        # Orientation error: rotate current gripper "down" axis onto target.
        # The gripperframe site has quat="1 0 1 0" (90° about Y); after that
        # rotation, the world direction of the body's -Z axis equals the
        # site's local +X axis. So we use site_xmat[:, 0] as the "outward"
        # direction and align it with target_axis_world via cross product.
        if target_axis_world is not None:
            cur_axis = site_xmat[:, 0]
            ori_err = np.cross(cur_axis, target_axis_world) * ori_weight
            err = np.concatenate([pos_err, ori_err])
            mujoco.mj_jacSite(model, data, jacp, jacr, idx["site_id"])
            J = np.vstack([
                jacp[:, idx["arm_dofadr"]],
                jacr[:, idx["arm_dofadr"]] * ori_weight,
            ])
            damp = (lam ** 2) * np.eye(6)
        else:
            err = pos_err
            mujoco.mj_jacSite(model, data, jacp, jacr, idx["site_id"])
            J = jacp[:, idx["arm_dofadr"]]
            damp = (lam ** 2) * np.eye(3)

        last_err = float(np.linalg.norm(pos_err))
        if last_err < tol and (target_axis_world is None
                               or np.linalg.norm(err[3:]) < 5e-3):
            break

        dq = J.T @ np.linalg.solve(J @ J.T + damp, err)
        for k, qa in enumerate(idx["arm_qadr"]):
            data.qpos[qa] += step * dq[k]
        for k, jid in enumerate(idx["arm_jids"]):
            lo, hi = model.jnt_range[jid]
            qa = idx["arm_qadr"][k]
            data.qpos[qa] = np.clip(data.qpos[qa], lo, hi)

    return (np.array([data.qpos[qa] for qa in idx["arm_qadr"]]), last_err)


def smooth_track(model, data, idx, q_target: np.ndarray, grip_target: float,
                 duration_s: float):
    """PD-track from current ctrl to (q_target, grip_target) over duration_s."""
    n_steps = max(1, int(duration_s / model.opt.timestep))
    start = np.array([data.ctrl[a] for a in idx["arm_actids"]])
    start_g = data.ctrl[idx["grip_actid"]]
    for i in range(n_steps):
        alpha = (i + 1) / n_steps
        s = alpha * alpha * (3 - 2 * alpha)        # smoothstep easing
        for k, a in enumerate(idx["arm_actids"]):
            data.ctrl[a] = start[k] + s * (q_target[k] - start[k])
        data.ctrl[idx["grip_actid"]] = start_g + s * (grip_target - start_g)
        mujoco.mj_step(model, data)


def settle(model, data, seconds: float):
    for _ in range(int(seconds / model.opt.timestep)):
        mujoco.mj_step(model, data)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run(out_dir: Path, save_frames: bool, width: int, height: int) -> None:
    model = mujoco.MjModel.from_xml_path(str(MODEL_PATH))
    data = mujoco.MjData(model)
    key = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_KEY, "home")
    mujoco.mj_resetDataKeyframe(model, data, key)
    idx = get_indices(model)

    mujoco.mj_forward(model, data)
    cube_pos = data.xpos[idx["cube_id"]].copy()
    site0 = data.site_xpos[idx["site_id"]].copy()
    print(f"cube         : {cube_pos}")
    print(f"gripper@home : {site0}")

    # 3 Cartesian waypoints for the gripperframe site (jaw tip).
    # Targets are kept close to the cube so the arm + orientation constraint
    # can both be satisfied (the SO-101 has only 5 arm DoF and limited reach).
    approach = cube_pos + np.array([0.0, 0.0, 0.07])
    grasp    = cube_pos + np.array([0.0, 0.0, -0.005])
    lift     = cube_pos + np.array([0.0, 0.0, 0.12])

    # Solve IK in a scratch MjData (so the live data.qpos isn't perturbed).
    scratch = mujoco.MjData(model)
    mujoco.mj_resetDataKeyframe(model, scratch, key)

    DOWN = np.array([0.0, 0.0, -1.0])

    def solve(target, axis=DOWN):
        # Warm-start from previous IK pose for smooth, consistent posture.
        q_arm, perr = ik_pose(model, scratch, idx, target, target_axis_world=axis)
        return q_arm, perr

    q_approach, e1 = solve(approach)
    q_grasp,    e2 = solve(grasp)
    q_lift,     e3 = solve(lift)
    print(f"q_approach   : {np.round(q_approach, 3)}  pos_err={e1:.4f}")
    print(f"q_grasp      : {np.round(q_grasp, 3)}  pos_err={e2:.4f}")
    print(f"q_lift       : {np.round(q_lift, 3)}  pos_err={e3:.4f}")

    # Init ctrl from current home pose so smooth_track has a sensible start.
    for k, a in enumerate(idx["arm_actids"]):
        data.ctrl[a] = data.qpos[idx["arm_qadr"][k]]
    data.ctrl[idx["grip_actid"]] = GRIPPER_OPEN

    # Optional snapshot helper.
    snapshot_dir = out_dir if save_frames else None
    snap_renderer = None
    if snapshot_dir is not None:
        snapshot_dir.mkdir(parents=True, exist_ok=True)
        snap_renderer = mujoco.Renderer(model, height=height, width=width)

    def snap(tag: str, cam: str = "side_cam") -> None:
        if snap_renderer is None:
            return
        from PIL import Image
        snap_renderer.update_scene(data, camera=cam)
        Image.fromarray(snap_renderer.render()).save(snapshot_dir / f"pick_{tag}_{cam}.png")

    # Run the pick-and-place sequence.
    print("→ phase 1: move above cube (open)")
    smooth_track(model, data, idx, q_approach, GRIPPER_OPEN, duration_s=1.5)
    snap("01_approach")

    print("→ phase 2: descend to cube")
    smooth_track(model, data, idx, q_grasp, GRIPPER_OPEN, duration_s=1.0)
    snap("02_at_cube")

    print("→ phase 3: close gripper")
    smooth_track(model, data, idx, q_grasp, GRIPPER_CLOSED, duration_s=0.6)
    settle(model, data, 0.2)
    snap("03_grasped")

    print("→ phase 4: lift")
    smooth_track(model, data, idx, q_lift, GRIPPER_CLOSED, duration_s=1.5)
    settle(model, data, 0.5)
    snap("04_lifted")

    cube_z = data.xpos[idx["cube_id"]][2]
    print(f"final cube z = {cube_z:.4f}  (table top is z = 0)")
    if cube_z > 0.05:
        print("✓ cube lifted off the table.")
    else:
        print("✗ cube did NOT lift — try tuning waypoints / IK.")

    if save_frames:
        out_dir.mkdir(parents=True, exist_ok=True)
        from PIL import Image
        cams = ["side_cam", "front_cam", "wrist_cam"]
        with mujoco.Renderer(model, height=height, width=width) as r:
            for cam in cams:
                r.update_scene(data, camera=cam)
                p = out_dir / f"pick_{cam}.png"
                Image.fromarray(r.render()).save(p)
                print(f"  wrote {p}")
    if snap_renderer is not None:
        snap_renderer.close()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, default=HERE / "renders")
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    p.add_argument("--no-save", action="store_true")
    args = p.parse_args()
    run(args.out, save_frames=not args.no_save,
        width=args.width, height=args.height)


if __name__ == "__main__":
    main()
