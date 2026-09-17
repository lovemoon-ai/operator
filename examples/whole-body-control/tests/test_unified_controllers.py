"""Numerical closed loops with actual models; these are not headset tests."""
from dataclasses import replace
import os
from pathlib import Path
from types import SimpleNamespace
import numpy as np
import pytest
from scipy.spatial.transform import Rotation
from wbc.controls import ControlMode, Commands
from wbc.hands import HAND_NAMES
from test_sonic_official import algebra_frame


def numerical_frame(step, left=None, right=None):
    frame = algebra_frame(step * .02, left=left, right=right)
    positions = {7: (-.15, .08, 0), 8: (.15, .08, 0),
                 20: (-.3, 1.2, -.3), 21: (.3, 1.2, -.3)}
    # A non-singular arithmetic pose for upstream's SMPL math, not tracking.
    joints = tuple(replace(j, pose=replace(j.pose,
        position=positions.get(j.joint, j.pose.position),
        rotation=tuple(Rotation.from_euler("xyz", [.005*j.joint, .003*j.joint, .002*j.joint]).as_quat())))
        for j in frame.body.joints)
    return replace(frame, body=replace(frame.body, joints=joints))


@pytest.fixture(params=["scalebfm", "sonic"])
def controller(request):
    if request.param == "scalebfm":
        names = ("SCALEBFM_CHECKPOINT", "SCALEBFM_UPSTREAM", "SCALEBFM_G1_XML")
        if not all(os.getenv(n) for n in names):
            pytest.skip("set SCALEBFM_CHECKPOINT, SCALEBFM_UPSTREAM, SCALEBFM_G1_XML")
        from wbc.controllers.scalebfm.controller import ScaleBFMController
        value = ScaleBFMController(SimpleNamespace(
            checkpoint=Path(os.environ[names[0]]), upstream=Path(os.environ[names[1]]),
            model=Path(os.environ[names[2]]), backend="torch", device="cpu", threads=2,
            metadata=None, mode_table=None, scale=.75, future_last=10, tracking="global"))
        if value.args.model.name == "g1_29dof.xml":
            assert value.simulation.model.nu == 29
            assert value.simulation.hands is None  # never substitute the sibling Dex3 asset
    else:
        names = ("SONIC_UPSTREAM", "SONIC_CHECKPOINT", "SONIC_PLANNER")
        if not all(os.getenv(n) for n in names):
            pytest.skip("set SONIC_UPSTREAM, SONIC_CHECKPOINT, SONIC_PLANNER")
        from wbc.controllers.sonic.controller import SonicController
        value = SonicController(SimpleNamespace(upstream=Path(os.environ[names[0]]),
            checkpoint=Path(os.environ[names[1]]), planner=Path(os.environ[names[2]]), model=None,
            device=os.getenv("SONIC_DEVICE", "cpu"), threads=2, scale=1., synchronous_planner=True))
    try:
        yield value
    finally:
        if hasattr(value, "close"):
            value.close()


def test_shared_reset_modes_velocities_hands_and_no_exit(controller):
    seen = set(); positions = []; headings = []; hands = []
    ab = {"ax_button": 1., "by_button": 1.}
    for step in range(470):
        left, right = {}, {}
        if 1 <= step < 5 or 450 <= step < 455:
            left.update(ab); right.update(ab)
        if step in (50, 300, 400):
            left["primary_click"] = 1.
        if 100 <= step < 240:
            left["primary_y"] = .6
        if 160 <= step < 240:
            right["primary_x"] = .3
        if 180 <= step < 230:
            left["trigger"] = 1.
            right["trigger"] = 1.
        frame = numerical_frame(step, left, right)
        status = controller.control_tick(frame, controller.extract(frame), step*.02)
        sim = controller.simulation
        seen.add(controller.control_mode)
        assert np.isfinite(sim.data.qpos).all(), (step, status)
        if 1 <= step < 300:
            assert sim.data.qpos[2] > .4, (step, status, sim.data.qpos[:7])
        positions.append(sim.data.qpos[:3].copy())
        matrix = Rotation.from_quat(sim.data.qpos[[4, 5, 6, 3]]).as_matrix()
        headings.append(np.arctan2(matrix[1, 0], matrix[0, 0]))
        indices = [sim.model.joint(n).qposadr[0] for n in HAND_NAMES if n in sim.joint_names]
        hands.append(sim.data.qpos[indices].copy())
        expected_joints = 29 if controller.key == "scalebfm" and sim.hands is None else 43
        assert len(sim.blueprint_state()["g1.joints"]) == expected_joints
        if 180 <= step < 230:
            assert controller.control_mode == ControlMode.VR  # dual triggers never switch/reset
            assert sim.data.time > 1.
        if step in (1, 450):
            assert sim.data.time <= .021
            assert controller.control_mode == ControlMode.LOCOMOTION
        if step == 454:
            assert sim.data.time > .06  # holding ABXY didn't reset every frame
    assert seen == set(ControlMode)
    assert np.linalg.norm(positions[280][:2] - positions[90][:2]) > .08
    assert abs(headings[280] - headings[90]) > .08
    if hands[225].size:
        assert np.linalg.norm(hands[225][:7] - hands[175][:7]) > .2
    assert controller.control_enabled  # second ABXY reset, never exit()/OFF


def test_shared_loop_emits_only_declared_blueprint_state(controller):
    from wbc.loop import ControlLoop
    from wbc.presentation import blueprint
    from pyoperator import BlueprintComponent
    def component(id, asset_port, **kwargs):
        return BlueprintComponent.robot_model(id, asset_port=asset_port,
            asset_sha256="a"*64, asset_size=100, joint_names=controller.simulation.joint_names, **kwargs)
    spec = blueprint(SimpleNamespace(component=component), 63904, 2., controller.key)
    loop = ControlLoop(controller, .25)
    for step in range(5):
        frame = numerical_frame(step)
        spec.validate_state_values(loop.tick(frame, True, None, step*.02))


def test_scalebfm_vr_root_relative_targets_and_optional_hands(controller):
    if controller.key != "scalebfm":
        # SONIC's root-relative invariance is tested against the upstream oracle.
        return
    frame = numerical_frame(0)
    controller.calibrate(controller.extract(frame))
    p, q = controller._joystick_reference(controller.extract(frame), Commands())
    moved = replace(frame, body=replace(frame.body, joints=tuple(
        replace(j, pose=replace(j.pose, position=tuple(np.asarray(j.pose.position) + [.4, .1, -.2])))
        for j in frame.body.joints)))
    moved_p, moved_q = controller._joystick_reference(controller.extract(moved), Commands())
    selected = [controller.simulation.body_names.index(n) for n in
                ("pelvis", "left_wrist_yaw_link", "right_wrist_yaw_link")]
    # Unselected body slots are neutral placeholders, not tracked poses.
    # Assert both selected targets and actual masked policy output invariance.
    np.testing.assert_allclose(moved_p[:, selected], p[:, selected], atol=1e-7)
    np.testing.assert_allclose(moved_q, q, atol=1e-7)
    sim = controller.simulation
    def infer(positions, rotations):
        return controller.policy.infer(sim.inputs(positions, rotations, controller.reference.offsets,
                                                 False, control_mode=2))[0]
    np.testing.assert_allclose(infer(moved_p, moved_q), infer(p, q), atol=1e-6)
    assert len(sim.q_indices) == 29
    if sim.hands is not None:
        sim.hands.command(Commands(left_trigger=1.))
        assert np.max(abs(sim.hands.targets[:7])) > 0 and not np.any(sim.hands.targets[7:])
        assert len(sim.hands.q_indices) == 14
    else:
        assert len(sim.joint_names) == 29
