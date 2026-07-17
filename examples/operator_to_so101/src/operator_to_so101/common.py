#!/usr/bin/env python

# Copyright 2026 NVIDIA Corporation and The HuggingFace Inc. team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Shared Operator input, SO-101 IK and physical follower lifecycle."""

from __future__ import annotations

import json
import logging
import math
import sys
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Protocol
from urllib.parse import quote
from urllib.request import urlopen
from xml.etree import ElementTree

import numpy as np
from lerobot.model.kinematics import RobotKinematics
from lerobot.processor import (
    RobotProcessorPipeline,
    robot_action_observation_to_transition,
    transition_to_robot_action,
)
from lerobot.robots import RobotConfig, make_robot_from_config
from lerobot.robots.so_follower import SOFollowerConfig  # noqa: F401
from lerobot.robots.so_follower.robot_kinematic_processor import (
    EEBoundsAndSafety,
    InverseKinematicsEEToJoints,
)
from lerobot.types import RobotAction, RobotObservation
from lerobot.utils.constants import HF_LEROBOT_HOME
from lerobot.utils.robot_utils import precise_sleep

from .clutch import Clutch
from .config import OperatorControllerConfig
from .operator_source import (
    OperatorControllerFrame,
    OperatorControllerSource,
    OperatorKillRequested,
)
from .xr_controller_processor import MapOperatorXRActionToRobotAction

FPS = 30
IK_ORIENTATION_WEIGHT = 0.01
RESET_DURATION_S = 5.0
RESET_POSE_FILE = str(HF_LEROBOT_HOME / "reset_poses" / "{robot_name}" / "{robot_id}.json")
SO101_URDF_REVISION = "fda892cba81032c46c40976a48c9ceadbf40a9ca"
SO101_URDF_BASE_URL = (
    "https://raw.githubusercontent.com/TheRobotStudio/SO-ARM100/"
    f"{SO101_URDF_REVISION}/Simulation/SO101/"
)
RESET_ORIGIN_DEG: dict[str, float] = {
    "shoulder_pan": -4.0,
    "shoulder_lift": -103.0,
    "elbow_flex": 97.0,
    "wrist_flex": 78.0,
    "wrist_roll": -65.0,
    "gripper": 0.0,
}


class LoopConfig(Protocol):
    teleop: OperatorControllerConfig
    robot: RobotConfig
    reset_to_origin: bool
    reset_duration: float


@dataclass(frozen=True)
class Device:
    compute: Callable[[RobotObservation], RobotAction | None]
    preflight: Callable[[], None]
    startup: Callable[[], None]
    cleanup: Callable[[], None]
    last_frame: Callable[[], OperatorControllerFrame]


def hold_action(obs: RobotObservation, motor_names: list[str]) -> dict[str, float]:
    return {f"{name}.pos": float(obs[f"{name}.pos"]) for name in motor_names}


class HoldLatch:
    """Hold one fixed pose while idle instead of ratcheting with measured sag."""

    def __init__(self, motor_names: list[str]):
        self._motor_names = motor_names
        self._held: dict[str, float] | None = None

    def resolve(self, action: RobotAction | None, obs: RobotObservation) -> RobotAction:
        if action is not None:
            self._held = None
            return action
        if self._held is None:
            self._held = hold_action(obs, self._motor_names)
        return self._held


def slew(
    robot,
    motor_names: list[str],
    target: dict[str, float],
    duration_s: float,
) -> None:
    obs = robot.get_observation()
    start = {name: float(obs[f"{name}.pos"]) for name in motor_names}
    n_steps = max(1, int(duration_s * FPS))
    for step in range(1, n_steps + 1):
        alpha = step / n_steps
        action = {
            f"{name}.pos": start[name] + alpha * (target[name] - start[name])
            for name in motor_names
        }
        robot.send_action(action)
        precise_sleep(1.0 / FPS)


def _download_so101_file(relative_path: PurePosixPath, dest_dir: Path) -> None:
    destination = dest_dir.joinpath(*relative_path.parts)
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(f"{destination.name}.part")
    url = f"{SO101_URDF_BASE_URL}{quote(relative_path.as_posix())}"
    try:
        with urlopen(url, timeout=60) as response, partial.open("wb") as output:  # noqa: S310
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        partial.replace(destination)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise


def _urdf_mesh_paths(urdf_path: Path) -> list[PurePosixPath]:
    root = ElementTree.fromstring(urdf_path.read_bytes())
    paths: set[PurePosixPath] = set()
    for mesh in root.iter("mesh"):
        filename = mesh.get("filename")
        if not filename:
            raise ValueError(f"mesh without filename in {urdf_path}")
        path = PurePosixPath(filename)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"unsafe mesh path in {urdf_path}: {filename!r}")
        paths.add(path)
    return sorted(paths, key=str)


def _ensure_so101_urdf() -> str:
    dest_dir = HF_LEROBOT_HOME / "robot-urdfs" / "so101"
    urdf_path = dest_dir / "so101_new_calib.urdf"
    marker = dest_dir / ".sync_complete"
    if (
        urdf_path.is_file()
        and marker.exists()
        and marker.read_text().strip() == SO101_URDF_REVISION
    ):
        return str(urdf_path)

    dest_dir.mkdir(parents=True, exist_ok=True)
    _download_so101_file(PurePosixPath(urdf_path.name), dest_dir)
    for mesh_path in _urdf_mesh_paths(urdf_path):
        _download_so101_file(mesh_path, dest_dir)
    marker.write_text(f"{SO101_URDF_REVISION}\n")
    return str(urdf_path)


def _load_reset_target(reset_pose_file: Path, motor_names: list[str]) -> dict[str, float]:
    if reset_pose_file.exists():
        saved = json.loads(reset_pose_file.read_text())
        return {
            name: float(saved.get(name, RESET_ORIGIN_DEG.get(name, 0.0))) for name in motor_names
        }
    return {name: RESET_ORIGIN_DEG.get(name, 0.0) for name in motor_names}


def setup_operator_controller(cfg: LoopConfig, robot, motor_names: list[str]) -> Device:
    kinematics = RobotKinematics(
        urdf_path=_ensure_so101_urdf(),
        target_frame_name="gripper_frame_link",
        joint_names=motor_names,
    )
    source = OperatorControllerSource(cfg.teleop)
    processor = RobotProcessorPipeline[tuple[RobotAction, RobotObservation], RobotAction](
        steps=[
            MapOperatorXRActionToRobotAction(),
            EEBoundsAndSafety(
                end_effector_bounds={"min": [-1.0, -1.0, 0.0], "max": [1.0, 1.0, 1.0]},
                max_ee_step_m=cfg.teleop.max_ee_step_m,
                raise_on_jump=False,
            ),
            InverseKinematicsEEToJoints(
                kinematics=kinematics,
                motor_names=motor_names,
                initial_guess_current_joints=False,
                orientation_weight=IK_ORIENTATION_WEIGHT,
            ),
        ],
        to_transition=robot_action_observation_to_transition,
        to_output=transition_to_robot_action,
    )
    clutch: Clutch | None = None
    prev_engaged = False

    def measured_fk(obs: RobotObservation) -> np.ndarray:
        joints = np.asarray([float(obs[f"{name}.pos"]) for name in motor_names], dtype=float)
        return kinematics.forward_kinematics(joints)

    def preflight() -> None:
        source.connect()
        print(
            f"Waiting for fresh {cfg.teleop.hand_side} controller + CTRL on "
            f"{cfg.teleop.socket_path}..."
        )
        source.wait_for_tracking()
        print("Operator tracking is live.")

    def startup() -> None:
        nonlocal clutch, prev_engaged
        if cfg.reset_to_origin:
            reset_pose_file = Path(RESET_POSE_FILE.format(robot_name=robot.name, robot_id=robot.id))
            target = _load_reset_target(reset_pose_file, motor_names)
            print(f"Resetting follower over {cfg.reset_duration:.1f}s...")
            slew(robot, motor_names, target, cfg.reset_duration)

        obs0 = robot.get_observation()
        clutch = Clutch(measured_fk(obs0))
        processor.reset()
        prev_engaged = False
        source.disarm()
        prompt = "Press A/X once to arm, then hold Grip and move. B/Y re-anchors."
        if not cfg.teleop.require_run_toggle:
            prompt = "Hold Grip and move. B/Y re-anchors."
        print(f"Follower ready. {prompt}")

    def compute(robot_obs: RobotObservation) -> RobotAction | None:
        nonlocal clutch, prev_engaged
        if clutch is None:
            raise RuntimeError("compute() called before startup()")
        frame = source.read()
        if frame.kill:
            raise OperatorKillRequested("Operator requested stop")
        if frame.reset:
            clutch = Clutch(measured_fk(robot_obs))
            processor.reset()
            prev_engaged = False
            return None
        if not frame.engaged:
            prev_engaged = False
            return None
        if not prev_engaged:
            clutch.engage(
                frame.grip_pos,
                frame.grip_quat,
                measured_base_T_ee=measured_fk(robot_obs),
            )
            processor.reset()
        prev_engaged = True
        ee_pos, ee_quat = clutch.rebase(frame.grip_pos, frame.grip_quat)
        return processor(
            (
                {
                    "ee_pose": np.concatenate([ee_pos, ee_quat]).astype(np.float32),
                    "closedness": frame.trigger,
                },
                robot_obs,
            )
        )

    return Device(
        compute=compute,
        preflight=preflight,
        startup=startup,
        cleanup=source.close,
        last_frame=lambda: source.last_frame,
    )


def build_device(cfg: LoopConfig):
    supported = {"so100_follower", "so101_follower"}
    if cfg.robot.type not in supported:
        raise ValueError(
            f"operator_to_so101 supports {sorted(supported)}, got --robot.type={cfg.robot.type}"
        )
    if not getattr(cfg.robot, "use_degrees", True):
        raise ValueError("--robot.use_degrees=false is unsupported: SO-101 IK uses degrees")
    max_relative_target = getattr(cfg.robot, "max_relative_target", None)
    if max_relative_target is None:
        raise ValueError(
            "--robot.max_relative_target is required for a physical follower "
            "(start with 5 degrees/units per command)"
        )
    limits = (
        max_relative_target.values()
        if isinstance(max_relative_target, dict)
        else (max_relative_target,)
    )
    if any(not math.isfinite(float(limit)) or float(limit) <= 0.0 for limit in limits):
        raise ValueError("--robot.max_relative_target limits must all be positive")

    robot = make_robot_from_config(cfg.robot)
    motor_names = [
        key.removesuffix(".pos") for key in robot.action_features if key.endswith(".pos")
    ]
    if isinstance(max_relative_target, dict) and set(max_relative_target) != set(motor_names):
        raise ValueError(
            f"--robot.max_relative_target dictionary keys must exactly match {motor_names}"
        )
    device = setup_operator_controller(cfg, robot, motor_names)
    try:
        # Wait for the headset before opening the physical serial device. The
        # URDF download and input timeout therefore cannot leave torque enabled.
        device.preflight()
        robot.connect()
        device.startup()
    except BaseException:
        with suppress(Exception):
            device.cleanup()
        _rollback_robot_connect(robot)
        raise
    return robot, device, motor_names


def _rollback_robot_connect(robot) -> None:
    """Best-effort torque/port cleanup even after a partial ``connect()``."""

    with suppress(Exception):
        robot.disconnect()
    bus = getattr(robot, "bus", None)
    if bus is not None and getattr(bus, "is_connected", False):
        with suppress(Exception):
            bus.disconnect(getattr(robot.config, "disable_torque_on_disconnect", True))
    for camera in getattr(robot, "cameras", {}).values():
        if getattr(camera, "is_connected", False):
            with suppress(Exception):
                camera.disconnect()


def init_keyboard_listener():
    if not (sys.stdin is not None and sys.stdin.isatty()):
        from lerobot.utils.keyboard_input import init_keyboard_listener as upstream_listener

        return upstream_listener()

    from lerobot.utils.keyboard_input import TerminalKeyListener, apply_recording_control

    events = {"exit_early": False, "rerecord_episode": False, "stop_recording": False}

    def on_key(name: str) -> None:
        key = name.lower()
        if key in ("right", "n"):
            apply_recording_control("right", events)
        elif key in ("left", "r"):
            apply_recording_control("left", events)
        elif key in ("esc", "q"):
            apply_recording_control("esc", events)

    listener = TerminalKeyListener(on_key)
    listener.start()
    logging.info("Right/n=end episode, Left/r=re-record, Esc/q=stop")
    return listener, events
