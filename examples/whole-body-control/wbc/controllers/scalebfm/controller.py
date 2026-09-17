"""ScaleBFM-specific five-point control behind the shared session loop."""
import numpy as np
from scipy.spatial.transform import Rotation

from .runtime import Simulation, policy_from_args
from .tracking import Calibration, ReferenceBuffer, extract_five_points
from ...tracking import rotation_wxyz, wxyz, TrackingUnavailable
from ...controls import Gamepad, ControlMode, RESET_HINT


class ScaleBFMController:
    key = "scalebfm"
    name = "ScaleBFM G1"
    dt = Simulation.DT
    initial_status = "ScaleBFM OFF: " + RESET_HINT
    extract = staticmethod(extract_five_points)

    def __init__(self, args):
        self.args = args
        self.policy = policy_from_args(args)
        # Honor the requested asset: the standard 29-DoF model must not be
        # silently replaced by a heavier articulated-hand variant.
        self.simulation = Simulation(args.model, self.policy.metadata)
        if self.simulation.hands is None:
            print("ScaleBFM: no articulated hands; trigger/grip bindings are reserved (no-op).", flush=True)
        self.gamepad = Gamepad()
        self.control_mode = ControlMode.LOCOMOTION
        self.pause()
        p, q = self.simulation.reference_pose()
        self.policy.infer(self.simulation.inputs(
            np.repeat(p[None], 6, axis=0), np.repeat(q[None], 6, axis=0),
            self.reference.offsets, args.tracking == "local"))
        print(f"ScaleBFM: {self.policy.backend}/{self.policy.device}; reference delay {args.future_last * 20} ms", flush=True)

    def pause(self):
        self.gamepad.invalidate()
        self.calibration = None
        self.reference = ReferenceBuffer(self.args.future_last)

    def reset(self):
        # Do not reset gamepad edges here: ABXY may still be held down.
        self.calibration = None
        self.reference = ReferenceBuffer(self.args.future_last)
        self.control_mode = ControlMode.LOCOMOTION
        self.simulation.reset()

    def calibrate(self, sample):
        self.calibration = Calibration(sample, *self.simulation.reference_pose(),
                                       self.simulation.body_names, self.args.scale)
        self.reference = ReferenceBuffer(self.args.future_last)
        self.root_target = self.simulation.data.qpos[:3].copy()
        rotation = rotation_wxyz(self.simulation.data.qpos[3:7]).as_matrix()
        self.heading = np.arctan2(rotation[1, 0], rotation[0, 0])

    def accept(self, sample):
        if self.calibration is not None:
            self.reference.append(sample.timestamp_ns, *self.calibration.apply(sample))

    def advance(self):
        targets = self.reference.targets()
        if targets is None:
            return "Buffering five-point targets"
        target, action = self.policy.infer(self.simulation.inputs(
            *targets, self.reference.offsets, self.args.tracking == "local"))
        self.simulation.step(target, action)
        return "Running: pelvis + hands + feet -> G1 (29 DoF)"

    @property
    def control_enabled(self):
        return self.calibration is not None

    def control_tick(self, frame, sample, now):
        commands = self.gamepad.update(frame)
        if commands.reset:
            self.reset()
            try:
                self.calibrate(sample)
            except TrackingUnavailable as exc:
                self.pause()
                return f"ScaleBFM reset failed: {exc}"
        elif commands.cycle_mode and self.control_enabled:
            self.control_mode = self.control_mode.next()
            # Re-anchor to actual robot pose, without resetting physics.
            try:
                self.calibrate(sample)
            except TrackingUnavailable as exc:
                self.pause()
                return f"ScaleBFM mode calibration failed: {exc}"
        if not self.control_enabled:
            return self.initial_status
        if self.simulation.hands is not None:
            self.simulation.hands.command(commands)
        if self.control_mode == ControlMode.BODY:
            self.accept(sample)
            result = self.advance()
            return f"ScaleBFM BODY (five-point): {result}; sticks disabled"
        positions, rotations = self._joystick_reference(sample, commands)
        mode = 0 if self.control_mode == ControlMode.LOCOMOTION else 2
        target, action = self.policy.infer(self.simulation.inputs(
            positions, rotations, self.reference.offsets, False, control_mode=mode))
        self.simulation.step(target, action)
        return (f"ScaleBFM {self.control_mode.value} (policy mode {mode}) | "
                f"vx={commands.vx:.2f} vy={commands.vy:.2f} vyaw={commands.vyaw:.2f}")

    def _joystick_reference(self, sample, commands):
        """Commanded root trajectory for native root/root+wrist policy modes.

        These future poses are commanded goals, not predicted human movement.
        Feet are masked by the official mode table: no fabricated walking gait.
        Integration follows simulation time, so slow inference cannot run the
        reference far ahead of physics. Saturation bounds root tracking error.
        """
        sim = self.simulation
        velocity = Rotation.from_euler("z", self.heading).apply([commands.vx, commands.vy, 0.])
        self.root_target += velocity * self.dt
        error = self.root_target[:2] - sim.data.qpos[:2]
        norm = np.linalg.norm(error)
        if norm > .3:
            self.root_target[:2] = sim.data.qpos[:2] + error * (.3 / norm)
        self.heading += commands.vyaw * self.dt
        actual = rotation_wxyz(sim.data.qpos[3:7]).as_matrix()
        yaw = np.arctan2(actual[1, 0], actual[0, 0])
        error_yaw = np.arctan2(np.sin(self.heading - yaw), np.cos(self.heading - yaw))
        self.heading = yaw + np.clip(error_yaw, -.5, .5)
        times = self.reference.offsets * self.dt
        future_heading = Rotation.from_euler("z", self.heading + commands.vyaw * times)
        future_root = self.root_target + times[:, None] * velocity
        p, q = self.calibration.apply(sample)
        root_inverse = rotation_wxyz(q[0]).inv()
        local_p = root_inverse.apply(p - p[0])
        local_q = root_inverse * rotation_wxyz(q)
        positions = np.stack([r.apply(local_p) + root for r, root in zip(future_heading, future_root)])
        rotations = np.stack([wxyz(r * local_q) for r in future_heading])
        return positions, rotations
