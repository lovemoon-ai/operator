"""Configuration for the `vr_operator` LeRobot teleoperator plugin."""

from dataclasses import dataclass, field

from lerobot.teleoperators.config import TeleoperatorConfig

# The five SO-101 arm joints, in bus order. These names must match both the
# URDF joint names and the LeRobot `so_follower` motor names -- they are used to
# key the IK solver *and* the returned action dict.
ARM_JOINT_NAMES: tuple[str, ...] = (
    "shoulder_pan",
    "shoulder_lift",
    "elbow_flex",
    "wrist_flex",
    "wrist_roll",
)
GRIPPER_JOINT_NAME = "gripper"

# Full actuator list reported in `Hello`/`State` (5 arm joints + gripper).
JOINT_NAMES: tuple[str, ...] = (*ARM_JOINT_NAMES, GRIPPER_JOINT_NAME)


def _default_home_joints() -> list[float]:
    return [0.0, -90.0, 90.0, 0.0, 0.0]


# NOTE: the register_subclass decorator must sit ABOVE @dataclass, otherwise it
# registers the pre-dataclass class and draccus cannot build it from the CLI.
@TeleoperatorConfig.register_subclass("vr_operator")
@dataclass
class VROperatorConfig(TeleoperatorConfig):
    """Config for the Operator XR headset teleoperator.

    This plugin is the Python half of the `lerobot_link` driver in the Operator
    Rust adapter. The adapter *listens* and this plugin *dials in*, so the two
    processes may be started in either order and restarted independently.

    The operator->robot frame retarget (axis remap, mirroring, scaling) already
    happened in Rust, upstream of this plugin. Everything arriving here is
    already a robot base-frame target; this plugin only runs IK and returns
    joint targets.
    """

    # Where the Rust adapter listens. Format matches the Rust `Endpoint`
    # `Display`/`FromStr` impls: "uds:<path>" or "tcp:<host>:<port>".
    endpoint: str = "uds:/tmp/lerobot-vr.sock"

    # Absolute path to `so101_new_calib.urdf`. This file is NOT vendored in
    # lerobot: fetch it from the SO-ARM100 repo (or reuse the copy LeRobot
    # caches under `~/.cache/huggingface/lerobot/robot-urdfs/so101/`). See the
    # README. Validated in `connect()`.
    urdf_path: str = ""

    # End-effector frame in the URDF that IK targets.
    target_frame: str = "gripper_frame_link"

    # Home pose for the 5 arm joints, in DEGREES. Used for the `Hello` forward
    # kinematics snapshot and whenever the adapter bumps `reset_epoch`.
    home_joints: list[float] = field(default_factory=_default_home_joints)

    # Home gripper opening, in RANGE_0_100 units (NOT degrees) -- the same scale
    # `gripper.pos` is returned in, because the SO-101 follower registers its
    # gripper as `MotorNormMode.RANGE_0_100`. 85.0 is mostly-open, matching the
    # adapter's expected home snapshot.
    home_gripper: float = 85.0

    # A target older than this is treated as stale: `get_action()` holds the
    # last commanded position instead of tracking.
    command_timeout_ms: int = 500

    # How long `connect()` waits for the adapter to accept our socket before
    # giving up. Generous by default because the adapter may still be booting.
    connect_timeout_ms: int = 30000

    # Upper bound on how often `State` frames are pushed back to the adapter.
    state_report_hz: float = 20.0

    # `RobotKinematics` exposes soft-task weights rather than a tolerance or an
    # iteration cap, so convergence is judged by the residual below instead.
    # Position dominates; a small nonzero orientation weight lets the wrist
    # follow the hand without fighting position on the 5-DoF (underactuated for
    # full 6-DoF poses) SO-101.
    ik_position_weight: float = 1.0
    ik_orientation_weight: float = 0.01

    # Max acceptable IK position residual, in METERS: if the solved joints put
    # the end effector further than this from the requested target, the solve is
    # treated as non-convergent (the arm holds, an `Error` frame is sent).
    ik_position_tolerance: float = 0.02

    # `RobotKinematics.inverse_kinematics` performs ONE differential-IK step per
    # call, so the plugin iterates it until the residual is inside tolerance.
    # Reachable targets converge in 2-4 steps; the cap bounds the worst case
    # (an unreachable target) so `get_action()` stays cheap.
    ik_max_iterations: int = 10

    # --- Command-space joint rate limiting (Phase-2) --------------------------
    #
    # COMPLEMENTS (does NOT replace) LeRobot's `--robot.max_relative_target`.
    # This limiter shapes the *commanded* trajectory -- velocity, acceleration,
    # and overshoot-free deceleration -- against our own last command. It needs
    # no serial read, but for exactly that reason it cannot bound motion relative
    # to the arm's *actual* position (the teleoperator never reads the encoders):
    # at startup, if the arm is not at the assumed home, the limiter's internal
    # state disagrees with reality and provides no measured-space guarantee.
    # Keep `--robot.max_relative_target` ON as the measured-space safety floor
    # (its Present_Position read is ~1.3ms and the loop is fps/sleep-bound, so it
    # is effectively free); this limiter adds smoothness and an fps-independent
    # velocity/accel cap on top. Set `limit_enabled=False` to A/B the raw IK
    # output.
    limit_enabled: bool = True
    max_velocity_deg_s: float = 180.0
    max_acceleration_deg_s2: float = 1200.0
    # Gripper is RANGE_0_100, not degrees; limit its slew separately. 400/s =
    # full open->close in 0.25s.
    gripper_max_rate_per_s: float = 400.0

    def __post_init__(self) -> None:
        # draccus cannot decode `Literal`, and validating here keeps bad CLI
        # input from surfacing as an obscure failure much later.
        if not (self.endpoint.startswith("uds:") or self.endpoint.startswith("tcp:")):
            raise ValueError(f"endpoint must be 'uds:<path>' or 'tcp:<host>:<port>', got {self.endpoint!r}")
        if len(self.home_joints) != len(ARM_JOINT_NAMES):
            raise ValueError(
                f"home_joints must have {len(ARM_JOINT_NAMES)} entries "
                f"(one per arm joint, in degrees), got {len(self.home_joints)}"
            )
        if not 0.0 <= self.home_gripper <= 100.0:
            raise ValueError(f"home_gripper is in RANGE_0_100 units, not degrees; got {self.home_gripper}")
        if self.command_timeout_ms <= 0:
            raise ValueError(f"command_timeout_ms must be > 0, got {self.command_timeout_ms}")
        if self.connect_timeout_ms <= 0:
            raise ValueError(f"connect_timeout_ms must be > 0, got {self.connect_timeout_ms}")
        if self.state_report_hz <= 0.0:
            raise ValueError(f"state_report_hz must be > 0, got {self.state_report_hz}")
        if self.ik_position_tolerance <= 0.0:
            raise ValueError(f"ik_position_tolerance must be > 0 (meters), got {self.ik_position_tolerance}")
        if self.ik_max_iterations < 1:
            raise ValueError(f"ik_max_iterations must be >= 1, got {self.ik_max_iterations}")
        if self.max_velocity_deg_s <= 0.0:
            raise ValueError(f"max_velocity_deg_s must be > 0, got {self.max_velocity_deg_s}")
        if self.max_acceleration_deg_s2 <= 0.0:
            raise ValueError(f"max_acceleration_deg_s2 must be > 0, got {self.max_acceleration_deg_s2}")
        if self.gripper_max_rate_per_s <= 0.0:
            raise ValueError(f"gripper_max_rate_per_s must be > 0, got {self.gripper_max_rate_per_s}")
