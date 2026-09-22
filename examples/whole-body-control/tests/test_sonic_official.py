"""Host conformance against real upstream code/assets, not headset coverage."""
from dataclasses import replace
import os
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
from scipy.spatial.transform import Rotation
from operator_xr import (BodyState, ControllerInput, ControllerPair, ControllerState,
                        HandPair, Joint, Pose, XrFrame)
from wbc.controllers.sonic.pico_input import OfficialThreePoint, extract_pico_sample, require_full_body
from wbc.controllers.sonic.controls import OfficialControls
from wbc.tracking import TrackingUnavailable


def algebra_frame(t=0., *, left=None, right=None):
    """A numerical pose input for transform tests, never a device fixture."""
    positions = {0:(0,1,0), 12:(0,1.5,0), 22:(-.3,1.2,-.3), 23:(.3,1.2,-.3)}
    joints = tuple(Joint(joint=i,flags=15,tracked=True,
        pose=Pose(valid=True,position=positions.get(i,(0,1,0)))) for i in range(24))
    timestamp = 1 + round(t*1e9)
    body = BodyState(active=True,sample_timestamp_ns=timestamp,joint_set="pico_bd_24",joints=joints)
    controllers = ControllerPair(
        ControllerState(pose=Pose(valid=True),input=ControllerInput(values=left or {})),
        ControllerState(pose=Pose(valid=True),input=ControllerInput(values=right or {})))
    return XrFrame(1,1+round(t*1000),timestamp,"openxr_stage",None,controllers,HandPair(),body,())


@pytest.fixture
def official():
    root = os.getenv("SONIC_UPSTREAM")
    if not root: pytest.skip("set SONIC_UPSTREAM to test the actual official VR algorithms")
    return OfficialThreePoint(Path(root))


def test_native_pico_input_is_not_pretransformed_or_rescaled():
    frame = algebra_frame()
    sample = extract_pico_sample(frame)
    np.testing.assert_array_equal(sample.body_poses_np[22], [-.3,1.2,-.3,0,0,0,1])
    with pytest.raises(TrackingUnavailable,match="pico_bd_24"):
        extract_pico_sample(replace(frame,body=replace(frame.body,joint_set="godot_xr_body_tracker_v1")))
    joints = list(frame.body.joints); joints[12] = replace(joints[12],flags=8)
    with pytest.raises(TrackingUnavailable,match="point 12"):
        extract_pico_sample(replace(frame,body=replace(frame.body,joints=tuple(joints))))


def test_body_mode_rejects_partial_joints_but_vr_input_keeps_official_three_points():
    frame = algebra_frame()
    joints = list(frame.body.joints)
    joints[7] = replace(joints[7], tracked=False, flags=0,
                        pose=replace(joints[7].pose, valid=False))
    sample = extract_pico_sample(replace(frame, body=replace(frame.body, joints=tuple(joints))))
    with pytest.raises(TrackingUnavailable, match="missing 7"):
        require_full_body(sample)


def test_official_points_and_pelvis_relative_invariance(official):
    raw = extract_pico_sample(algebra_frame()).body_poses_np
    process = official.algorithms._process_3pt_pose
    baseline = process(raw)
    changed = raw.copy(); changed[[15,20,21],:3] += [1,2,3]
    np.testing.assert_allclose(process(changed),baseline,atol=1e-6)
    changed = raw.copy(); changed[22,0] += .2
    assert not np.allclose(process(changed)[0,:3],baseline[0,:3])
    np.testing.assert_allclose(process(changed)[1:],baseline[1:],atol=1e-6)
    moved = raw.copy(); moved[:,:3] += [1.2,-.2,.6]
    np.testing.assert_allclose(process(moved),baseline,atol=1e-6)
    world = Rotation.from_euler("xyz",[.2,-.3,.7])
    rotated = raw.copy(); rotated[:,:3]=world.apply(raw[:,:3])
    rotated[:,3:] = (world * Rotation.from_quat(raw[:,3:])).as_quat()
    result = process(rotated)
    np.testing.assert_allclose(result[:,:3],baseline[:,:3],atol=1e-6)
    np.testing.assert_allclose(Rotation.from_quat(result[:,[4,5,6,3]]).as_matrix(),
                              Rotation.from_quat(baseline[:,[4,5,6,3]]).as_matrix(),atol=1e-6)


def test_zero_start_and_measured_wrist_recalibration_match_upstream(official):
    sample = extract_pico_sample(algebra_frame())
    oracle = official.algorithms.ThreePointPose(robot_model=official.robot_model)
    official.calibrate_full(sample)
    assert oracle.calibrate_now(sample.body_poses_np)
    expected = oracle.process_smpl_pose(sample.body_poses_np)
    actual = official.process(sample)
    np.testing.assert_allclose(np.column_stack(actual),expected,atol=1e-7)
    neck = official.processor._calibration_neck_quat_inv.copy()
    measured = np.linspace(-.15,.15,29)
    official.calibrate_wrists(measured)
    oracle.reset_with_measured_q(measured)
    np.testing.assert_allclose(np.column_stack(official.process(sample)),
                              oracle.process_smpl_pose(sample.body_poses_np),atol=1e-7)
    np.testing.assert_array_equal(official.processor._calibration_neck_quat_inv,neck)
    np.testing.assert_allclose(official.process(sample)[0][2], [0,0,.4], atol=1e-7)


def test_original_manager_modes_joysticks_and_hand_messages(official):
    root=Path(os.environ["SONIC_UPSTREAM"])
    measured = np.linspace(-.1,.1,29).tolist()
    feedback=lambda: {"body_q_measured":measured,"left_hand_q_measured":[0.]*7,"right_hand_q_measured":[0.]*7}
    controls=OfficialControls(root,official,feedback)
    def tick(t, left=None, right=None):
        frame=algebra_frame(t,left=left,right=right)
        return controls.update(frame,extract_pico_sample(frame),t)
    abxy={"ax_button":1.,"by_button":1.}
    tick(0,left=abxy,right=abxy)
    assert controls.mode.name == "PLANNER"
    tick(.05)
    messages=tick(.1,left={"primary_click":1.})
    assert controls.mode.name == "PLANNER_VR_3PT"
    planner=next(values for topic,values in messages if topic=="planner")
    assert planner["vr_position"].shape==(9,) and planner["vr_orientation"].shape==(12,)
    assert planner["left_hand_joints"].shape==(7,)
    tick(.15)
    messages=tick(.2,left={"primary_y":1.,"trigger":1.},right=abxy)
    planner=next(values for topic,values in messages if topic=="planner")
    assert int(planner["mode"][0])==1
    assert float(planner["speed"][0])==pytest.approx(.6)
    np.testing.assert_allclose(planner["movement"],[1,0,0],atol=1e-7)
    assert np.max(abs(planner["left_hand_joints"]))>0
    messages=tick(.25,left={"primary_y":.1},right={"primary_x":1.})
    planner=next(values for topic,values in messages if topic=="planner")
    assert int(planner["mode"][0])==0  # deadzone returns to IDLE
    np.testing.assert_allclose(planner["facing"],[np.cos(-.075),np.sin(-.075),0],atol=1e-7)
    tick(.3,left={"primary_click":1.})
    assert controls.mode.name=="PLANNER"
    tick(.35)
    with pytest.raises(SystemExit): tick(.4,left=abxy,right=abxy)


def test_manager_keeps_twenty_hz_when_polled_at_fifty_hz(official):
    root=Path(os.environ["SONIC_UPSTREAM"])
    controls=OfficialControls(root,official,lambda: {"body_q_measured":[0.]*29})
    count=0
    for i in range(50):
        frame=algebra_frame(i*.02)
        count += bool(controls.update(frame,extract_pico_sample(frame),i*.02))
    assert count==20


def test_official_pose_pause_and_frozen_upper_transitions(official):
    controls=OfficialControls(Path(os.environ["SONIC_UPSTREAM"]),official,
        lambda: {"body_q_measured":[0.]*29,"left_hand_q_measured":[0.]*7,"right_hand_q_measured":[0.]*7})
    def tick(t,left=None,right=None):
        frame=algebra_frame(t,left=left,right=right)
        # Exact zero elbow axis-angle is singular in the pinned upstream SMPL
        # swing/twist implementation. Use a non-singular numerical pose here;
        # do not modify that upstream algorithm to make this test pass.
        joints = tuple(replace(j,pose=replace(j.pose,rotation=tuple(
            Rotation.from_euler("xyz",[.005*j.joint,.003*j.joint,.002*j.joint]).as_quat())))
            for j in frame.body.joints)
        frame=replace(frame,body=replace(frame.body,joints=joints))
        return controls.update(frame,extract_pico_sample(frame),t)
    abxy={"ax_button":1.,"by_button":1.}
    tick(0,abxy,abxy); tick(.05)
    tick(.1,{"ax_button":1.},{"ax_button":1.})
    assert controls.mode.name=="POSE"
    messages=[]
    for i in range(1,12): messages += tick(.1+i*.02)
    poses=[values for topic,values in messages if topic=="pose"]
    assert poses and poses[-1]["smpl_joints"].shape==(5,24,3)
    tick(.34,{"menu_button":1.})
    assert controls.mode.name=="POSE_PAUSE"
    tick(.36)
    assert controls.mode.name=="POSE"
    tick(.38,{"by_button":1.},{"by_button":1.})
    assert controls.mode.name=="PLANNER_FROZEN_UPPER_BODY"
    tick(.44)
    tick(.5,{"primary_click":1.})
    assert controls.mode.name=="PLANNER_VR_3PT"
    tick(.56)
    tick(.62,{"primary_click":1.})
    assert controls.mode.name=="PLANNER_FROZEN_UPPER_BODY"


def test_real_planner_vr3pt_walk_and_turn_with_unified_buttons():
    root=os.getenv("SONIC_UPSTREAM")
    checkpoint=os.getenv("SONIC_CHECKPOINT")
    planner=os.getenv("SONIC_PLANNER")
    if not all((root,checkpoint,planner)):
        pytest.skip("set SONIC_UPSTREAM, SONIC_CHECKPOINT, SONIC_PLANNER for the real full controller")
    from wbc.controllers.sonic.controller import SonicController, yaw
    controller=SonicController(SimpleNamespace(upstream=Path(root),checkpoint=Path(checkpoint),planner=Path(planner),
        model=None,device=os.getenv("SONIC_DEVICE","cpu"),threads=2,scale=1.,synchronous_planner=True))
    modes=set(); lowest=10.; states=[]
    try:
        expected_hand_ids = [i for side in ("left_hand", "right_hand")
                             for i in range(controller.simulation.model.njnt)
                             if side in controller.simulation.model.joint(i).name]
        np.testing.assert_array_equal(controller.simulation.hand_q_indices,
                                       controller.simulation.model.jnt_qposadr[expected_hand_ids])
        for i in range(500):
            left={}; right={}
            if 1<=i<4: left.update(ax_button=1.,by_button=1.); right.update(ax_button=1.,by_button=1.)
            if 50<=i<55: left["primary_click"]=1.
            if 100<=i<350: left["primary_y"]=.6
            if 200<=i<260: right["primary_x"]=.3
            if 180<=i<220: left["trigger"]=1.
            frame=algebra_frame(i*.02,left=left,right=right)
            status=controller.control_tick(frame,extract_pico_sample(frame),i*.02)
            modes.add(controller.controls.mode.name)
            sim=controller.simulation
            lowest=min(lowest,sim.data.qpos[2])
            assert sim.data.qpos[2]>.4, (i,status,sim.data.qpos[:7])
            states.append(sim.blueprint_state())
        assert modes=={"OFF","PLANNER","PLANNER_VR_3PT"}
        assert controller.planner.calls>2
        assert len(states[-1]["g1.joints"])==43
        assert np.linalg.norm(controller.simulation.data.qpos[:2])>.1
        assert abs(yaw(controller.simulation.data.qpos[3:7]))>.1
        assert abs(controller.heading_delta)==0  # planner facing, not POSE yaw increments
    finally:
        controller.close()


def test_real_reference_encodings_follow_pose_and_planner_transitions():
    root=os.getenv("SONIC_UPSTREAM"); checkpoint=os.getenv("SONIC_CHECKPOINT"); planner=os.getenv("SONIC_PLANNER")
    if not all((root,checkpoint,planner)):
        pytest.skip("set SONIC_UPSTREAM, SONIC_CHECKPOINT, SONIC_PLANNER for full transition coverage")
    from wbc.controllers.sonic.controller import SonicController
    controller=SonicController(SimpleNamespace(upstream=Path(root),checkpoint=Path(checkpoint),planner=Path(planner),
        model=None,device=os.getenv("SONIC_DEVICE","cpu"),threads=2,scale=1.,synchronous_planner=True))
    seen=set()
    try:
        for i in range(210):
            left={}; right={}
            if 1<=i<4: left.update(ax_button=1.,by_button=1.); right.update(ax_button=1.,by_button=1.)
            if any(start<=i<start+5 for start in (25,80,125,170)): left["primary_click"]=1.
            frame=algebra_frame(i*.02,left=left,right=right)
            joints=tuple(replace(j,pose=replace(j.pose,rotation=tuple(Rotation.from_euler(
                "xyz",[.005*j.joint,.003*j.joint,.002*j.joint]).as_quat()))) for j in frame.body.joints)
            frame=replace(frame,body=replace(frame.body,joints=joints))
            controller.control_tick(frame,extract_pico_sample(frame),i*.02)
            seen.add((controller.controls.mode.name,controller.encoder_mode))
            if controller.controls.mode.name=="PLANNER" and i >= 125:
                # Returning from POSE must never send its sparse wrist-only
                # joint reference to the planner/G1 encoder, even for one tick.
                q=controller.planner.references()[0]
                assert np.max(abs(q[0,:12]))>.05
        assert ("POSE",2) in seen
        assert ("PLANNER",0) in seen
        assert ("PLANNER_VR_3PT",1) in seen
        assert np.isfinite(controller.simulation.data.qpos).all()
    finally:
        controller.close()
