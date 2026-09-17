#!/usr/bin/env python3
"""Minimal pyoperator client for the MuJoCo G1-D dual-arm sandbox."""

from __future__ import annotations

import argparse
from contextlib import nullcontext
import time

from g1d_sim import DualArmRetargeter, G1DMujocoRobot

from pyoperator import BridgeConfig, XrSession


def _pressed(frame, side: str, name: str) -> bool:
    controller = getattr(frame.controllers, side)
    return controller is not None and controller.input.value(name) >= 0.5


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headless", action="store_true", help="run without the MuJoCo viewer")
    parser.add_argument("--translation-scale", type=float, default=1.0)
    parser.add_argument("--max-joint-velocity", type=float, default=2.5)
    parser.add_argument(
        "--no-gravity-compensation",
        action="store_true",
        help="disable RNEA-equivalent bias torque for regression experiments",
    )
    parser.add_argument(
        "--discovery-target",
        action="append",
        default=[],
        help="optional headset subnet broadcast/unicast address",
    )
    args = parser.parse_args()

    robot = G1DMujocoRobot(
        gravity_compensation=not args.no_gravity_compensation,
        max_joint_velocity_rad_s=args.max_joint_velocity,
    )
    robot.connect()
    retargeter = DualArmRetargeter(translation_scale=args.translation_scale)
    config = BridgeConfig(
        name="unitree-g1d-mujoco",
        discovery_unicast_targets=tuple(args.discovery_target),
    )

    viewer_context = nullcontext(None)
    if not args.headless:
        import mujoco.viewer

        viewer_context = mujoco.viewer.launch_passive(robot.model, robot.data)

    last_frame_id = 0
    last_step_at = time.monotonic()
    last_report_at = last_step_at
    x_was_pressed = False
    y_was_pressed = False
    command_active = False
    try:
        with viewer_context as viewer, XrSession(config) as session:
            print("G1-D MuJoCo ready: hold either Grip to move that arm; X=ready, Y=initial")
            while session.is_running and (viewer is None or viewer.is_running()):
                frame = session.wait_next(last_frame_id, timeout=0.01)
                now = time.monotonic()
                dt = min(now - last_step_at, 0.05)
                robot.advance(dt)
                last_step_at = now
                if frame is not None:
                    last_frame_id = frame.frame_id
                    x_pressed = _pressed(frame, "left", "ax_button")
                    y_pressed = _pressed(frame, "left", "by_button")
                    if x_pressed and not x_was_pressed:
                        robot.set_posture("ready")
                        retargeter.reset()
                    if y_pressed and not y_was_pressed:
                        robot.set_posture("initial")
                        retargeter.reset()
                    x_was_pressed = x_pressed
                    y_was_pressed = y_pressed

                    target = retargeter.retarget(frame, robot.read_state())
                    if target is None:
                        if command_active:
                            robot.stop("Grip released")
                        command_active = False
                    else:
                        failed = robot.write(target, dt=max(dt, 1.0 / 120.0))
                        for side in failed:
                            # The arm held its position while the controller
                            # kept moving; re-anchor so the target resumes
                            # from the arm's actual pose instead of chasing a
                            # runaway reference.
                            retargeter.release(side)
                        command_active = True
                if viewer is not None:
                    viewer.sync()
                if now - last_report_at >= 1.0:
                    state = robot.read_state()
                    left = state.ee_poses["left_end_effector"].position
                    right = state.ee_poses["right_end_effector"].position
                    print(
                        f"frames={last_frame_id} active={command_active} "
                        f"max_dq={robot.max_arm_speed():.3f} "
                        f"left={tuple(round(v, 3) for v in left)} "
                        f"right={tuple(round(v, 3) for v in right)}"
                    )
                    last_report_at = now
    except KeyboardInterrupt:
        print("stopping G1-D MuJoCo teleoperation")
    finally:
        robot.stop("client exit")
        robot.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
