#!/usr/bin/env python

# Copyright 2025 The HuggingFace Inc. team. All rights reserved.
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

"""Small XYZW rotation helper adapted from ``lerobot.utils.rotation``."""

from __future__ import annotations

import numpy as np


class Rotation:
    def __init__(self, quat: np.ndarray) -> None:
        self._quat = np.asarray(quat, dtype=float)
        norm = float(np.linalg.norm(self._quat))
        if norm <= 1e-12:
            raise ValueError("rotation quaternion must be non-zero")
        self._quat /= norm

    @classmethod
    def from_quat(cls, quat: np.ndarray) -> Rotation:
        return cls(quat)

    @classmethod
    def from_matrix(cls, matrix: np.ndarray) -> Rotation:
        matrix = np.asarray(matrix, dtype=float)
        trace = float(np.trace(matrix))
        if trace > 0.0:
            s = np.sqrt(trace + 1.0) * 2.0
            quat = np.asarray(
                [
                    (matrix[2, 1] - matrix[1, 2]) / s,
                    (matrix[0, 2] - matrix[2, 0]) / s,
                    (matrix[1, 0] - matrix[0, 1]) / s,
                    0.25 * s,
                ]
            )
        else:
            axis = int(np.argmax(np.diag(matrix)))
            if axis == 0:
                s = np.sqrt(1.0 + matrix[0, 0] - matrix[1, 1] - matrix[2, 2]) * 2.0
                quat = np.asarray(
                    [
                        0.25 * s,
                        (matrix[0, 1] + matrix[1, 0]) / s,
                        (matrix[0, 2] + matrix[2, 0]) / s,
                        (matrix[2, 1] - matrix[1, 2]) / s,
                    ]
                )
            elif axis == 1:
                s = np.sqrt(1.0 + matrix[1, 1] - matrix[0, 0] - matrix[2, 2]) * 2.0
                quat = np.asarray(
                    [
                        (matrix[0, 1] + matrix[1, 0]) / s,
                        0.25 * s,
                        (matrix[1, 2] + matrix[2, 1]) / s,
                        (matrix[0, 2] - matrix[2, 0]) / s,
                    ]
                )
            else:
                s = np.sqrt(1.0 + matrix[2, 2] - matrix[0, 0] - matrix[1, 1]) * 2.0
                quat = np.asarray(
                    [
                        (matrix[0, 2] + matrix[2, 0]) / s,
                        (matrix[1, 2] + matrix[2, 1]) / s,
                        0.25 * s,
                        (matrix[1, 0] - matrix[0, 1]) / s,
                    ]
                )
        return cls(quat)

    def as_quat(self) -> np.ndarray:
        return self._quat.copy()

    def as_rotvec(self) -> np.ndarray:
        x, y, z, w = self._quat
        if w < 0.0:
            x, y, z, w = -x, -y, -z, -w
        angle = 2.0 * np.arccos(np.clip(w, -1.0, 1.0))
        sine = np.sqrt(max(0.0, 1.0 - w * w))
        if sine < 1e-8:
            return 2.0 * np.asarray([x, y, z])
        return angle * np.asarray([x, y, z]) / sine

    def inv(self) -> Rotation:
        x, y, z, w = self._quat
        return Rotation(np.asarray([-x, -y, -z, w]))

    def __mul__(self, other: Rotation) -> Rotation:
        if not isinstance(other, Rotation):
            return NotImplemented
        x1, y1, z1, w1 = other._quat
        x2, y2, z2, w2 = self._quat
        return Rotation(
            np.asarray(
                [
                    w2 * x1 + x2 * w1 + y2 * z1 - z2 * y1,
                    w2 * y1 - x2 * z1 + y2 * w1 + z2 * x1,
                    w2 * z1 + x2 * y1 - y2 * x1 + z2 * w1,
                    w2 * w1 - x2 * x1 - y2 * y1 - z2 * z1,
                ]
            )
        )
