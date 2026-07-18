"""`vr_operator` teleoperator: drives an SO-101 from an Operator XR headset."""

from __future__ import annotations

import logging
import os
import time

import numpy as np
from lerobot.model.kinematics import RobotKinematics
from lerobot.teleoperators.teleoperator import Teleoperator
from lerobot.types import RobotAction
from lerobot.utils.decorators import check_if_not_connected
from lerobot.utils.rotation import Rotation

from .config_vr_operator import (
    ARM_JOINT_NAMES,
    GRIPPER_JOINT_NAME,
    JOINT_NAMES,
    VROperatorConfig,
)
from .latency_metrics import LatencyMetrics
from .link import TargetSample, VRLink

logger = logging.getLogger(__name__)


def gripper_norm_to_pos(normalized: float) -> float:
    """Map the adapter's normalized 0..1 gripper to LeRobot's `gripper.pos`.

    The SO-101 follower registers its gripper with `MotorNormMode.RANGE_0_100`,
    NOT degrees like the five arm joints. Returning degrees here is the single
    easiest way to break this plugin, so the conversion lives in one named
    function with one test.
    """
    return float(np.clip(normalized, 0.0, 1.0)) * 100.0


def pose_to_matrix(position: list[float], rotation_xyzw: list[float]) -> np.ndarray:
    """Build a 4x4 homogeneous transform from a position (m) + xyzw quaternion."""
    matrix = np.eye(4)
    matrix[:3, :3] = Rotation.from_quat(np.asarray(rotation_xyzw, dtype=float)).as_matrix()
    matrix[:3, 3] = np.asarray(position, dtype=float)
    return matrix


def matrix_to_pose(matrix: np.ndarray) -> dict[str, list[float]]:
    """Inverse of `pose_to_matrix`, in the wire format the adapter expects."""
    return {
        "position": [float(v) for v in matrix[:3, 3]],
        "rotation": [float(v) for v in Rotation.from_matrix(matrix[:3, :3]).as_quat()],
    }


class VROperator(Teleoperator):
    """Teleoperator fed by the Operator Rust adapter over a local socket.

    The adapter has *already* retargeted the operator's hand pose into the robot
    base frame (see `pose_mapping.rs`); this plugin deliberately implements no
    frame, axis, mirror, or scale math. It reads the socket, runs IK, and
    returns joint targets.

    Safety contract: whenever the link is not positively commanding motion
    (disabled, e-stopped, stale, unseeded, or IK non-convergence),
    `get_action()` re-commands the last setpoint so the arm holds. It **never**
    returns `{}` -- an empty action is a crash, not a no-op; see `get_action`.
    """

    config_class = VROperatorConfig
    name = "vr_operator"

    def __init__(self, config: VROperatorConfig):
        # The connection-state attribute must exist before anything that can
        # raise: the base class `__del__` reads `self.is_connected`, which would
        # otherwise `AttributeError` if `__init__` bailed out early.
        self._link: VRLink | None = None

        super().__init__(config)
        self.config = config

        self._kin: RobotKinematics | None = None

        # Our own last commanded joints. `get_action()` cannot see the
        # follower's measured state, so this doubles as the IK initial guess.
        self._last_q: list[float] = list(config.home_joints)
        self._last_gripper: float = float(config.home_gripper)

        # Watches VRLink.reset_generation(), which survives adapter restarts;
        # comparing raw reset_epochs would silently stop firing after one.
        self._reset_generation_seen = 0
        self._reset_active = False
        self._reset_at = 0.0

        self._last_ik_error: float | None = None
        self._last_state_sent = 0.0
        # Last Error message sent, so a sustained fault is reported once.
        self._last_error: str | None = None

        # Phase-1 latency instrumentation (pure logging; no control effect).
        self._metrics = LatencyMetrics()
        self._last_ik_iters = 0
        # seq of the last target we actually consumed, to count fresh vs repeat.
        self._last_consumed_seq = -1

    # -- features ----------------------------------------------------------

    @property
    def action_features(self) -> dict[str, type]:
        # Must match `get_action()`'s keys exactly; asserted by a unit test.
        return {f"{name}.pos": float for name in JOINT_NAMES}

    @property
    def feedback_features(self) -> dict[str, type]:
        return {}

    # -- lifecycle ---------------------------------------------------------

    @property
    def is_connected(self) -> bool:
        # Tracks the *link*, not the socket: the reader thread reconnects on its
        # own, and an adapter restart must not tear down the teleop loop. While
        # the socket is down the link reports the safe (disabled) state, so
        # `get_action()` holds the last setpoint.
        return self._link is not None and self._link.is_running

    def connect(self, calibrate: bool = True) -> None:
        if self.is_connected:
            raise ConnectionError(f"{self} is already connected.")

        urdf_path = self._resolve_urdf_path()
        self._kin = RobotKinematics(
            urdf_path=urdf_path,
            target_frame_name=self.config.target_frame,
            # Explicit: the URDF also declares a revolute `gripper` joint, and
            # letting placo default to every joint would have IK drive the jaw.
            joint_names=list(ARM_JOINT_NAMES),
        )

        # The adapter blocks its own device connect until `Hello` arrives, and
        # has no forward kinematics of its own, so the FK snapshot below is what
        # unblocks it. See the bootstrap caveat in the README: this claims the
        # arm is at `home_joints`, which is only true if it actually is.
        self._last_q = list(self.config.home_joints)
        self._last_gripper = float(self.config.home_gripper)

        link = VRLink(self.config.endpoint, self.config.connect_timeout_ms / 1000.0)
        link.set_hello(self._snapshot_payload("Hello"))
        link.start()
        self._link = link

        if calibrate and not self.is_calibrated:
            self.calibrate()

        logger.info("%s connected to %s.", self, self.config.endpoint)

    def _resolve_urdf_path(self) -> str:
        """Return a usable URDF path, or explain precisely how to get one."""
        if self.config.urdf_path:
            if not os.path.isfile(self.config.urdf_path):
                raise FileNotFoundError(
                    f"urdf_path {self.config.urdf_path!r} does not exist. Point "
                    f"--teleop.urdf_path at `so101_new_calib.urdf` (see this plugin's README)."
                )
            return self.config.urdf_path

        cached = self._cached_urdf_path()
        if cached is not None:
            logger.info("urdf_path not set; using the LeRobot URDF cache at %s", cached)
            return cached

        raise FileNotFoundError(
            "No URDF configured and none found in the LeRobot cache. The SO-101 URDF is not "
            "vendored in lerobot: fetch `so101_new_calib.urdf` (plus its meshes) from the "
            "SO-ARM100 repo <https://github.com/TheRobotStudio/SO-ARM100> and pass "
            "--teleop.urdf_path=/path/to/so101_new_calib.urdf"
        )

    @staticmethod
    def _cached_urdf_path() -> str | None:
        """Best-effort reuse of the URDF LeRobot's own examples cache.

        Purely a convenience: `urdf_path` stays the supported, explicit route.
        """
        try:
            from lerobot.utils.constants import HF_LEROBOT_HOME
        except ImportError:  # pragma: no cover
            return None
        candidate = HF_LEROBOT_HOME / "robot-urdfs" / "so101" / "so101_new_calib.urdf"
        return str(candidate) if candidate.is_file() else None

    @property
    def is_calibrated(self) -> bool:
        # Nothing to calibrate on this side: the operator->robot retarget (and
        # its calibration) lives in the Rust adapter, and joint calibration
        # belongs to the follower.
        return True

    def calibrate(self) -> None:
        pass

    def configure(self) -> None:
        pass

    @check_if_not_connected
    def disconnect(self) -> None:
        assert self._link is not None
        self._link.stop()
        self._link = None
        self._kin = None
        logger.info("%s disconnected.", self)

    # -- action ------------------------------------------------------------

    @check_if_not_connected
    def get_action(self) -> RobotAction:
        """Timing wrapper around `_get_action_impl` (Phase-1 instrumentation).

        Measures whole-call time and flushes the 1Hz latency summary. The
        `finally` guarantees the sample is recorded on every return path,
        including the many `_hold()` early-outs, without touching control logic.
        """
        t0 = time.perf_counter()
        try:
            return self._get_action_impl()
        finally:
            self._metrics.record_call((time.perf_counter() - t0) * 1000.0)
            self._metrics.maybe_flush()

    def _get_action_impl(self) -> RobotAction:
        """Latest joint targets, or the last commanded ones to hold. Never blocks.

        Every path returns a full six-key action -- **never** `{}`. An empty
        action is not a no-op in LeRobot, it is a crash:
        `SOFollower.send_action({})` filters to an empty `goal_pos`, and
        `MotorsBus.sync_write("Goal_Position", {})` then does
        `next(iter(models))` over an empty list and raises `StopIteration`
        (lerobot 0.6.0, motors_bus.py:1244). Since the only way to signal "no
        change" is to re-command the current setpoint, holding means returning
        `_last_q` / `_last_gripper`.

        This is an upstream bug, not a quirk of this plugin -- LeRobot's own
        `phone` teleoperator returns `{}` and takes the same crash against an
        SO-101 follower. It would fire here every time the operator released the
        deadman, so it cannot be worked around anywhere but here.
        """
        assert self._link is not None

        control = self._link.control()
        now = time.monotonic()

        # A reset is an edge. The link exposes it as a process-monotonic
        # generation (see VRLink.reset_generation) that is robust across adapter
        # restarts, unlike the raw reset_epoch. Consume the edge here, but do not
        # *apply* it until we know we are not e-stopped.
        reset_generation = self._link.reset_generation()
        reset_bumped = reset_generation != self._reset_generation_seen
        if reset_bumped:
            self._reset_generation_seen = reset_generation

        # E-stop outranks everything, including a pending reset. Applying the
        # reset first would overwrite `_last_q` with home and the hold below
        # would then drive the arm there -- the exact opposite of stopping. The
        # edge stays consumed, so clearing the stop does not fire a deferred
        # move either: an e-stop must not queue motion for later.
        if control.stopped:
            self._reset_active = False
            self._report_state()
            return self._hold()

        if reset_bumped:
            self._reset_active = True
            self._reset_at = now
            self._last_q = list(self.config.home_joints)
            self._last_gripper = float(self.config.home_gripper)
            logger.info("reset requested (epoch %d); commanding home", control.reset_epoch)

        target = self._link.latest_target()
        fresh = (
            target is not None and (now - target.recv_monotonic) * 1000.0 <= self.config.command_timeout_ms
        )

        if self._reset_active:
            # Keep commanding home until the operator actually starts driving.
            # Returning home for a single tick would strand the arm mid-slew,
            # because `max_relative_target` caps each step's travel.
            if control.enabled and fresh and target.recv_monotonic > self._reset_at:
                self._reset_active = False
            else:
                # Honoured even while disabled: reset is an explicit operator
                # action, and the bootstrap (README) depends on being able to
                # send the arm home *before* the first enable.
                self._report_state()
                return self._hold()

        if not control.enabled:  # deadman released
            self._report_state()
            return self._hold()
        if target is None:  # nothing received yet
            self._report_state()
            return self._hold()
        if not fresh:  # link stalled or operator stopped moving
            self._report_state()
            return self._hold()

        ik_t0 = time.perf_counter()
        joints = self._solve(target)
        ik_ms = (time.perf_counter() - ik_t0) * 1000.0
        if joints is None:  # IK non-convergent; _solve() already sent an Error
            return self._hold()

        # Phase-1: record the consume-path segments for this fresh command.
        # age_uds spans adapter publish -> here (same host wall clock); None if
        # the adapter did not stamp ts_ns.
        fresh = target.seq != self._last_consumed_seq
        self._last_consumed_seq = target.seq
        age_uds_ms = (time.time_ns() - target.ts_ns) / 1e6 if target.ts_ns else None
        self._metrics.record_solve(
            age_uds_ms=age_uds_ms, ik_ms=ik_ms, ik_iters=self._last_ik_iters, fresh=fresh
        )

        # Re-arm the error edge: if this fault recurs later it is news again.
        self._last_error = None
        self._last_q = joints
        if target.gripper is not None:
            self._last_gripper = gripper_norm_to_pos(target.gripper)

        self._report_state()
        return self._action(self._last_q, self._last_gripper)

    def _solve(self, target: TargetSample) -> list[float] | None:
        """Resolve a target to 5 arm joint angles (deg), or `None` on failure."""
        if target.positions is not None:
            # Direct passthrough: the adapter is in joint mode, no IK.
            if len(target.positions) != len(ARM_JOINT_NAMES):
                self._fail(f"positions must contain {len(ARM_JOINT_NAMES)} floats")
                return None
            self._last_ik_error = None
            self._last_ik_iters = 0
            return [float(v) for v in target.positions]

        if target.ee_position is None:
            # Gripper-only update: hold the joints we last commanded.
            self._last_ik_iters = 0
            return list(self._last_q)

        assert self._kin is not None
        desired = pose_to_matrix(target.ee_position, target.ee_rotation or [0.0, 0.0, 0.0, 1.0])

        # `RobotKinematics.inverse_kinematics` runs a SINGLE QP iteration of
        # placo's differential solver, not a solve-to-convergence: it steps the
        # configuration toward the target and returns. One call therefore leaves
        # a residual proportional to the step size (a 5cm target jump lands
        # ~2.3cm away), so the loop below iterates -- feeding each solution back
        # as the next initial guess -- until the residual is inside tolerance.
        # Without it, any jump bigger than the tolerance (the first target after
        # an enable, say) would be judged non-convergent and rejected forever:
        # `_last_q` never advances on failure, so the arm would deadlock.
        # Reachable targets settle in 2-4 iterations.
        solution = np.asarray(self._last_q, dtype=float)
        error = float("inf")
        iters = 0
        for _ in range(self.config.ik_max_iterations):
            iters += 1
            solution = self._kin.inverse_kinematics(
                solution,
                desired,
                position_weight=self.config.ik_position_weight,
                orientation_weight=self.config.ik_orientation_weight,
            )
            if not np.all(np.isfinite(solution)):
                self._fail("IK produced non-finite joint angles")
                return None
            # The frame task is *soft*, so the solver always "succeeds" and
            # exposes no convergence flag. The position residual is the only
            # honest signal: an unreachable target simply settles short.
            reached = self._kin.forward_kinematics(solution)
            error = float(np.linalg.norm(reached[:3, 3] - desired[:3, 3]))
            if error <= self.config.ik_position_tolerance:
                break

        self._last_ik_iters = iters
        self._last_ik_error = error
        if error > self.config.ik_position_tolerance:
            self._fail(
                f"IK did not converge after {self.config.ik_max_iterations} iterations: "
                f"{error * 1000:.1f}mm from the requested target (tolerance "
                f"{self.config.ik_position_tolerance * 1000:.1f}mm); target likely out of reach"
            )
            return None

        return [float(v) for v in solution[: len(ARM_JOINT_NAMES)]]

    def _fail(self, msg: str) -> None:
        """Log and surface a plugin-side failure to the adapter.

        Edge-triggered: the adapter turns an `Error` into a driver error on its
        next write, and `get_action()` runs at the loop rate, so re-sending every
        tick would flood the link for one sustained fault (e.g. the operator
        holding their hand out of reach).
        """
        logger.warning("%s", msg)
        if self._link is not None and msg != self._last_error:
            self._link.send({"type": "Error", "msg": msg})
        self._last_error = msg

    def _hold(self) -> RobotAction:
        """Re-command the last setpoint, which is how "no change" is expressed.

        Used for every idle path: deadman released, e-stop, stale link, no
        target yet, IK non-convergent. See `get_action`'s docstring for why this
        cannot be `{}`.

        Before the first target arrives `_last_q` is `home_joints`, so the first
        tick after `lerobot-teleoperate` starts commands home. That is a real
        movement, and it is unavoidable: `send_action` has no no-op encoding, and
        a teleoperator cannot see the follower's measured position (`get_action`
        takes no arguments, and the stock loop only routes observations to
        `send_feedback` for `unitree_g1`). Commanding home is the only defined
        pose available. `--robot.max_relative_target` bounds each step of the
        resulting slew; the README calls this out.
        """
        self._metrics.record_hold()
        return self._action(self._last_q, self._last_gripper)

    def _action(self, joints: list[float], gripper: float) -> RobotAction:
        """Build the action dict. Arm joints in DEGREES, gripper in RANGE_0_100."""
        action: RobotAction = {
            f"{name}.pos": float(q) for name, q in zip(ARM_JOINT_NAMES, joints, strict=True)
        }
        action[f"{GRIPPER_JOINT_NAME}.pos"] = float(gripper)
        return action

    # -- state reporting ---------------------------------------------------

    def _snapshot_payload(self, kind: str) -> dict:
        """`Hello`/`State` body: 6 positions + the end-effector pose.

        `positions` is 5 arm joints in degrees followed by the gripper in
        RANGE_0_100 -- matching what the adapter's own stub plugin reports.
        """
        assert self._kin is not None
        ee = matrix_to_pose(self._kin.forward_kinematics(np.asarray(self._last_q, dtype=float)))
        payload: dict = {
            "type": kind,
            "joint_names": list(JOINT_NAMES),
            "positions": [*(float(q) for q in self._last_q), float(self._last_gripper)],
            "ee": ee,
        }
        if kind == "State":
            payload.pop("joint_names")
            payload["ik_error"] = self._last_ik_error
            payload["ts_ns"] = time.time_ns()
        return payload

    def _report_state(self) -> None:
        """Push a rate-limited `State` frame back to the adapter.

        Rate-limited because the adapter only uses this for its snapshot and
        telemetry, while the teleop loop may run well above `state_report_hz`.
        """
        now = time.monotonic()
        if now - self._last_state_sent < 1.0 / self.config.state_report_hz:
            return
        self._last_state_sent = now
        if self._link is None:
            return
        payload = self._snapshot_payload("State")
        self._link.send(payload)
        # Keep the reconnect `Hello` honest: after the first one, the truth is
        # wherever we last commanded the arm, not `home_joints`.
        hello = dict(payload)
        hello["type"] = "Hello"
        hello["joint_names"] = list(JOINT_NAMES)
        hello.pop("ik_error", None)
        hello.pop("ts_ns", None)
        self._link.set_hello(hello)

    # -- feedback ----------------------------------------------------------

    def send_feedback(self, feedback: dict[str, float]) -> None:
        # No haptics wired up. The stock teleop loop only calls this for
        # unitree_g1, so raising here is the documented lerobot convention.
        raise NotImplementedError
