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

"""Map a clutch-rebased XR pose into LeRobot's SO-101 IK input contract."""

from __future__ import annotations

from dataclasses import dataclass

from lerobot.configs.types import FeatureType, PipelineFeatureType, PolicyFeature
from lerobot.processor import ProcessorStepRegistry, RobotActionProcessorStep
from lerobot.types import RobotAction

from .rotation import Rotation

_GRIPPER_MOTOR_SCALE = 100.0


@ProcessorStepRegistry.register("map_operator_xr_action_to_robot_action")
@dataclass
class MapOperatorXRActionToRobotAction(RobotActionProcessorStep):
    """Convert ``ee_pose`` + trigger closedness to EE pose fields and gripper units."""

    def action(self, action: RobotAction) -> RobotAction:
        ee_pose = action.pop("ee_pose")
        closedness = float(action.pop("closedness"))
        action["ee.x"] = float(ee_pose[0])
        action["ee.y"] = float(ee_pose[1])
        action["ee.z"] = float(ee_pose[2])
        rotvec = Rotation.from_quat(ee_pose[3:7]).as_rotvec()
        action["ee.wx"] = float(rotvec[0])
        action["ee.wy"] = float(rotvec[1])
        action["ee.wz"] = float(rotvec[2])
        action["ee.gripper_pos"] = (1.0 - closedness) * _GRIPPER_MOTOR_SCALE
        return action

    def transform_features(
        self, features: dict[PipelineFeatureType, dict[str, PolicyFeature]]
    ) -> dict[PipelineFeatureType, dict[str, PolicyFeature]]:
        for feature in ("ee_pose", "closedness"):
            features[PipelineFeatureType.ACTION].pop(feature, None)
        for feature in (
            "ee.x",
            "ee.y",
            "ee.z",
            "ee.wx",
            "ee.wy",
            "ee.wz",
            "ee.gripper_pos",
        ):
            features[PipelineFeatureType.ACTION][feature] = PolicyFeature(
                type=FeatureType.ACTION, shape=(1,)
            )
        return features
