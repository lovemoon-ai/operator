"""Real official SONIC controller benchmark. Numerical inputs are NOT XR coverage."""
import argparse
import json
import time
import numpy as np
from operator_xr import BodyState, ControllerInput, ControllerPair, ControllerState, HandPair, Joint, Pose, XrFrame
from .controller import add_arguments, SonicController, yaw
from .pico_input import extract_pico_sample


def numerical_input(step, motion):
    # A scripted arithmetic reference for host policy/planner/physics timing.
    # It never opens an XR socket and must not be used as headset acceptance.
    t = step * .02
    positions = {0:(0,1,0),12:(0,1.5,0),22:(-.3,1.2,-.3),23:(.3,1.2,-.3)}
    if motion == "wave" and step > 50:
        positions[22] = (-.3, 1.2 + .04 * (1 - np.cos(np.pi*t)), -.3)
    joints = tuple(Joint(joint=i,flags=15,tracked=True,
        pose=Pose(valid=True,position=positions.get(i,(0,1,0)))) for i in range(24))
    left, right = {}, {}
    if 1 <= step < 4:
        left.update(ax_button=1.,by_button=1.); right.update(ax_button=1.,by_button=1.)
    if 50 <= step < 55: left["primary_click"] = 1.
    if motion in ("walk","turn"):
        if step >= 100: left["primary_y"] = .6
        if motion == "turn" and step >= 150: right["primary_x"] = .3
    timestamp = 1 + step * 20_000_000
    return XrFrame(1,step+1,timestamp,"openxr_stage",None,
        ControllerPair(ControllerState(pose=Pose(valid=True),input=ControllerInput(values=left)),
                       ControllerState(pose=Pose(valid=True),input=ControllerInput(values=right))),
        HandPair(),BodyState(active=True,sample_timestamp_ns=timestamp,joint_set="pico_bd_24",joints=joints),())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_arguments(parser)
    parser.add_argument("--steps",type=int,default=1000)
    parser.add_argument("--motion",choices=("standing","wave","walk","turn"),default="walk")
    parser.add_argument("--realtime",action="store_true",help="Pace at 50 Hz and exercise the live planner worker")
    args = parser.parse_args()
    if args.steps < 1: parser.error("steps must be positive")
    args.scale = 1.
    args.synchronous_planner = not args.realtime
    controller = SonicController(args)
    times, heights, modes = [], [], set()
    started = time.monotonic()
    try:
        for step in range(args.steps):
            frame = numerical_input(step,args.motion)
            tick = time.monotonic()
            now = tick if args.realtime else step * controller.dt
            controller.control_tick(frame,extract_pico_sample(frame),now)
            times.append((time.monotonic()-tick)*1000)
            heights.append(float(controller.simulation.data.qpos[2]))
            modes.add(controller.controls.mode.name)
            if args.realtime:
                remaining = controller.dt - (time.monotonic()-tick)
                if remaining > 0: time.sleep(remaining)
        report = {
            "controller":"sonic_v1_1_unified_controls", "device":args.device, "motion":args.motion,
            "realtime":args.realtime, "steps":args.steps, "modes":sorted(modes),
            "simulated_seconds":float(controller.simulation.data.time),
            "wall_seconds":time.monotonic()-started,
            "tick_ms_p95":float(np.percentile(times,95)), "tick_ms_max":max(times),
            "planner_model_calls":controller.planner.calls,
            "pelvis_height_min_m":min(heights),
            "final_base_xyz":controller.simulation.data.qpos[:3].tolist(),
            "final_base_yaw_rad":float(yaw(controller.simulation.data.qpos[3:7])),
            "command_heading":controller.controls.heading,
            "body_dof":29, "hand_dof":14,
        }
        print(json.dumps(report,indent=2),flush=True)
        if min(heights) < .4: raise SystemExit("Closed-loop check failed: G1 fell")
    finally:
        controller.close()


if __name__ == "__main__":
    main()
