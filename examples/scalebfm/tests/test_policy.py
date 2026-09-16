"""Optional conformance checks against real weights and the real robot model."""
import json
import os
from pathlib import Path
import sys

import numpy as np
import pytest

from runtime import Policy, Simulation
from tracking import FIVE_POINTS, rotation_wxyz


@pytest.fixture(scope="module")
def real_policy():
    required = ("SCALEBFM_CHECKPOINT", "SCALEBFM_UPSTREAM", "SCALEBFM_G1_XML")
    if not all(os.getenv(name) for name in required):
        pytest.skip("Set SCALEBFM_CHECKPOINT, SCALEBFM_UPSTREAM and SCALEBFM_G1_XML for real-policy tests")
    pytest.importorskip("torch")
    argv = sys.argv.copy()
    policy = Policy(Path(os.environ["SCALEBFM_CHECKPOINT"]), backend="torch", device="cpu",
                    upstream=Path(os.environ["SCALEBFM_UPSTREAM"]), model=Path(os.environ["SCALEBFM_G1_XML"]))
    assert sys.argv == argv  # Loading declarations must not run the upstream CLI.
    return policy


def neutral_inputs(policy):
    sim = Simulation(Path(os.environ["SCALEBFM_G1_XML"]), policy.metadata)
    positions, rotations = sim.reference_pose()
    arrays = sim.inputs(np.repeat(positions[None], 6, axis=0), np.repeat(rotations[None], 6, axis=0),
                        np.asarray(policy.metadata["future_idx"]), False)
    return sim, arrays


def test_real_checkpoint_action_scale_and_five_point_mask(real_policy):
    _, arrays = neutral_inputs(real_policy)
    target, action = real_policy.infer(arrays)
    assert target.shape == action.shape == (29,)
    assert np.isfinite(target).all()
    np.testing.assert_allclose(target, action * np.asarray(real_policy.metadata["action_scale"])
                               + real_policy.metadata["default_dof_pos"], atol=1e-6)
    # Changing unselected reference links cannot affect mode 4's output.
    unselected = [i for i, name in enumerate(real_policy.metadata["selected_body_names"])
                  if name not in FIVE_POINTS]
    changed = [a.copy() for a in arrays]
    changed[5][:, :, unselected] += .5
    changed[6][:, :, unselected] = [0, 1, 0, 0]
    np.testing.assert_allclose(real_policy.infer(changed)[0], target, atol=1e-6)
    wrist = real_policy.metadata["selected_body_names"].index("left_wrist_yaw_link")
    changed[5][:, :, wrist, 2] += .1
    assert not np.allclose(real_policy.infer(changed)[0], target, atol=1e-4)


def test_exporter_kinematics_matches_real_mujoco(real_policy):
    import mujoco
    import torch
    from upstream_policy import deployment_kinematics, load_definitions

    model_path = Path(os.environ["SCALEBFM_G1_XML"])
    names, joint_names, parents, axes, translation, rotation = deployment_kinematics(model_path)
    definitions = load_definitions(Path(os.environ["SCALEBFM_UPSTREAM"]))
    sim, _ = neutral_inputs(real_policy)
    indices = [sim.model.joint(name).qposadr[0] for name in joint_names]
    rng = np.random.default_rng(17)
    for _ in range(4):
        sim.data.qpos[:7] = [0, 0, 0, 1, 0, 0, 0]
        sim.data.qpos[sim.q_indices] = np.asarray(real_policy.metadata["default_dof_pos"]) + rng.normal(0, .1, 29)
        mujoco.mj_forward(sim.model, sim.data)
        half = torch.tensor(sim.data.qpos[indices], dtype=torch.float32)[:, None] / 2
        joint_rot = torch.cat([torch.cos(half), axes * torch.sin(half)], dim=-1)
        positions = torch.zeros(30, 3)
        rotations = torch.zeros(30, 4)
        rotations[:, 0] = 1
        for i in range(1, 30):
            parent = int(parents[i])
            positions[i] = positions[parent] + definitions.quat_apply(rotations[parent], translation[i-1])
            rotations[i] = definitions.quat_mul(rotations[parent], definitions.quat_mul(rotation[i-1], joint_rot[i-1]))
        ids = [sim.model.body(name).id for name in names]
        np.testing.assert_allclose(positions.numpy(), sim.data.xpos[ids], atol=2e-6)
        np.testing.assert_allclose(rotation_wxyz(rotations.numpy()).as_matrix(),
                                   sim.data.xmat[ids].reshape(-1, 3, 3), atol=2e-6)


def test_real_model_torchscript_export_and_reload(real_policy, tmp_path):
    from benchmark import export_script

    _, arrays = neutral_inputs(real_policy)
    path = tmp_path / "policy.pt"
    export_script(real_policy, arrays, path)
    restored = Policy(path, backend="torchscript", device="cpu")
    np.testing.assert_allclose(restored.infer(arrays)[0], real_policy.infer(arrays)[0], atol=1e-5)
    with pytest.raises(FileExistsError):
        export_script(real_policy, arrays, path)
    metadata_path = tmp_path / "policy_metadata.json"
    metadata = json.loads(metadata_path.read_text())
    metadata["operator_export"]["device"] = "cuda"
    metadata_path.write_text(json.dumps(metadata))
    with pytest.raises(ValueError, match="device differs"):
        Policy(path, backend="torchscript", device="cpu")
