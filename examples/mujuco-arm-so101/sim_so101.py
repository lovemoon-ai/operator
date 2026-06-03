"""SO-101 pick-and-place MuJoCo simulation.

Four modes:
    viewer   - interactive 3D viewer (passive, mouse/keyboard control).
    render   - offscreen render of the wrist + side cameras to PNG.
    smoketest - load the model, step a few times, print key info.
    bridge   - stdin/stdout JSON-line protocol used by robo-agent's
               MujocoSo101 device. Acts as the "hardware" side of the
               teleoperation loop: takes 6 joint targets, steps the sim,
               returns joint angles + cube pose.

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
##     {"reset": true}                        # reset to keyframe "home"
##
##   response (sim → host):
##     {"q":[6 floats],
##      "cube":[x,y,z,qw,qx,qy,qz],            # MuJoCo qpos order (w-first)
##      "ts_ns": <int>}                        # wall-clock ns at response
##
##   error (sim → host): {"error":"<msg>"}
##
## Bridge is intentionally dumb: no IK, no command parsing, no safety.
## Anything that resembles "logic" lives in the Rust device.
## ---------------------------------------------------------------------------

ARM_ACTUATORS = ["shoulder_pan", "shoulder_lift", "elbow_flex",
                 "wrist_flex", "wrist_roll", "gripper"]
VIEWER_IDLE_SYNC_PERIOD_S = 1.0 / 30.0


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


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

    # Resolve actuator + joint indices once.
    act_ids = []
    qadr = []
    for name in ARM_ACTUATORS:
        a = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_ACTUATOR, name)
        j = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, name)
        if a < 0 or j < 0:
            print(f"bridge: missing actuator/joint '{name}'", file=sys.stderr)
            sys.exit(2)
        act_ids.append(a)
        qadr.append(int(model.jnt_qposadr[j]))

    cube_jid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, "red_cube_freejoint")
    cube_qadr = int(model.jnt_qposadr[cube_jid]) if cube_jid >= 0 else -1

    home_key = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_KEY, "home")

    # Initialise ctrl to current home pose so the very first step doesn't
    # snap from zero.
    for k, a in enumerate(act_ids):
        data.ctrl[a] = float(data.qpos[qadr[k]])

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
        q = [float(data.qpos[a]) for a in qadr]
        if cube_qadr >= 0:
            cube = [float(x) for x in data.qpos[cube_qadr:cube_qadr + 7]]
        else:
            cube = []
        return {
            "q": q,
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
                for k, a in enumerate(act_ids):
                    data.ctrl[a] = float(data.qpos[qadr[k]])
                mujoco.mj_forward(model, data)
                maybe_sync_viewer()
                _emit(snapshot())
                continue

            ctrl = msg.get("ctrl")
            if not isinstance(ctrl, list) or len(ctrl) != len(ARM_ACTUATORS):
                _emit({"error": f"ctrl must be list of {len(ARM_ACTUATORS)} floats"})
                continue

            steps = int(msg.get("steps", 1))
            if steps < 1:
                steps = 1
            if steps > 1000:
                steps = 1000  # safety: don't let the host stall the bridge.

            for k, a in enumerate(act_ids):
                data.ctrl[a] = float(ctrl[k])

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
