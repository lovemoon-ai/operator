"""Godot/OpenXR to Isaac right-handed coordinate conversion."""

from __future__ import annotations

import math

from .model import ControllerSample, JointSample, JointSetSample, Pose

# [x_i, y_i, z_i] = [-z_g, -x_g, y_g]
_C = ((0.0, 0.0, -1.0), (-1.0, 0.0, 0.0), (0.0, 1.0, 0.0))


def _mul(
    a: tuple[tuple[float, ...], ...], b: tuple[tuple[float, ...], ...]
) -> tuple[tuple[float, ...], ...]:
    return tuple(
        tuple(sum(a[i][k] * b[k][j] for k in range(len(b))) for j in range(len(b[0])))
        for i in range(len(a))
    )


def _transpose(a: tuple[tuple[float, ...], ...]) -> tuple[tuple[float, ...], ...]:
    return tuple(tuple(row[i] for row in a) for i in range(len(a[0])))


def _quat_to_matrix(q: tuple[float, float, float, float]) -> tuple[tuple[float, ...], ...]:
    x, y, z, w = q
    norm = math.sqrt(x * x + y * y + z * z + w * w)
    if norm == 0.0:
        return ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))
    x, y, z, w = x / norm, y / norm, z / norm, w / norm
    return (
        (1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)),
        (2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)),
        (2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)),
    )


def _matrix_to_quat(m: tuple[tuple[float, ...], ...]) -> tuple[float, float, float, float]:
    trace = m[0][0] + m[1][1] + m[2][2]
    if trace > 0.0:
        s = math.sqrt(trace + 1.0) * 2
        q = ((m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s, 0.25 * s)
    elif m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        s = math.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2
        q = (0.25 * s, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s, (m[2][1] - m[1][2]) / s)
    elif m[1][1] > m[2][2]:
        s = math.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2
        q = ((m[0][1] + m[1][0]) / s, 0.25 * s, (m[1][2] + m[2][1]) / s, (m[0][2] - m[2][0]) / s)
    else:
        s = math.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2
        q = ((m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, 0.25 * s, (m[1][0] - m[0][1]) / s)
    norm = math.sqrt(sum(value * value for value in q))
    return tuple(value / norm for value in q)  # type: ignore[return-value]


def godot_to_isaac_pose(pose: Pose) -> Pose:
    x, y, z = pose.position
    rotation = _mul(_mul(_C, _quat_to_matrix(pose.orientation_xyzw)), _transpose(_C))
    return Pose(pose.valid, (-z, -x, y), _matrix_to_quat(rotation))


def godot_to_isaac(value: Pose | ControllerSample | JointSetSample):
    if isinstance(value, Pose):
        return godot_to_isaac_pose(value)
    if isinstance(value, ControllerSample):
        return ControllerSample(
            godot_to_isaac_pose(value.grip),
            godot_to_isaac_pose(value.aim),
            value.primary,
            value.secondary,
            value.thumb_click,
            value.menu,
            value.thumb_x,
            value.thumb_y,
            value.squeeze,
            value.trigger,
        )
    if isinstance(value, JointSetSample):
        return JointSetSample(
            tuple(JointSample(godot_to_isaac_pose(j.pose), j.radius) for j in value.joints)
        )
    raise TypeError(f"cannot transform {type(value).__name__}")
