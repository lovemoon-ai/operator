"""SONIC v1.1 algorithms with Operator's shared gamepad interaction."""
from pathlib import Path
import numpy as np
from scipy.spatial.transform import Rotation

from .parameters import load_parameters
from .policy import Policy
from .simulation import Simulation
from .pico_input import OfficialThreePoint, extract_pico_sample, require_full_body
from .planner import OfficialPlanner
from ...tracking import rotation_wxyz
from ...tracking import TrackingUnavailable
from ...controls import Gamepad, ControlMode, HELP, RESET_HINT


def add_arguments(parser):
    parser.add_argument("--checkpoint", type=Path, required=True,
                        help="Official SONIC v1.1 encoder/decoder/config directory")
    parser.add_argument("--upstream", type=Path, required=True, help="Pinned GR00T-WholeBodyControl checkout")
    parser.add_argument("--model", type=Path, help="Official 43-DoF G1 scene (29 body + 14 hand joints)")
    parser.add_argument("--planner", type=Path, help="Official V2 planner_sonic.onnx")
    parser.add_argument("--backend", choices=("onnxruntime",), default="onnxruntime")
    parser.add_argument("--device", choices=("cpu", "cuda"), default="cuda")
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--synchronous-planner", action="store_true",
                        help="Offline diagnostics only; live operation uses a separate planner worker")


def yaw(quaternion):
    matrix = rotation_wxyz(quaternion).as_matrix()
    return np.arctan2(matrix[1, 0], matrix[0, 0])


class SonicController:
    key = "sonic"
    name = "SONIC G1"
    dt = Simulation.DT
    initial_status = "SONIC OFF: " + RESET_HINT
    extract = staticmethod(extract_pico_sample)

    def __init__(self, args):
        if args.scale != 1.0:
            raise ValueError("Official SONIC does not apply an operator motion scale; use --scale 1")
        self.args = args
        self.parameters = load_parameters(args.upstream)
        self.three_point = OfficialThreePoint(args.upstream)
        official_model = args.upstream / "gear_sonic/data/robot_model/model_data/g1/scene_43dof.xml"
        model = args.model or official_model
        if model.resolve() != official_model.resolve():
            raise ValueError("Official SONIC mode requires its pinned 43-DoF scene")
        self.simulation = Simulation(model, self.parameters)
        self.simulation.configure_hands(self.three_point.robot_model)
        self.policy = Policy(args.checkpoint, device=args.device, threads=args.threads)
        self.planner = OfficialPlanner(args.upstream,
            args.planner or args.upstream / "gear_sonic_deploy/planner/target_vel/V2/planner_sonic.onnx",
            device=args.device, threads=args.threads)
        self.controls = None
        self.gamepad = Gamepad()
        self.synchronous_planner = getattr(args, "synchronous_planner", False)
        try:
            self.reset()
        except BaseException:
            self.planner.close()
            raise
        print(HELP, flush=True)

    def _new_controls(self):
        from .controls import UnifiedControls
        self.three_point.processor = self.three_point.algorithms.ThreePointPose(
            robot_model=self.three_point.robot_model, log_prefix="SONIC")
        self.controls = UnifiedControls(self.args.upstream, self.three_point, self.simulation.feedback)
        self.control_mode = ControlMode.LOCOMOTION
        self.encoder_mode = 0
        self.planner_enabled = False
        self.current_command = {}
        self.heading_offset = self.heading_delta = 0.
        self.next_plan = 0.
        self.need_planner_install = False

    @property
    def control_enabled(self):
        return self.controls.mode != self.controls.algorithms.StreamMode.OFF

    def pause(self):
        self.gamepad.invalidate()
        if self.controls is not None and not self.control_enabled:
            return
        self.planner.reset()
        self._new_controls()

    def reset(self):
        self.simulation.reset()
        self.planner.reset()
        self._new_controls()

    def close(self):
        self.planner.close()
        self.three_point.processor.close()

    def control_tick(self, frame, sample, now):
        self.planner.check_worker()
        commands = self.gamepad.update(frame)
        if commands.reset:
            self.reset()
            try:
                self.controls.start(sample)
            except TrackingUnavailable as exc:
                self.pause()
                return f"SONIC reset failed: {exc}"
        elif commands.cycle_mode and self.control_enabled:
            self.control_mode = self.control_mode.next()
            self.controls.set_mode(self.control_mode)
            self.current_command = {}
            # POSE may buffer before emitting its first packet. Never reuse
            # VR's encoder mask with a newly cleared three-point command.
            self.encoder_mode = {ControlMode.LOCOMOTION: 0, ControlMode.VR: 1, ControlMode.BODY: 2}[self.control_mode]
        mode = self.controls.mode
        Modes = self.controls.algorithms.StreamMode
        if mode == Modes.OFF:
            return "SONIC OFF: " + RESET_HINT
        if self.control_mode == ControlMode.BODY:
            try:
                require_full_body(sample)
            except TrackingUnavailable as exc:
                self.pause()
                return f"SONIC BODY unavailable: {exc}; restore tracking and press ABXY to reset"
        messages = self.controls.update_commands(frame, sample, now, commands)
        planner_enabled = mode in (Modes.PLANNER, Modes.PLANNER_FROZEN_UPPER_BODY, Modes.PLANNER_VR_3PT)
        if planner_enabled != self.planner_enabled:
            self.planner.set_mode(planner_enabled)
            self.planner_enabled = planner_enabled
            self.need_planner_install = planner_enabled
            self.next_plan = now
        heading_increment = 0.
        for topic, values in messages:
            if topic == "planner":
                self.current_command = values
                self.encoder_mode = 1 if "vr_position" in values else 0
                self.planner.movement(int(values["mode"][0]), values["movement"], values["facing"],
                                      float(values["speed"][0]), float(values["height"][0]))
            elif topic == "pose":
                self.planner.stream(values)
                self.encoder_mode = 2
                increment = float(values["heading_increment"][0])
                heading_increment += increment
                self.heading_delta += increment
            if topic in ("planner", "pose"):
                self.simulation.command_hands(values.get("left_hand_joints"), values.get("right_hand_joints"))
        sim = self.simulation
        self.planner.measurements(sim.data.qpos[3:7], sim.data.qpos[sim.q_indices])
        if planner_enabled and now + 1e-9 >= self.next_plan:
            if self.planner.worker is None:
                self.planner.plan()
                if self.need_planner_install:
                    # Do not feed a previous SMPL stream's sparse joint array
                    # to the G1 encoder while switching back to the planner.
                    self.planner.advance()
                    self.need_planner_install = False
                if not self.synchronous_planner: self.planner.start_worker()
            else:
                self.planner.request_plan()
            self.next_plan = now + .1
        references = self.planner.references()
        if references is None:
            # Consume the first generated planner trajectory; no policy runs
            # against an invented reference while waiting for upstream data.
            self.planner.advance()
            references = self.planner.references()
        if references is None:
            return f"SONIC {mode.name}: buffering official reference"
        if self.planner.take_heading_reset():
            self.heading_offset = yaw(sim.data.qpos[3:7]) - yaw(references[2][0])
            self.heading_delta = heading_increment
        values = self._encoder_values(references)
        if values is None:
            return f"SONIC {mode.name}: buffering official POSE reference"
        action = self.policy.infer(values, sim.decoder_values(), mode=self.encoder_mode)
        sim.step(action)
        self.planner.advance()
        return (f"SONIC {self.control_mode.value} ({mode.name}) | "
                f"vx={commands.vx:.2f} vy={commands.vy:.2f} vyaw={commands.vyaw:.2f}"
                if self.control_mode != ControlMode.BODY else "SONIC BODY (POSE): sticks disabled; tracking body")

    def _encoder_values(self, references):
        q, dq, quaternions, positions = references
        current_yaw = yaw(self.simulation.data.qpos[3:7])
        def orient(qs):
            return (Rotation.from_euler("z", self.heading_offset + self.heading_delta - current_yaw)
                    * rotation_wxyz(qs)).as_matrix()[..., :2].reshape(len(qs), 6)
        q, dq = q.copy(), dq.copy()
        upper = self.current_command.get("upper_body_position")
        if upper is not None:
            indices = self.parameters["upper_body_joint_isaaclab_order_in_isaaclab_index"].astype(int)
            q[:, indices] = upper
            dq[:, indices] = self.current_command.get("upper_body_velocity", np.zeros(17))
        lower = self.parameters["lower_body_joint_mujoco_order_in_isaaclab_index"].astype(int)
        values = {
            "encoder_mode_4": [self.encoder_mode, 0, 0, 0],
            "motion_joint_positions_10frame_step5": q,
            "motion_joint_velocities_10frame_step5": dq,
            "motion_anchor_orientation_heading_10frame_step5": orient(quaternions),
            "motion_joint_positions_lowerbody_10frame_step5": q[:, lower],
            "motion_joint_velocities_lowerbody_10frame_step5": dq[:, lower],
            "motion_anchor_orientation_heading": orient(quaternions[:1]),
        }
        if self.encoder_mode == 1:
            values["vr_3point_local_target"] = self.current_command["vr_position"]
            values["vr_3point_local_orn_target"] = self.current_command["vr_orientation"]
        elif self.encoder_mode == 2:
            pose = self.planner.pose_references()
            if pose is None: return None
            joints, rotations, wrists = pose
            values.update(smpl_joints_10frame_step1=joints,
                smpl_anchor_orientation_heading_10frame_step1=orient(rotations),
                motion_joint_positions_wrists_10frame_step1=wrists)
        return values
