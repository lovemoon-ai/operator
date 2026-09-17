"""Contract math plus opt-in checks with the actual released SONIC weights."""
import copy
import os
from pathlib import Path
import subprocess
import numpy as np
import pytest
import yaml
from scipy.spatial.transform import Rotation
from wbc.tracking import rotation_wxyz

from wbc.controllers.sonic.parameters import arithmetic, load_parameters, HEADER
from wbc.controllers.sonic.policy import Policy, ENCODER_FIELDS, TELEOP_FIELDS, pack, validate_config
from wbc.controllers.sonic.simulation import Simulation
from wbc.app import parse_args


def test_cli_and_safe_parameter_arithmetic():
    args = parse_args(["--controller", "sonic", "--checkpoint", "/models", "--upstream", "/source", "--no-viewer"])
    assert args.device == "cuda" and args.backend == "onnxruntime" and not args.viewer
    assert arithmetic("-2 * A / 4", {"A": 3}) == -1.5
    with pytest.raises(ValueError):
        arithmetic("__import__('os').getcwd()", {})


@pytest.fixture(scope="module")
def upstream():
    path = os.environ.get("SONIC_UPSTREAM")
    if not path:
        pytest.skip("set SONIC_UPSTREAM to the real pinned GR00T-WholeBodyControl checkout")
    return Path(path)


@pytest.fixture(scope="module")
def real_policy(upstream):
    path = os.environ.get("SONIC_CHECKPOINT")
    if not path:
        pytest.skip("set SONIC_CHECKPOINT to the real SONIC v1.1 model directory")
    return Policy(Path(path), device=os.environ.get("SONIC_DEVICE", "cpu"))


def simulation(upstream):
    model = Path(os.environ.get("SONIC_G1_XML", upstream / "gear_sonic_deploy/g1/scene_29dof.xml"))
    return Simulation(model, load_parameters(upstream))


def standing_encoder_values(sim, positions, rotations):
    # Unit-level policy smoke input only. Production uses the official planner.
    matrix = rotation_wxyz(sim.data.qpos[3:7]).as_matrix()
    yaw = np.arctan2(matrix[1, 0], matrix[0, 0])
    heading_relative = Rotation.from_euler("z", -yaw).as_matrix()[:, :2].reshape(-1)
    return {
        # GatherEncoderMode writes the numeric ID followed by padding;
        # despite its width, this field is NOT a one-hot vector.
        "encoder_mode_4": [1., 0., 0., 0.],
        "motion_joint_positions_lowerbody_10frame_step5": np.tile(sim.parameters["default_angles"][:12], (10, 1)),
        "motion_joint_velocities_lowerbody_10frame_step5": np.zeros((10, 12)),
        "motion_anchor_orientation_heading": heading_relative,
        "vr_3point_local_target": positions,
        "vr_3point_local_orn_target": rotations,
    }


def test_parameters_agree_with_compiled_upstream_cpp(upstream, tmp_path):
    # The numeric oracle includes the actual upstream header, not a copy of our parser.
    oracle = Path(__file__).with_name("sonic_parameters_oracle.cpp")
    binary = tmp_path / "parameters"
    subprocess.run(["c++", "-std=c++17", "-I", str((upstream / HEADER).parent), str(oracle), "-o", str(binary)], check=True)
    lines = subprocess.check_output([str(binary)], text=True).splitlines()
    parsed = load_parameters(upstream)
    for line in lines:
        name, values = line.split(":")
        np.testing.assert_allclose(parsed[name], np.fromstring(values, sep=" "), rtol=1e-7)


def test_mode_mask_history_and_joint_mapping(upstream):
    sim = simulation(upstream)
    p, q = sim.reference_pose()
    values = standing_encoder_values(sim, p, q)
    packed = pack(ENCODER_FIELDS, values, allowed=TELEOP_FIELDS)
    assert packed.shape == (1, 1751)
    offset = 0
    for name, size in ENCODER_FIELDS:
        slot = packed[0, offset:offset + size]
        if name not in TELEOP_FIELDS:
            np.testing.assert_array_equal(slot, 0)
        offset += size
    np.testing.assert_array_equal(packed[0, :4], [1, 0, 0, 0])
    sim.data.qpos[sim.q_indices] += np.arange(29) * .01
    state = sim._state()
    np.testing.assert_allclose(state["his_body_joint_positions_10frame_step1"],
        np.arange(29)[sim.parameters["mujoco_to_isaaclab"]] * .01, atol=1e-12)
    np.testing.assert_allclose(state["his_gravity_dir_10frame_step1"], [0, 0, -1])
    sim.reset()
    sim.step(np.arange(29, dtype=np.float32) * .01)
    history = sim.decoder_values()["his_last_actions_10frame_step1"]
    np.testing.assert_array_equal(history[:-1], 0)
    np.testing.assert_allclose(history[-1], np.arange(29) * .01, atol=1e-7)
    assert sim.data.time == pytest.approx(.02)


def test_real_config_rejects_wrong_mode_or_layout(upstream):
    config = yaml.safe_load((upstream / "gear_sonic_deploy/policy/sonic_v1_1/observation_config.yaml").read_text())
    validate_config(config)
    wrong = copy.deepcopy(config)
    wrong["encoder"]["encoder_modes"][1]["required_observations"].remove("vr_3point_local_target")
    with pytest.raises(ValueError): validate_config(wrong)
    wrong = copy.deepcopy(config)
    wrong["observations"].reverse()
    with pytest.raises(ValueError): validate_config(wrong)


def test_real_weights_respond_to_each_point_and_robot_feedback(real_policy, upstream):
    sim = simulation(upstream)
    p, q = sim.reference_pose()
    baseline = real_policy.infer(standing_encoder_values(sim, p, q), sim.decoder_values())
    assert baseline.shape == (29,) and np.isfinite(baseline).all()
    for point in range(3):
        moved = p.copy(); moved[point, 2] += .05
        assert not np.allclose(real_policy.infer(standing_encoder_values(sim, moved, q), sim.decoder_values()), baseline, atol=1e-4)
    sim.data.qpos[sim.q_indices[0]] += .1
    sim.history.append(sim._state())
    assert not np.allclose(real_policy.infer(standing_encoder_values(sim, p, q), sim.decoder_values()), baseline, atol=1e-4)


def test_wrong_planner_model_fails_before_native_runtime(real_policy, upstream):
    from wbc.controllers.sonic.planner import OfficialPlanner
    with pytest.raises(ValueError,match="planner model signature"):
        OfficialPlanner(upstream,Path(os.environ["SONIC_CHECKPOINT"])/"model_encoder.onnx",device="cpu")



def test_cuda_matches_cpu_when_requested(real_policy, upstream):
    if real_policy.device != "cuda":
        pytest.skip("set SONIC_DEVICE=cuda for actual GPU/CPU numerical conformance")
    cpu = Policy(Path(os.environ["SONIC_CHECKPOINT"]), device="cpu")
    sim = simulation(upstream)
    p, q = sim.reference_pose()
    for step in range(5):
        targets = p.copy()
        targets[step % 3, 2] += .03 * step
        encoder, decoder = standing_encoder_values(sim, targets, q), sim.decoder_values()
        gpu_action = real_policy.infer(encoder, decoder)
        np.testing.assert_allclose(gpu_action, cpu.infer(encoder, decoder), rtol=1e-4, atol=1e-5)
        sim.step(gpu_action)


def test_real_standing_and_moving_three_point_closed_loop(real_policy, upstream):
    sim = simulation(upstream)
    p, q = sim.reference_pose()
    joints, roots = [], []
    for i in range(1000):
        target = p.copy()
        # A bounded scripted reference measures the actual policy, not VR tracking.
        if i >= 500:
            target[:2, 2] += .04 * (1 - np.cos(2 * np.pi * .5 * (i - 500) * sim.DT))
        sim.step(real_policy.infer(standing_encoder_values(sim, target, q), sim.decoder_values()))
        assert sim.data.qpos[2] > .4, f"G1 fell at tick {i}"
        joints.append(sim.blueprint_state()["g1.joints"])
        roots.append(sim.blueprint_state()["g1.base"])
    assert sim.data.time == pytest.approx(20)
    assert np.isfinite(joints).all() and np.isfinite(roots).all()
    assert np.max(np.std(joints[500:], axis=0)) > .01
    assert np.max(np.std(roots[500:], axis=0)) > .001
