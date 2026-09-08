"""SO-101 pick-and-place MuJoCo simulation.

Four modes:
    viewer   - interactive 3D viewer (passive, mouse/keyboard control).
    render   - offscreen render of the wrist + side cameras to PNG.
    smoketest - load the model, step a few times, print key info.
    bridge   - stdin/stdout JSON-line protocol used by robo-agent's
               MujocoSo101 device. Acts as the "hardware" side of the
               teleoperation loop: takes joint targets or end-effector pose
               targets, steps the sim, returns joint angles + end-effector
               pose + cube pose.

Examples:
    python sim_so101.py viewer
    python sim_so101.py render --steps 200 --out renders
    python sim_so101.py smoketest
    python sim_so101.py bridge

Run from the directory containing this file (so the relative model path resolves).
"""

from __future__ import annotations

import argparse
import json
import os
import select
import sys
import time
from pathlib import Path

import mujoco
import numpy as np

HERE = Path(__file__).resolve().parent
MODEL_PATH = HERE / "assets" / "so101" / "scene_pickplace.xml"


def load_model() -> tuple[mujoco.MjModel, mujoco.MjData]:
    if not MODEL_PATH.exists():
        sys.exit(f"Model XML not found: {MODEL_PATH}")
    model = mujoco.MjModel.from_xml_path(str(MODEL_PATH))
    data = mujoco.MjData(model)
    # Apply the "home" keyframe if present.
    key_id = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_KEY, "home")
    if key_id >= 0:
        mujoco.mj_resetDataKeyframe(model, data, key_id)
    else:
        mujoco.mj_resetData(model, data)
    return model, data


def list_cameras(model: mujoco.MjModel) -> list[str]:
    names = []
    for i in range(model.ncam):
        name = mujoco.mj_id2name(model, mujoco.mjtObj.mjOBJ_CAMERA, i)
        if name:
            names.append(name)
    return names


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

def run_viewer() -> None:
    """Open the interactive passive viewer.

    Controls (default MuJoCo viewer):
        - Left  drag : rotate camera
        - Right drag : pan camera
        - Scroll     : zoom
        - Tab        : cycle through scene cameras (wrist_cam, side_cam, ...)
        - Space      : pause / resume
        - Backspace  : reset to keyframe
    """
    try:
        import mujoco.viewer as viewer
    except ImportError:
        sys.exit("mujoco.viewer is unavailable in this build of mujoco.")

    model, data = load_model()
    print(f"Loaded {MODEL_PATH}")
    print(f"Cameras: {list_cameras(model)}")
    print("Press Tab in the viewer to switch cameras.")

    with viewer.launch_passive(model, data) as v:
        # Start with the side camera so the user immediately sees the scene.
        side_id = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_CAMERA, "side_cam")
        if side_id >= 0:
            v.cam.fixedcamid = side_id
            v.cam.type = mujoco.mjtCamera.mjCAMERA_FIXED

        sim_step = model.opt.timestep
        last_wall = time.perf_counter()
        while v.is_running():
            mujoco.mj_step(model, data)
            v.sync()
            # Real-time pacing.
            now = time.perf_counter()
            sleep = sim_step - (now - last_wall)
            if sleep > 0:
                time.sleep(sleep)
            last_wall = time.perf_counter()


def run_render(steps: int, out_dir: Path, width: int, height: int) -> None:
    """Offscreen-render wrist_cam and side_cam after `steps` simulation steps."""
    model, data = load_model()
    out_dir.mkdir(parents=True, exist_ok=True)

    # Step the simulation forward so things settle.
    for _ in range(steps):
        mujoco.mj_step(model, data)

    cameras = list_cameras(model)
    print(f"Rendering cameras: {cameras}")

    try:
        from PIL import Image
    except ImportError:
        Image = None  # fall back to numpy .npy

    with mujoco.Renderer(model, height=height, width=width) as renderer:
        for cam in cameras:
            renderer.update_scene(data, camera=cam)
            pixels = renderer.render()  # (H, W, 3) uint8
            out_path = out_dir / f"{cam}.png"
            if Image is not None:
                Image.fromarray(pixels).save(out_path)
            else:
                np.save(out_path.with_suffix(".npy"), pixels)
                out_path = out_path.with_suffix(".npy")
            print(f"  wrote {out_path}")


def run_smoketest() -> None:
    """Sanity check: load model, step, and print key information."""
    model, data = load_model()
    print("=== SO-101 scene smoketest ===")
    print(f"  XML        : {MODEL_PATH}")
    print(f"  nq / nv    : {model.nq} / {model.nv}")
    print(f"  nbody      : {model.nbody}")
    print(f"  njnt       : {model.njnt}")
    print(f"  nu (act.)  : {model.nu}")
    print(f"  cameras    : {list_cameras(model)}")

    actuator_names = []
    for i in range(model.nu):
        actuator_names.append(
            mujoco.mj_id2name(model, mujoco.mjtObj.mjOBJ_ACTUATOR, i)
        )
    print(f"  actuators  : {actuator_names}")

    # Step 100 times.
    t0 = time.perf_counter()
    for _ in range(100):
        mujoco.mj_step(model, data)
    dt = time.perf_counter() - t0
    print(f"  100 steps in {dt*1000:.1f} ms ({100/dt:.0f} Hz wall-clock)")

    cube_id = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_BODY, "red_cube")
    if cube_id >= 0:
        print(f"  red_cube z = {data.xpos[cube_id, 2]:.4f} m")
    print("OK")


## ---------------------------------------------------------------------------
## Bridge mode — IO loop driven by robo-agent (Rust) over stdin/stdout.
##
## Protocol (one JSON object per line, both directions):
##
##   ready  (sim → host, sent once at startup):
##     {"event":"ready","nq":13,"nu":6,"joint_names":["shoulder_pan",...]}
##
##   request (host → sim):
##     {"ctrl":[6 floats], "steps": N}        # apply ctrl, mj_step N times
##     {"ee_pose":{"position":[x,y,z],
##                 "rotation":[qx,qy,qz,qw]},
##      "gripper": 0.5,
##      "steps": N}                           # solve IK in MuJoCo, then step
##     {"reset": true}                        # reset to keyframe "home"
##
##   response (sim → host):
##     {"q":[6 floats],
##      "ctrl":[6 floats],
##      "ee":{"position":[x,y,z],
##            "rotation":[qx,qy,qz,qw]},
##      "cube":[x,y,z,qw,qx,qy,qz],            # MuJoCo qpos order (w-first)
##      "ts_ns": <int>}                        # wall-clock ns at response
##
##   error (sim → host): {"error":"<msg>"}
##
## The bridge owns MuJoCo-specific IK. Rust sends robot-frame EE targets and
## normalized gripper commands; the simulator clamps the resulting actuators to
## the model's limits before stepping.
## ---------------------------------------------------------------------------

ARM_ACTUATORS = ["shoulder_pan", "shoulder_lift", "elbow_flex",
                 "wrist_flex", "wrist_roll", "gripper"]
ARM_JOINTS = ARM_ACTUATORS[:-1]
GRIPPER_ACTUATOR = "gripper"
GRIPPER_RAD_MIN = -0.17
GRIPPER_RAD_MAX = 1.75
EE_SITE = "gripperframe"
VIEWER_IDLE_SYNC_PERIOD_S = 1.0 / 30.0


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _bridge_indices(model: mujoco.MjModel) -> dict:
    arm_jids = []
    arm_actids = []
    for name in ARM_JOINTS:
        jid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, name)
        aid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_ACTUATOR, name)
        if jid < 0 or aid < 0:
            raise RuntimeError(f"missing actuator/joint '{name}'")
        arm_jids.append(jid)
        arm_actids.append(aid)

    grip_actid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_ACTUATOR, GRIPPER_ACTUATOR)
    grip_jid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, GRIPPER_ACTUATOR)
    site_id = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_SITE, EE_SITE)
    if grip_actid < 0 or grip_jid < 0:
        raise RuntimeError("missing gripper actuator/joint")
    if site_id < 0:
        raise RuntimeError(f"missing site '{EE_SITE}'")

    act_ids = list(arm_actids) + [grip_actid]
    jids = list(arm_jids) + [grip_jid]
    return {
        "act_ids": act_ids,
        "qadr": [int(model.jnt_qposadr[j]) for j in jids],
        "arm_jids": arm_jids,
        "arm_qadr": [int(model.jnt_qposadr[j]) for j in arm_jids],
        "arm_dofadr": [int(model.jnt_dofadr[j]) for j in arm_jids],
        "arm_actids": arm_actids,
        "grip_actid": grip_actid,
        "site_id": site_id,
    }


def _quat_xyzw_from_mat(mat: np.ndarray) -> list[float]:
    quat_wxyz = np.zeros(4, dtype=np.float64)
    mujoco.mju_mat2Quat(quat_wxyz, np.asarray(mat, dtype=np.float64).reshape(9))
    return [
        float(quat_wxyz[1]),
        float(quat_wxyz[2]),
        float(quat_wxyz[3]),
        float(quat_wxyz[0]),
    ]


def _mat_from_quat_xyzw(rot: list[float]) -> np.ndarray:
    quat_wxyz = np.array([rot[3], rot[0], rot[1], rot[2]], dtype=np.float64)
    norm = np.linalg.norm(quat_wxyz)
    if norm <= 1.0e-9:
        quat_wxyz[:] = [1.0, 0.0, 0.0, 0.0]
    else:
        quat_wxyz /= norm
    mat = np.zeros(9, dtype=np.float64)
    mujoco.mju_quat2Mat(mat, quat_wxyz)
    return mat.reshape(3, 3)


def _target_axis_from_pose(ee_pose: dict) -> np.ndarray | None:
    rot = ee_pose.get("rotation")
    if rot is None:
        return None
    if not isinstance(rot, list) or len(rot) != 4:
        raise ValueError("ee_pose.rotation must be [qx,qy,qz,qw]")
    return _mat_from_quat_xyzw([float(x) for x in rot])[:, 0].copy()


def _gripper_value_to_rad(value: float) -> float:
    v = min(1.0, max(0.0, float(value)))
    return GRIPPER_RAD_MIN + v * (GRIPPER_RAD_MAX - GRIPPER_RAD_MIN)


def _clamp_ctrl(model: mujoco.MjModel, act_id: int, value: float) -> float:
    if bool(model.actuator_ctrllimited[act_id]):
        lo, hi = model.actuator_ctrlrange[act_id]
        return float(np.clip(value, lo, hi))
    return float(value)


def _steps_from_msg(msg: dict) -> int:
    steps = int(msg.get("steps", 1))
    if steps < 1:
        steps = 1
    if steps > 1000:
        steps = 1000
    return steps


def ik_pose(model: mujoco.MjModel,
            data: mujoco.MjData,
            idx: dict,
            target_pos: np.ndarray,
            target_axis_world: np.ndarray | None = None,
            ori_weight: float = 1.0,
            max_iters: int = 96,
            tol: float = 1.0e-3,
            lam: float = 0.05,
            step: float = 0.4) -> tuple[np.ndarray, float]:
    """Damped least-squares IK on the five SO-101 arm joints."""
    jacp = np.zeros((3, model.nv))
    jacr = np.zeros((3, model.nv))
    last_err = np.inf

    for _ in range(max_iters):
        mujoco.mj_forward(model, data)
        site_xmat = data.site_xmat[idx["site_id"]].reshape(3, 3)
        pos_err = target_pos - data.site_xpos[idx["site_id"]]

        if target_axis_world is not None:
            cur_axis = site_xmat[:, 0]
            ori_err = np.cross(cur_axis, target_axis_world) * ori_weight
            err = np.concatenate([pos_err, ori_err])
            mujoco.mj_jacSite(model, data, jacp, jacr, idx["site_id"])
            jac = np.vstack([
                jacp[:, idx["arm_dofadr"]],
                jacr[:, idx["arm_dofadr"]] * ori_weight,
            ])
            damp = (lam ** 2) * np.eye(6)
        else:
            err = pos_err
            mujoco.mj_jacSite(model, data, jacp, jacr, idx["site_id"])
            jac = jacp[:, idx["arm_dofadr"]]
            damp = (lam ** 2) * np.eye(3)

        last_err = float(np.linalg.norm(pos_err))
        if last_err < tol and (target_axis_world is None or np.linalg.norm(err[3:]) < 5.0e-3):
            break

        dq = jac.T @ np.linalg.solve(jac @ jac.T + damp, err)
        for k, qpos_addr in enumerate(idx["arm_qadr"]):
            data.qpos[qpos_addr] += step * dq[k]
        for k, jid in enumerate(idx["arm_jids"]):
            lo, hi = model.jnt_range[jid]
            qpos_addr = idx["arm_qadr"][k]
            data.qpos[qpos_addr] = np.clip(data.qpos[qpos_addr], lo, hi)

    return np.array([data.qpos[qpos_addr] for qpos_addr in idx["arm_qadr"]]), last_err


def run_bridge(viewer_enabled: bool = False) -> None:
    """Run the stdin/stdout bridge loop.

    Reads JSON lines from stdin and writes JSON lines to stdout. All log
    output goes to stderr so it doesn't pollute the protocol stream.

    If `viewer_enabled` is True, also opens a passive 3D viewer alongside
    the bridge loop. The viewer runs on a background thread (managed by
    `mujoco.viewer.launch_passive`); we call `viewer.sync()` after each
    `mj_step` so the window mirrors the live ctrl input. If the user
    closes the window mid-session the bridge keeps running headless —
    the JSON protocol is unaffected.
    """
    model, data = load_model()

    # Optional 3D viewer. Must be opened from the main Python thread on
    # macOS (which is where we are — stdin reads happen on the main
    # thread). The viewer itself spins on its own thread and renders
    # asynchronously.
    viewer_handle = None
    if viewer_enabled:
        try:
            import mujoco.viewer as _mjviewer
        except ImportError:
            print(
                "bridge: --viewer requested but mujoco.viewer is unavailable; "
                "continuing headless",
                file=sys.stderr,
            )
        else:
            try:
                viewer_handle = _mjviewer.launch_passive(model, data)
                side_id = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_CAMERA, "side_cam")
                if side_id >= 0:
                    viewer_handle.cam.fixedcamid = side_id
                    viewer_handle.cam.type = mujoco.mjtCamera.mjCAMERA_FIXED
                print("bridge: passive viewer launched (side_cam)", file=sys.stderr)
            except Exception as e:  # pragma: no cover — best-effort fallback
                print(
                    f"bridge: viewer launch failed ({e}); continuing headless",
                    file=sys.stderr,
                )
                viewer_handle = None

    def maybe_sync_viewer() -> None:
        """Push the latest mjData snapshot to the viewer if it's alive.

        Quietly drops if the user has closed the window mid-session so the JSON
        protocol can keep running headless."""
        nonlocal viewer_handle
        if viewer_handle is None:
            return
        try:
            if viewer_handle.is_running():
                viewer_handle.sync()
            else:
                viewer_handle = None
        except Exception as e:
            print(f"bridge: viewer sync failed ({e}); detaching", file=sys.stderr)
            viewer_handle = None

    try:
        idx = _bridge_indices(model)
    except RuntimeError as e:
        print(f"bridge: {e}", file=sys.stderr)
        sys.exit(2)

    cube_jid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, "red_cube_freejoint")
    cube_qadr = int(model.jnt_qposadr[cube_jid]) if cube_jid >= 0 else -1

    home_key = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_KEY, "home")
    ik_data = mujoco.MjData(model)

    # Initialise ctrl to current home pose so the very first step doesn't
    # snap from zero.
    for k, a in enumerate(idx["act_ids"]):
        data.ctrl[a] = float(data.qpos[idx["qadr"][k]])

    mujoco.mj_forward(model, data)
    maybe_sync_viewer()

    _emit({
        "event": "ready",
        "nq": int(model.nq),
        "nu": int(model.nu),
        "joint_names": list(ARM_ACTUATORS),
    })
    print(f"bridge: ready (nq={model.nq}, nu={model.nu})", file=sys.stderr)

    def snapshot() -> dict:
        mujoco.mj_forward(model, data)
        q = [float(data.qpos[a]) for a in idx["qadr"]]
        ctrl = [float(data.ctrl[a]) for a in idx["act_ids"]]
        if cube_qadr >= 0:
            cube = [float(x) for x in data.qpos[cube_qadr:cube_qadr + 7]]
        else:
            cube = []
        site_id = idx["site_id"]
        ee = {
            "position": [float(x) for x in data.site_xpos[site_id]],
            "rotation": _quat_xyzw_from_mat(data.site_xmat[site_id]),
        }
        return {
            "q": q,
            "ctrl": ctrl,
            "ee": ee,
            "cube": cube,
            "ts_ns": time.time_ns(),
        }

    try:
        while True:
            if viewer_handle is None:
                raw = sys.stdin.readline()
            else:
                readable, _, _ = select.select(
                    [sys.stdin], [], [], VIEWER_IDLE_SYNC_PERIOD_S
                )
                if not readable:
                    maybe_sync_viewer()
                    continue
                raw = sys.stdin.readline()

            if raw == "":
                break
            raw = raw.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError as e:
                _emit({"error": f"bad json: {e}"})
                continue

            if msg.get("reset"):
                if home_key >= 0:
                    mujoco.mj_resetDataKeyframe(model, data, home_key)
                else:
                    mujoco.mj_resetData(model, data)
                for k, a in enumerate(idx["act_ids"]):
                    data.ctrl[a] = float(data.qpos[idx["qadr"][k]])
                mujoco.mj_forward(model, data)
                maybe_sync_viewer()
                _emit(snapshot())
                continue

            ee_pose = msg.get("ee_pose")
            if isinstance(ee_pose, dict):
                pos = ee_pose.get("position")
                if not isinstance(pos, list) or len(pos) != 3:
                    _emit({"error": "ee_pose.position must be [x,y,z]"})
                    continue
                try:
                    target_pos = np.array([float(x) for x in pos], dtype=np.float64)
                    target_axis = _target_axis_from_pose(ee_pose)
                except (TypeError, ValueError) as e:
                    _emit({"error": str(e)})
                    continue

                ik_data.qpos[:] = data.qpos
                ik_data.qvel[:] = 0.0
                ik_data.ctrl[:] = data.ctrl
                q_target, pos_err = ik_pose(
                    model,
                    ik_data,
                    idx,
                    target_pos,
                    target_axis_world=target_axis,
                )
                for k, a in enumerate(idx["arm_actids"]):
                    data.ctrl[a] = _clamp_ctrl(model, a, float(q_target[k]))

                if msg.get("gripper") is not None:
                    grip = _gripper_value_to_rad(float(msg["gripper"]))
                    data.ctrl[idx["grip_actid"]] = _clamp_ctrl(model, idx["grip_actid"], grip)

                for _ in range(_steps_from_msg(msg)):
                    mujoco.mj_step(model, data)

                maybe_sync_viewer()
                snap = snapshot()
                snap["ik_error"] = pos_err
                _emit(snap)
                continue

            ctrl = msg.get("ctrl")
            if not isinstance(ctrl, list) or len(ctrl) != len(ARM_ACTUATORS):
                _emit({"error": f"ctrl must be list of {len(ARM_ACTUATORS)} floats"})
                continue

            steps = _steps_from_msg(msg)

            for k, a in enumerate(idx["act_ids"]):
                data.ctrl[a] = _clamp_ctrl(model, a, float(ctrl[k]))

            for _ in range(steps):
                mujoco.mj_step(model, data)

            maybe_sync_viewer()
            _emit(snapshot())
    finally:
        if viewer_handle is not None:
            try:
                viewer_handle.close()
            except Exception:
                pass


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="mode", required=True)

    sub.add_parser("viewer", help="interactive viewer")

    pr = sub.add_parser("render", help="offscreen camera renders")
    pr.add_argument("--steps", type=int, default=200,
                    help="settling steps before render (default 200)")
    pr.add_argument("--out", type=Path, default=HERE / "renders",
                    help="output directory (default ./renders)")
    pr.add_argument("--width", type=int, default=1280)
    pr.add_argument("--height", type=int, default=720)

    sub.add_parser("smoketest", help="load model, step, print info")

    br = sub.add_parser("bridge", help="stdin/stdout JSON-line bridge for robo-agent")
    br.add_argument(
        "--viewer",
        action="store_true",
        help="also open a passive 3D viewer alongside the JSON-line loop "
             "(useful for live debugging; opens a window so don't enable "
             "on headless servers)",
    )

    args = p.parse_args()

    if args.mode == "viewer":
        run_viewer()
    elif args.mode == "render":
        run_render(args.steps, args.out, args.width, args.height)
    elif args.mode == "smoketest":
        run_smoketest()
    elif args.mode == "bridge":
        run_bridge(viewer_enabled=args.viewer)


if __name__ == "__main__":
    main()
