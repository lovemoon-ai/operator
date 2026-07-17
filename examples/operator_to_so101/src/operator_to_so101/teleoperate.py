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

"""Teleoperate a real SO-101 follower from Operator XR through LeRobot."""

import time
from dataclasses import dataclass, field

from lerobot.configs import parser
from lerobot.robots import RobotConfig
from lerobot.robots.so_follower import SOFollowerConfig  # noqa: F401
from lerobot.utils.robot_utils import precise_sleep

from .common import FPS, RESET_DURATION_S, HoldLatch, build_device
from .config import OperatorControllerConfig
from .operator_source import OperatorKillRequested


@dataclass
class TeleoperateConfig:
    robot: RobotConfig
    teleop: OperatorControllerConfig = field(default_factory=OperatorControllerConfig)
    reset_to_origin: bool = True
    reset_duration: float = RESET_DURATION_S


@parser.wrap()
def teleoperate(cfg: TeleoperateConfig) -> None:
    robot, device, motor_names = build_device(cfg)
    hold = HoldLatch(motor_names)
    try:
        while True:
            started = time.perf_counter()
            observation = robot.get_observation()
            action = hold.resolve(device.compute(observation), observation)
            robot.send_action(action)
            precise_sleep(max(1.0 / FPS - (time.perf_counter() - started), 0.0))
    except OperatorKillRequested as exc:
        print(f"Stopping: {exc}")
    except KeyboardInterrupt:
        pass
    finally:
        try:
            device.cleanup()
        finally:
            robot.disconnect()


def main() -> None:
    teleoperate()


if __name__ == "__main__":
    main()
