"""Validate export contracts; optional physics checks use the real upstream model."""
import os
import argparse
from pathlib import Path

import numpy as np
import pytest

from wbc.controllers.scalebfm.runtime import Simulation, add_policy_arguments, validate_metadata
from wbc.controllers.scalebfm.tracking import FIVE_POINTS, rotation_wxyz


def test_cli_defaults_to_cuda_and_cpu_requires_explicit_selection():
    parser = argparse.ArgumentParser()
    add_policy_arguments(parser)
    required = ["--checkpoint", "model.pt", "--model", "g1.xml"]
    assert parser.parse_args(required).device == "cuda"
    assert parser.parse_args([*required, "--device", "cpu"]).device == "cpu"


def metadata_for_contract_tests():
    # Metadata contract only; no Inside Robot assets or headset fixtures.
    # Deliberately permute action order to test mapping against a real host model.
    legs = ("hip_pitch", "hip_roll", "hip_yaw", "knee", "ankle_pitch", "ankle_roll")
    arms = ("shoulder_pitch", "shoulder_roll", "shoulder_yaw", "elbow", "wrist_roll", "wrist_pitch", "wrist_yaw")
    names = [f"{side}_{joint}_joint" for side in ("left", "right") for joint in legs]
    names += [f"waist_{axis}_joint" for axis in ("yaw", "roll", "pitch")]
    names += [f"{side}_{joint}_joint" for side in ("left", "right") for joint in arms]
    bodies = ["pelvis", "left_hip_roll_link", "left_knee_link", "left_ankle_roll_link",
              "right_hip_roll_link", "right_knee_link", "right_ankle_roll_link", "torso_link",
              "left_shoulder_roll_link", "left_elbow_link", "left_wrist_yaw_link",
              "right_shoulder_roll_link", "right_elbow_link", "right_wrist_yaw_link"]
    return dict(joint_names=names, action_names=list(reversed(names)), selected_body_names=bodies,
                stiffness=[50.] * 29, damping=[2.] * 29, default_dof_pos=[0.] * 29,
                history_buffer_size=3, future_idx=[0, 1, 2, 3, 4, 10])


def test_metadata_rejects_partial_or_incompatible_policy():
    metadata = metadata_for_contract_tests()
    validate_metadata(metadata)
    for key, value in (("joint_names", ["a"] * 29), ("stiffness", [float("nan")] * 29),
                       ("future_idx", [0, 1]), ("history_buffer_size", 0),
                       ("action_names", ["a"] * 29), ("selected_body_names", list(FIVE_POINTS))):
        with pytest.raises(ValueError):
            validate_metadata({**metadata, key: value})


@pytest.mark.skipif(not os.getenv("SCALEBFM_G1_XML"), reason="Set SCALEBFM_G1_XML to the real ScaleBridge model")
def test_real_mujoco_name_mapping_history_and_base_frame():
    sim = Simulation(Path(os.environ["SCALEBFM_G1_XML"]), metadata_for_contract_tests())
    positions, rotations = sim.reference_pose()
    inputs = sim.inputs(np.repeat(positions[None], 6, axis=0), np.repeat(rotations[None], 6, axis=0),
                        np.array([0, 1, 2, 3, 4, 10]), False)
    assert [a.shape for a in inputs] == [(1, 3, 4), (1, 3, 3), (1, 3, 29), (1, 3, 29),
                                         (1, 3, 29), (1, 6, 14, 3), (1, 6, 14, 4), (1,), (1, 6, 1)]
    assert inputs[7][0] == 4 and inputs[8].dtype == np.int64
    np.testing.assert_allclose(inputs[5][0, 0, 0], 0, atol=1e-7)
    np.testing.assert_allclose(rotation_wxyz(inputs[6][0, 0, 0]).as_matrix(), np.eye(3), atol=1e-7)
    assert sim.model.joint(sim.metadata["action_names"][0]).qposadr[0] == sim.action_q_indices[0]
    with pytest.raises(ValueError, match="invalid joint"):
        sim.step(np.full(29, np.nan), np.zeros(29))
    sim.step(np.zeros(29), np.arange(29, dtype=np.float32))
    assert sim.data.time == pytest.approx(.02)
    np.testing.assert_array_equal(sim.history[-1][-1], np.arange(29))
    assert len(sim.blueprint_state()["g1.joints"]) == 29
    assert len(sim.blueprint_state()["g1.base"]) == 7
