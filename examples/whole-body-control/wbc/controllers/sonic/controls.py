"""The upstream PICO manager/streamers, with transport and clock adapters only."""
from __future__ import annotations
import ast
from collections import defaultdict, deque
import importlib
import json
import os
import types

import numpy as np

from .official import declarations, source_bytes, STREAMER, FINGERPRINTS


class Clock:
    # The host loop supplies the cadence. Upstream run_once() remains unchanged
    # but must not sleep inside the 50-Hz physics loop.
    now = 0.
    def time(self): return self.now
    def sleep(self, _seconds): pass


class Reader:
    def __init__(self):
        self.frame = self.sample = None
        self.values_override = None
        self.previous_timestamp = None
        self.dt = 0.

    def update(self, frame, sample):
        if self.previous_timestamp is not None:
            self.dt = (frame.timestamp_ns - self.previous_timestamp) * 1e-9
        self.previous_timestamp = frame.timestamp_ns
        self.frame, self.sample = frame, sample

    def get_timestamp_ns(self): return self.frame.timestamp_ns if self.frame else 0
    def get_latest(self):
        if self.sample is None: return None
        return {"body_poses_np": self.sample.body_poses_np, "timestamp_ns": self.get_timestamp_ns(),
                "dt": self.dt, "fps": 1 / self.dt if self.dt > 0 else 0.}

    def value(self, hand, name):
        if self.values_override is not None:
            return self.values_override.get((hand, name), 0.)
        controller = getattr(self.frame.controllers, hand) if self.frame else None
        return controller.input.value(name) if controller else 0.

    def get_A_button(self): return self.value("right", "ax_button") > .5
    def get_B_button(self): return self.value("right", "by_button") > .5
    def get_X_button(self): return self.value("left", "ax_button") > .5
    def get_Y_button(self): return self.value("left", "by_button") > .5
    def get_left_axis(self): return [self.value("left", "primary_x"), self.value("left", "primary_y")]
    def get_right_axis(self): return [self.value("right", "primary_x"), self.value("right", "primary_y")]
    def get_left_axis_click(self): return self.value("left", "primary_click") > .5
    def get_right_axis_click(self): return self.value("right", "primary_click") > .5
    def get_left_trigger(self): return self.value("left", "trigger")
    def get_right_trigger(self): return self.value("right", "trigger")
    def get_left_grip(self): return self.value("left", "grip")
    def get_right_grip(self): return self.value("right", "grip")
    def get_left_menu_button(self): return self.value("left", "menu_button") > .5
    def get_right_menu_button(self): return self.value("right", "menu_button") > .5


class Messages:
    """Decode the actual upstream wire bytes at an in-process adapter boundary."""
    def __init__(self): self.pending = []
    def send(self, message):
        topic = next(t for t in ("manager_state", "command", "planner", "pose") if message.startswith(t.encode()))
        start = len(topic)
        header = json.loads(message[start:start + 1280].rstrip(b"\0"))
        if header["endian"] != "le": raise ValueError("Unexpected upstream endian")
        offset = start + 1280
        values = {}
        types = {"f32":"<f4", "f64":"<f8", "i32":"<i4", "i64":"<i8", "u8":"u1", "bool":"?"}
        for field in header["fields"]:
            dtype = np.dtype(types[field["dtype"]])
            count = int(np.prod(field["shape"]))
            values[field["name"]] = np.frombuffer(message, dtype, count, offset).copy().reshape(field["shape"])
            offset += dtype.itemsize * count
        if offset != len(message): raise ValueError("Invalid upstream message length")
        self.pending.append((topic, values))


def manager_step(source: bytes, namespace):
    """Lift ONE iteration from the real manager into a resumable host method.

    Only persistent local names become attributes. Branches, priorities, calls,
    transitions and ordering are copied verbatim from the pinned AST.
    """
    tree = ast.parse(source)
    function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "run_pico_manager")
    loop = next(n for n in ast.walk(function) if isinstance(n, ast.While))
    persistent = {"reader", "three_point", "pose_streamer", "planner_streamer", "socket",
                  "current_mode", "vr3pt_parent_mode", "prev_toggle_dc", "prev_toggle_da",
                  "prev_ax_pressed", "prev_by_pressed", "prev_start_combo", "prev_left_axis_click"}
    class Bind(ast.NodeTransformer):
        def visit_Name(self, node):
            if node.id in persistent:
                return ast.copy_location(ast.Attribute(ast.Name("self", ast.Load()), node.id, node.ctx), node)
            return node
    method = ast.FunctionDef(name="manager_step", args=ast.arguments(posonlyargs=[],
        args=[ast.arg(arg="self")], vararg=None, kwonlyargs=[], kw_defaults=[], kwarg=None, defaults=[]),
        body=[Bind().visit(n) for n in loop.body], decorator_list=[])
    module = ast.fix_missing_locations(ast.Module(body=[method], type_ignores=[]))
    exec(compile(module, "<pinned SONIC manager iteration>", "exec"), namespace)
    return namespace["manager_step"]


class OfficialControls:
    def __init__(self, upstream, three_point, measurements):
        import msgpack
        import torch
        for relative in FINGERPRINTS:
            if relative.startswith(("gear_sonic/utils/", "gear_sonic/trl/", "gear_sonic/isaac_utils/", "gear_sonic/data/human/")):
                source_bytes(upstream, relative)
        self.reader, self.clock, self.messages = Reader(), Clock(), Messages()
        self.algorithms = module = three_point.algorithms
        module.__dict__.update(defaultdict=defaultdict, deque=deque, torch=torch, os=os,
                               time=self.clock, msgpack=msgpack, xrt=self.reader, _ISAAC_TELEOP_READERS=())
        builders = importlib.import_module("gear_sonic.utils.teleop.zmq.zmq_planner_sender")
        for name in ("build_command_message", "build_planner_message", "pack_pose_message"):
            module.__dict__[name] = getattr(builders, name)
        hand = importlib.import_module("gear_sonic.utils.teleop.solver.hand.g1_gripper_ik_solver")
        module.G1GripperInverseKinematicsSolver = hand.G1GripperInverseKinematicsSolver
        transform = importlib.import_module("gear_sonic.trl.utils.torch_transform")
        for name in ("angle_axis_to_quaternion", "quat_apply", "quat_inv", "quaternion_to_angle_axis",
                     "quaternion_to_rotation_matrix"):
            module.__dict__[name] = getattr(transform, name)
        # Explicit resource path only; mathematical implementation is unchanged.
        def human_joints(**kwargs):
            return transform.compute_human_joints(**kwargs,
                human_joints_info_path=str(upstream / "gear_sonic/data/human/human_joints_info.pkl"))
        module.compute_human_joints = human_joints
        rotations = importlib.import_module("gear_sonic.isaac_utils.rotations")
        module.remove_smpl_base_rot = rotations.remove_smpl_base_rot
        module.smpl_root_ytoz_up = rotations.smpl_root_ytoz_up
        module.decompose_rotation_aa = importlib.import_module("gear_sonic.trl.utils.rotation_conversion").decompose_rotation_aa
        class FeedbackPoller:
            def __init__(self, **_): pass
            def get_data(self): return msgpack.packb(measurements(), use_bin_type=True)
        module.ZMQPoller = FeedbackPoller
        source = source_bytes(upstream, STREAMER)
        declarations(source, str(upstream / STREAMER), {
            "get_controller_inputs", "get_controller_axes", "get_menu_buttons", "get_axis_clicks",
            "get_face_buttons", "get_abxy_buttons", "generate_finger_data", "init_hand_ik_solvers",
            "compute_hand_joints_from_inputs", "process_smpl_joints", "compute_from_body_poses",
            "_quat_lerp_normalized", "_interp_pose_axis_angle", "PoseStreamer", "FeedbackReader", "PlannerStreamer",
        }, module.__dict__)
        self.state = types.SimpleNamespace(reader=self.reader, socket=self.messages, three_point=three_point.processor,
            pose_streamer=module.PoseStreamer(self.messages,self.reader,three_point.processor,5,50,False,"","npz"),
            planner_streamer=module.PlannerStreamer(self.messages,self.reader,three_point.processor,poll_hz=20),
            current_mode=module.StreamMode.OFF, vr3pt_parent_mode=module.StreamMode.PLANNER,
            prev_toggle_dc=False, prev_toggle_da=False, prev_ax_pressed=False, prev_by_pressed=False,
            prev_start_combo=False, prev_left_axis_click=False)
        self.step = types.MethodType(manager_step(source, module.__dict__), self.state)
        self.next_tick = 0.

    @property
    def mode(self): return self.state.current_mode

    def update(self, frame, sample, now):
        self.reader.update(frame, sample)
        self.clock.now = now
        if now + 1e-9 < self.next_tick: return []
        self.step()
        mode = self.state.current_mode
        period = 1 / 50 if mode in (self.algorithms.StreamMode.POSE,
                                    self.algorithms.StreamMode.POSE_PAUSE) else 1 / 20
        self.next_tick += period
        if self.next_tick <= now:
            self.next_tick = now + period
        messages, self.messages.pending = self.messages.pending, []
        return messages


class UnifiedControls(OfficialControls):
    """Operator button semantics, with upstream calibration and pose streaming.

    OfficialControls above remains an upstream conformance oracle; production
    does not run its button manager. ABXY never calls upstream's exit().
    """
    def __init__(self, upstream, three_point, measurements):
        super().__init__(upstream, three_point, measurements)
        # POSE's upstream joystick/menu bindings must not bypass shared controls.
        self.reader.values_override = {}
        self.heading = 0.
        self.last_send_time = None

    def start(self, sample):
        from ...controls import ControlMode
        if not self.state.three_point.calibrate_now(sample.body_poses_np):
            from ...tracking import TrackingUnavailable
            raise TrackingUnavailable("SONIC zero-reference calibration failed")
        self.set_mode(ControlMode.LOCOMOTION)

    def set_mode(self, mode):
        from ...controls import ControlMode
        modes = self.algorithms.StreamMode
        target = {ControlMode.LOCOMOTION: modes.PLANNER, ControlMode.VR: modes.PLANNER_VR_3PT,
                  ControlMode.BODY: modes.POSE}[mode]
        previous = self.mode
        if previous == target:
            return
        if previous == modes.POSE:
            self.state.pose_streamer.on_mode_exit()
            self.heading = 0.
        if target == modes.POSE:
            self.state.pose_streamer.reset_yaw()
        elif target == modes.PLANNER_VR_3PT:
            self.state.planner_streamer.recalibrate_for_vr3pt()
        self.state.current_mode = target
        self.next_tick = 0.
        self.last_send_time = None

    def update_commands(self, frame, sample, now, commands):
        from ...hands import hand_targets
        self.reader.update(frame, sample)
        self.clock.now = now
        if now + 1e-9 < self.next_tick:
            return []
        is_pose = self.mode == self.algorithms.StreamMode.POSE
        period = .02 if is_pose else .05
        dt = period if self.last_send_time is None else min(.1, max(0., now - self.last_send_time))
        self.last_send_time = now
        left, right = hand_targets(commands)
        if is_pose:
            self.state.pose_streamer.run_once()
        else:
            self.heading += commands.vyaw * dt
            facing = np.array([np.cos(self.heading), np.sin(self.heading), 0.])
            movement = commands.vx * facing + commands.vy * np.array([-facing[1], facing[0], 0.])
            speed = float(np.linalg.norm(movement))
            locomotion = self.algorithms.LocomotionMode
            self.state.planner_streamer.mode = locomotion.SLOW_WALK if speed > 0 else locomotion.IDLE
            values = dict(mode=np.array([self.state.planner_streamer.mode.value]),
                          movement=movement / speed if speed else movement, facing=facing,
                          speed=np.array([speed if speed else -1.]), height=np.array([-1.]))
            if self.mode == self.algorithms.StreamMode.PLANNER_VR_3PT:
                pose = self.state.three_point.process_smpl_pose(sample.body_poses_np)
                values.update(vr_position=pose[:, :3].flatten(), vr_orientation=pose[:, 3:].flatten())
            self.messages.pending.append(("planner", values))
        messages, self.messages.pending = self.messages.pending, []
        for topic, values in messages:
            if topic in ("planner", "pose"):
                values.update(left_hand_joints=left, right_hand_joints=right)
        self.next_tick += period
        if self.next_tick <= now:
            self.next_tick = now + period
        return messages
