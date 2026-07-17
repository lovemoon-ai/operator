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

"""Save the current follower joint pose as this example's startup reset pose."""

import argparse
import json
from pathlib import Path

from lerobot.robots.so_follower import SO100Follower, SO100FollowerConfig

from .common import RESET_POSE_FILE


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="/dev/ttyACM0")
    parser.add_argument("--id", default="so101_follower_arm")
    args = parser.parse_args()

    robot = SO100Follower(SO100FollowerConfig(port=args.port, id=args.id, use_degrees=True))
    robot.connect()
    try:
        observation = robot.get_observation()
        pose = {name: float(observation[f"{name}.pos"]) for name in robot.bus.motors}
    finally:
        robot.disconnect()

    path = Path(RESET_POSE_FILE.format(robot_name=robot.name, robot_id=robot.id))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(pose, indent=2))
    print(f"Saved reset pose to {path}")


if __name__ == "__main__":
    main()
