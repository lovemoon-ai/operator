"""Blueprint for the Light-O1 G1 scene and MuJoCo -> XR pose conversion.

Everything the headset shows is declared here with generic Blueprint
primitives: the host-served G1 asset, a floor grid, lighting, a controller
label with the current prompt/status, and system-menu rows that select a
prompt and start/stop/replay motion. No XR script or primitive is specific to
this example.
"""
from __future__ import annotations

import numpy as np

from pyoperator import Blueprint, BlueprintComponent, BlueprintTransform

# MuJoCo Z-up/X-forward robot frame to the Blueprint asset's XR Y-up frame.
ROBOT_TO_XR = np.array([[0., -1., 0.], [0., 0., 1.], [-1., 0., 0.]])
# 180 degrees about XR up (xyzw): the G1 starts facing the wearer instead of away.
FACE_USER_ROTATION = (0.0, 1.0, 0.0, 0.0)
IDENTITY_ROTATION = (0.0, 0.0, 0.0, 1.0)

# (component id, action, title, off text, on text, value binding, available binding)
MENU_ROWS = (
    ("motion", "motion.toggle", "Light-O1 motion", "Generate", "Stop", "motion.active", "motion.available"),
    ("prompt_next", "prompt.next", "Prompt", "Next >", "Next >", "prompt.cycle", None),
    ("prompt_prev", "prompt.prev", "Prompt", "< Prev", "< Prev", "prompt.cycle", None),
    ("replay", "motion.replay", "Last motion", "Replay", "Stop", "motion.active", "motion.replay_available"),
)
MENU_ACTIONS = frozenset(row[1] for row in MENU_ROWS)


def quaternion_to_matrix(wxyz) -> np.ndarray:
    w, x, y, z = (float(v) for v in np.asarray(wxyz, dtype=float) / np.linalg.norm(wxyz))
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def matrix_to_quaternion_xyzw(matrix) -> np.ndarray:
    m = np.asarray(matrix, dtype=float)
    trace = m[0, 0] + m[1, 1] + m[2, 2]
    if trace > 0:
        s = np.sqrt(trace + 1.0) * 2
        q = np.array([(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s])
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = np.array([0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s])
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = np.array([(m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s])
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = np.array([(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s])
    return q / np.linalg.norm(q)


def base_pose_to_xr(position, quaternion_wxyz) -> list[float]:
    """MuJoCo floating base -> Blueprint ``[x, y, z, qx, qy, qz, qw]`` in XR Y-up."""
    rotation = ROBOT_TO_XR @ quaternion_to_matrix(quaternion_wxyz) @ ROBOT_TO_XR.T
    return [*(ROBOT_TO_XR @ np.asarray(position, dtype=float)).tolist(),
            *matrix_to_quaternion_xyzw(rotation).tolist()]


def frame_to_state(frame) -> tuple[list[float], list[float]]:
    """Split a recorded frame into Blueprint joint positions and XR base pose."""
    array = np.asarray(frame, dtype=float)
    return array[7:].tolist(), base_pose_to_xr(array[:3], array[3:7])


def blueprint(asset, asset_port: int, *, distance: float = 2.5, face_user: bool = True) -> Blueprint:
    if not np.isfinite(distance) or distance <= 0:
        raise ValueError("distance must be finite and positive")
    rotation = FACE_USER_ROTATION if face_user else IDENTITY_ROTATION
    components = [
        BlueprintComponent.ground_grid(
            "ground", placement_target="g1", visible_binding="g1.visible",
            transform=BlueprintTransform(position=(0, 0.002, -distance)),
            properties={"settings_label": "Ground grid", "size": 8.0, "spacing": 0.5},
        ),
        BlueprintComponent.model_lighting(
            "lighting", visible_binding="g1.visible",
            properties={"settings_label": "Robot lighting", "key_energy": 1.6, "fill_energy": 0.6},
        ),
        asset.component(
            "g1", asset_port=asset_port,
            joint_positions_binding="g1.joints", base_pose_binding="g1.base",
            sample_binding="g1.sample", visible_binding="g1.visible",
            transform=BlueprintTransform(position=(0, 0, -distance), rotation=rotation),
        ),
        BlueprintComponent.label(
            "prompt_status", anchor="left_controller", text_binding="ui.text",
            transform=BlueprintTransform(position=(0, 0.09, 0)),
            properties={"settings_label": "Prompt and motion status", "font_size": 22},
        ),
    ]
    for component_id, action, title, off, on, value_binding, available_binding in MENU_ROWS:
        components.append(BlueprintComponent.menu_item(
            component_id, title=title, action=action, value_binding=value_binding,
            available_binding=available_binding, locked_text=off, unlocked_text=on,
            properties={"settings_label": f"Menu: {title} ({off})"},
        ))
    return Blueprint(blueprint_id="example.light_o1", components=tuple(components))
