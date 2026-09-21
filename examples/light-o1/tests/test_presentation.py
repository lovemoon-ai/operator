"""Pose conversion and the generic-primitive Blueprint for the G1 scene."""
import numpy as np
import pytest

from light_o1_vr.presentation import (
    FACE_USER_ROTATION, MENU_ROWS, ROBOT_TO_XR, base_pose_to_xr, blueprint, frame_to_state,
    matrix_to_quaternion_xyzw, quaternion_to_matrix,
)
from fakes import JOINT_NAMES, blueprint_for_tests


def rotation_about(axis, angle):
    axis = np.asarray(axis, dtype=float) / np.linalg.norm(axis)
    return np.concatenate(([np.cos(angle / 2)], np.sin(angle / 2) * axis))  # wxyz


def test_quaternion_matrix_round_trip_matches_mujoco_when_available():
    rng = np.random.default_rng(0)
    for _ in range(50):
        q = rng.normal(size=4)
        q /= np.linalg.norm(q)
        matrix = quaternion_to_matrix(q)
        assert np.allclose(matrix @ matrix.T, np.eye(3)) and np.linalg.det(matrix) == pytest.approx(1)
        back = matrix_to_quaternion_xyzw(matrix)
        expected = q[[1, 2, 3, 0]]
        assert np.allclose(back, expected) or np.allclose(back, -expected)
    mujoco = pytest.importorskip("mujoco")
    for _ in range(20):
        q = rng.normal(size=4)
        q /= np.linalg.norm(q)
        reference = np.empty(9)
        mujoco.mju_quat2Mat(reference, q)
        assert np.allclose(quaternion_to_matrix(q), reference.reshape(3, 3))


def test_base_pose_maps_mujoco_z_up_to_xr_y_up():
    assert base_pose_to_xr([0, 0, 0], [1, 0, 0, 0]) == pytest.approx([0, 0, 0, 0, 0, 0, 1])
    # Robot +X (forward) is XR -Z, robot +Y (left) is XR -X, robot +Z (up) is XR +Y.
    assert base_pose_to_xr([1, 2, 3], [1, 0, 0, 0])[:3] == pytest.approx([-2, 3, -1])
    assert np.allclose(ROBOT_TO_XR @ ROBOT_TO_XR.T, np.eye(3)) and np.linalg.det(ROBOT_TO_XR) == pytest.approx(1)
    # A yaw about robot Z becomes the same yaw about XR Y.
    pose = base_pose_to_xr([0, 0, 0], rotation_about([0, 0, 1], np.pi / 2))
    expected = np.array([0, np.sin(np.pi / 4), 0, np.cos(np.pi / 4)])
    assert np.allclose(pose[3:], expected) or np.allclose(pose[3:], -expected)
    # The base rotation acts on robot-frame vectors consistently after conversion.
    q = rotation_about([1, 1, 0], 0.7)
    xr = quaternion_to_matrix(np.array(base_pose_to_xr([0, 0, 0], q)[3:])[[3, 0, 1, 2]])
    assert np.allclose(xr @ ROBOT_TO_XR, ROBOT_TO_XR @ quaternion_to_matrix(q))
    joints, base = frame_to_state(np.concatenate(([0.5, 0, 0.8, 1, 0, 0, 0], np.arange(29) / 10)))
    assert joints == pytest.approx((np.arange(29) / 10).tolist()) and base[:3] == pytest.approx([0, 0.8, -0.5])


def test_blueprint_declares_generic_primitives_only():
    spec = blueprint_for_tests(distance=2.0)
    by_id = {component.id: component for component in spec.components}
    assert spec.blueprint_id == "example.light_o1"
    assert set(by_id) == {"ground", "lighting", "g1", "prompt_status"} | {row[0] for row in MENU_ROWS}
    g1 = by_id["g1"]
    assert g1.type == "robot_model" and tuple(g1.properties["joint_names"]) == JOINT_NAMES
    assert g1.transform.position == (0, 0, -2.0) and g1.transform.rotation == FACE_USER_ROTATION
    assert g1.bindings == {"joint_positions": "g1.joints", "base_pose": "g1.base", "sample": "g1.sample",
                           "visible": "g1.visible"}
    assert by_id["ground"].properties["placement_target"] == "g1"
    assert by_id["ground"].transform.position == (0, 0.002, -2.0)
    label = by_id["prompt_status"]
    assert label.type == "label" and label.anchor == "left_controller" and label.bindings["text"] == "ui.text"
    motion = by_id["motion"]
    assert motion.type == "menu_item" and motion.properties["action"] == "motion.toggle"
    assert (motion.properties["locked_text"], motion.properties["unlocked_text"]) == ("Generate", "Stop")
    assert motion.bindings == {"value": "motion.active", "available": "motion.available"}
    assert by_id["replay"].bindings["available"] == "motion.replay_available"
    assert by_id["prompt_next"].bindings == {"value": "prompt.cycle"}
    # Menu rows appear in declaration order: page 1 = Generate + Next, page 2 = Prev + Replay.
    rows = [component.id for component in spec.components if component.type == "menu_item"]
    assert rows == ["motion", "prompt_next", "prompt_prev", "replay"]
    assert not any(component.type in ("input_binding", "controller_menu", "palm_menu")
                   for component in spec.components)
    away = blueprint_for_tests(face_user=False)
    assert {c.id: c for c in away.components}["g1"].transform.rotation == (0.0, 0.0, 0.0, 1.0)
    with pytest.raises(ValueError):
        blueprint_for_tests(distance=0)


def test_blueprint_state_contract_covers_every_session_key():
    spec = blueprint_for_tests()
    state = {"g1.joints": [0.0] * 29, "g1.base": [0, 0.8, 0, 0, 0, 0, 1], "g1.sample": 1, "g1.visible": True,
             "ui.text": "Prompt 1/1: wave\nReady", "motion.active": False, "motion.available": True,
             "motion.replay_available": False, "prompt.cycle": False}
    spec.validate_state_values(state)
    assert set(spec.binding_types()) == set(state)
    with pytest.raises(ValueError):
        spec.validate_state_values({"motion.active": "yes"})
    with pytest.raises(ValueError):
        spec.validate_state_values({"g1.sample": -1})
