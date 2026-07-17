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

"""Engage-relative position and orientation clutch adapted from LeRobot."""

from __future__ import annotations

import numpy as np

from .rotation import Rotation


class Clutch:
    """Map controller deltas onto the measured end-effector pose without jumps."""

    def __init__(self, home_base_T_ee: np.ndarray):  # noqa: N803
        home = np.asarray(home_base_T_ee, dtype=float)
        self._last_commanded_pos = home[:3, 3].copy()
        self._last_commanded_rot = Rotation.from_matrix(home[:3, :3])
        self._home_pos = self._last_commanded_pos.copy()
        self._home_rot = self._last_commanded_rot
        self._origin_pos = np.zeros(3, dtype=float)
        self._origin_rot = Rotation.from_quat(np.array([0.0, 0.0, 0.0, 1.0]))

    def engage(
        self,
        grip_pos: np.ndarray,
        grip_quat: np.ndarray,
        measured_base_T_ee: np.ndarray | None = None,  # noqa: N803
    ) -> None:
        if measured_base_T_ee is not None:
            self._home_pos = np.asarray(measured_base_T_ee, dtype=float)[:3, 3].copy()
        else:
            self._home_pos = self._last_commanded_pos.copy()
        self._home_rot = self._last_commanded_rot
        self._origin_pos = np.asarray(grip_pos, dtype=float).copy()
        self._origin_rot = Rotation.from_quat(np.asarray(grip_quat, dtype=float))

    def rebase(self, grip_pos: np.ndarray, grip_quat: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        pos = self._home_pos + (np.asarray(grip_pos, dtype=float) - self._origin_pos)
        rot_ctrl = Rotation.from_quat(np.asarray(grip_quat, dtype=float))
        rot = (rot_ctrl * self._origin_rot.inv()) * self._home_rot
        self._last_commanded_pos = pos.copy()
        self._last_commanded_rot = rot
        return pos, rot.as_quat()
