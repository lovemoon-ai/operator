"""Unit tests for the `vr_operator` teleoperator logic.

No adapter, no headset, no hardware, and no placo: the link and the kinematics
solver are injected, so these cover the gripper unit conversion, the `{}`
safe-hold contract, and action/feature agreement -- the parts that are pure
logic. Real motion coverage belongs on the device.
"""

import time

import numpy as np
import pytest

from lerobot_teleoperator_vr_operator.config_vr_operator import JOINT_NAMES, VROperatorConfig
from lerobot_teleoperator_vr_operator.link import ControlState, TargetSample
from lerobot_teleoperator_vr_operator.vr_operator import (
    VROperator,
    gripper_norm_to_pos,
    matrix_to_pose,
    pose_to_matrix,
)

HOME_JOINTS = [0.0, -90.0, 90.0, 0.0, 0.0]
HOME_GRIPPER = 85.0
ACTION_KEYS = {
    "shoulder_pan.pos",
    "shoulder_lift.pos",
    "elbow_flex.pos",
    "wrist_flex.pos",
    "wrist_roll.pos",
    "gripper.pos",
}


class FakeLink:
    """Stands in for `VRLink`, with no socket behind it."""

    is_running = True

    def __init__(
        self,
        control: ControlState | None = None,
        target: TargetSample | None = None,
        reset_generation: int = 0,
    ):
        self._control = control or ControlState()
        self._target = target
        # A reset is signalled by a change in this counter, not by a nonzero
        # reset_epoch -- matching the real VRLink, which re-baselines the epoch
        # per connection so a restarted adapter's epoch=0 is not a false edge.
        self._reset_generation = reset_generation
        self.sent: list[dict] = []
        self.hello: dict | None = None

    def control(self) -> ControlState:
        return self._control

    def reset_generation(self) -> int:
        return self._reset_generation

    def latest_target(self) -> TargetSample | None:
        return self._target

    def send(self, obj: dict) -> None:
        self.sent.append(obj)

    def set_hello(self, payload: dict) -> None:
        self.hello = payload

    def stop(self) -> None:
        pass

    def errors(self) -> list[dict]:
        return [m for m in self.sent if m["type"] == "Error"]


class FakeKinematics:
    """Stands in for `RobotKinematics` (placo is not needed for these tests).

    `forward_kinematics` always reports the identity pose, so an IK request for
    a target away from the origin reads as a large residual -- which is exactly
    how the real non-convergence path is detected.
    """

    def __init__(self, solution: list[float] | None = None):
        self.solution = solution or [1.0, 2.0, 3.0, 4.0, 5.0]
        self.last_initial_guess: np.ndarray | None = None
        self.ik_calls = 0

    def forward_kinematics(self, joint_pos_deg: np.ndarray) -> np.ndarray:
        return np.eye(4)

    def inverse_kinematics(
        self, current_joint_pos, desired_ee_pose, position_weight=1.0, orientation_weight=0.01
    ) -> np.ndarray:
        self.ik_calls += 1
        self.last_initial_guess = np.asarray(current_joint_pos, dtype=float).copy()
        return np.asarray(self.solution, dtype=float)


class SteppingKinematics:
    """Mimics the real solver's differential behaviour.

    `RobotKinematics.inverse_kinematics` runs ONE QP step per call, closing only
    part of the gap, so the plugin must iterate it. This fake halves the
    remaining error per call, reproducing that contract.
    """

    def __init__(self, target_x: float):
        self._target_x = target_x
        self._x = 0.0
        self.ik_calls = 0

    def forward_kinematics(self, joint_pos_deg: np.ndarray) -> np.ndarray:
        matrix = np.eye(4)
        matrix[0, 3] = self._x
        return matrix

    def inverse_kinematics(
        self, current_joint_pos, desired_ee_pose, position_weight=1.0, orientation_weight=0.01
    ) -> np.ndarray:
        self.ik_calls += 1
        self._x += (self._target_x - self._x) / 2.0  # close half the gap
        return np.asarray([self._x, 0.0, 0.0, 0.0, 0.0], dtype=float)


def make_operator(tmp_path, link: FakeLink, kin: FakeKinematics | None = None, **overrides):
    config = VROperatorConfig(calibration_dir=tmp_path, **overrides)
    operator = VROperator(config)
    # Bypass connect(): it would need a real adapter socket and a real URDF.
    operator._link = link
    operator._kin = kin or FakeKinematics()
    return operator


def fresh_target(**kwargs) -> TargetSample:
    kwargs.setdefault("recv_monotonic", time.monotonic())
    return TargetSample(**kwargs)


# ---------------------------------------------------------------------------
# Units: the #1 bug in this plugin
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("normalized", "expected"),
    [(0.0, 0.0), (0.5, 50.0), (1.0, 100.0), (0.25, 25.0), (0.853, 85.3)],
)
def test_gripper_maps_0_1_to_range_0_100(normalized, expected):
    # RANGE_0_100, never degrees: SO-101's follower registers the gripper as
    # MotorNormMode.RANGE_0_100 while the five arm joints are DEGREES.
    assert gripper_norm_to_pos(normalized) == pytest.approx(expected)


@pytest.mark.parametrize(("normalized", "expected"), [(-0.5, 0.0), (1.5, 100.0)])
def test_gripper_clamps_out_of_range_input(normalized, expected):
    assert gripper_norm_to_pos(normalized) == pytest.approx(expected)


def test_gripper_0_5_maps_to_50_in_the_action(tmp_path):
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(positions=[0.0, 0.0, 0.0, 0.0, 0.0], gripper=0.5),
    )
    action = make_operator(tmp_path, link).get_action()
    assert action["gripper.pos"] == pytest.approx(50.0)


# ---------------------------------------------------------------------------
# Pose helpers
# ---------------------------------------------------------------------------


def test_pose_matrix_round_trip_preserves_position_and_xyzw_quaternion():
    position = [0.31, -0.02, 0.18]
    rotation = [0.0, 0.7071067811865476, 0.0, 0.7071067811865476]  # 90deg about +y
    pose = matrix_to_pose(pose_to_matrix(position, rotation))
    assert pose["position"] == pytest.approx(position)
    assert pose["rotation"] == pytest.approx(rotation, abs=1e-9)


def test_pose_to_matrix_places_position_in_the_translation_column():
    matrix = pose_to_matrix([0.25, 0.0, 0.2], [0.0, 0.0, 0.0, 1.0])
    assert matrix[:3, 3] == pytest.approx([0.25, 0.0, 0.2])
    assert matrix[:3, :3] == pytest.approx(np.eye(3))


# ---------------------------------------------------------------------------
# The safe-hold contract
#
# Every idle path must re-command the last setpoint. `{}` is NOT a safe no-op:
# `SOFollower.send_action({})` -> `sync_write("Goal_Position", {})` ->
# `next(iter([]))` -> StopIteration (lerobot 0.6.0 motors_bus.py:1244), which
# kills the whole teleop loop. This was found only on real hardware, because an
# earlier version of these tests asserted `== {}` and so pinned the bug in place.
# ---------------------------------------------------------------------------


def idle_links() -> list[tuple[str, FakeLink]]:
    """Every state in which the plugin is not actively tracking a target."""
    live = fresh_target(positions=[1.0, 2.0, 3.0, 4.0, 5.0], gripper=0.5)
    stale = fresh_target(
        positions=[1.0, 2.0, 3.0, 4.0, 5.0],
        gripper=0.5,
        recv_monotonic=time.monotonic() - 5.0,
    )
    return [
        ("unseeded", FakeLink(control=ControlState(enabled=True), target=None)),
        ("deadman released", FakeLink(control=ControlState(enabled=False), target=live)),
        ("e-stopped", FakeLink(control=ControlState(enabled=True, stopped=True), target=live)),
        ("stale target", FakeLink(control=ControlState(enabled=True), target=stale)),
        (
            "stop outranks pending reset",
            FakeLink(control=ControlState(enabled=True, stopped=True), reset_generation=1),
        ),
    ]


@pytest.mark.parametrize("label,link", idle_links(), ids=[label for label, _ in idle_links()])
def test_idle_paths_never_return_an_empty_action(tmp_path, label, link):
    """The regression guard: an empty action crashes `send_action`."""
    action = make_operator(tmp_path, link, command_timeout_ms=500).get_action()
    assert action != {}, f"{label}: empty action would raise StopIteration in send_action"
    assert set(action) == {f"{n}.pos" for n in JOINT_NAMES}, f"{label}: must be a full 6-key action"
    assert all(isinstance(v, float) for v in action.values())


@pytest.mark.parametrize("label,link", idle_links(), ids=[label for label, _ in idle_links()])
def test_idle_paths_hold_the_last_commanded_setpoint(tmp_path, label, link):
    """Holding means re-commanding the last setpoint, not moving somewhere new."""
    operator = make_operator(
        tmp_path, link, command_timeout_ms=500, home_joints=HOME_JOINTS, home_gripper=HOME_GRIPPER
    )
    # Pretend the arm was last driven somewhere other than home, so a bug that
    # returns home instead of the true last setpoint cannot pass.
    operator._last_q = [11.0, 22.0, 33.0, 44.0, 55.0]
    operator._last_gripper = 42.0

    action = operator.get_action()
    assert action == {
        "shoulder_pan.pos": 11.0,
        "shoulder_lift.pos": 22.0,
        "elbow_flex.pos": 33.0,
        "wrist_flex.pos": 44.0,
        "wrist_roll.pos": 55.0,
        "gripper.pos": 42.0,
    }, f"{label}: must hold the last setpoint"


def test_first_tick_before_any_target_commands_home(tmp_path):
    """Documents the one unavoidable startup movement.

    A teleoperator cannot see the follower's measured position, and
    `send_action` has no no-op encoding, so the first tick must command *some*
    pose. Home is the only defined one. `--robot.max_relative_target` bounds the
    resulting slew. Asserted here so the behaviour is deliberate, not incidental.
    """
    link = FakeLink(control=ControlState(enabled=True), target=None)
    operator = make_operator(tmp_path, link, home_joints=HOME_JOINTS, home_gripper=HOME_GRIPPER)
    action = operator.get_action()
    assert action["shoulder_lift.pos"] == HOME_JOINTS[1]
    assert action["gripper.pos"] == HOME_GRIPPER


def test_get_action_accepts_a_target_just_inside_the_timeout(tmp_path):
    target = fresh_target(
        positions=[1.0, 2.0, 3.0, 4.0, 5.0],
        gripper=0.5,
        recv_monotonic=time.monotonic() - 0.05,
    )
    link = FakeLink(control=ControlState(enabled=True), target=target)
    operator = make_operator(tmp_path, link, command_timeout_ms=500)
    # Distinct from home, so this proves tracking rather than holding.
    operator._last_q = [11.0, 22.0, 33.0, 44.0, 55.0]
    assert operator.get_action()["gripper.pos"] == 50.0


# ---------------------------------------------------------------------------
# Action shape / features
# ---------------------------------------------------------------------------


def test_action_features_match_get_action_keys(tmp_path):
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(positions=[1.0, 2.0, 3.0, 4.0, 5.0], gripper=0.5),
    )
    operator = make_operator(tmp_path, link)
    action = operator.get_action()

    assert set(operator.action_features) == ACTION_KEYS
    assert set(action) == set(operator.action_features)
    assert all(isinstance(v, float) for v in action.values())
    assert all(t is float for t in operator.action_features.values())


def test_feedback_features_is_empty_and_send_feedback_raises(tmp_path):
    operator = make_operator(tmp_path, FakeLink())
    assert operator.feedback_features == {}
    with pytest.raises(NotImplementedError):
        operator.send_feedback({})


# ---------------------------------------------------------------------------
# Target modes
# ---------------------------------------------------------------------------


def test_direct_positions_pass_through_without_ik(tmp_path):
    kin = FakeKinematics()
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(positions=[10.0, -20.0, 30.0, -40.0, 50.0], gripper=0.0),
    )
    action = make_operator(tmp_path, link, kin=kin).get_action()

    assert action["shoulder_pan.pos"] == pytest.approx(10.0)
    assert action["shoulder_lift.pos"] == pytest.approx(-20.0)
    assert action["elbow_flex.pos"] == pytest.approx(30.0)
    assert action["wrist_flex.pos"] == pytest.approx(-40.0)
    assert action["wrist_roll.pos"] == pytest.approx(50.0)
    assert action["gripper.pos"] == pytest.approx(0.0)
    assert kin.last_initial_guess is None, "direct mode must not run IK"


def test_direct_positions_of_the_wrong_length_report_an_error(tmp_path):
    link = FakeLink(
        control=ControlState(enabled=True), target=fresh_target(positions=[1.0, 2.0], gripper=0.5)
    )
    operator = make_operator(tmp_path, link)
    operator._last_q = [11.0, 22.0, 33.0, 44.0, 55.0]
    assert operator.get_action()["shoulder_pan.pos"] == 11.0, "a bad target must hold, not move"
    assert "positions must contain 5 floats" in link.errors()[0]["msg"]


def test_ee_pose_runs_ik_seeded_from_the_last_commanded_joints(tmp_path):
    kin = FakeKinematics(solution=[1.0, 2.0, 3.0, 4.0, 5.0])
    # FakeKinematics' FK reports the identity pose, so an origin target has a
    # zero residual and reads as converged.
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(ee_position=[0.0, 0.0, 0.0], ee_rotation=[0.0, 0.0, 0.0, 1.0]),
    )
    operator = make_operator(tmp_path, link, kin=kin, home_joints=HOME_JOINTS)

    action = operator.get_action()
    # get_action() cannot see the follower's measured state, so IK must be
    # seeded from the plugin's own last commanded joints (home on the first call).
    assert kin.last_initial_guess == pytest.approx(HOME_JOINTS)
    assert action["shoulder_pan.pos"] == pytest.approx(1.0)
    assert link.errors() == []

    # Second call seeds from the joints just commanded.
    operator.get_action()
    assert kin.last_initial_guess == pytest.approx([1.0, 2.0, 3.0, 4.0, 5.0])


def test_unreachable_ee_pose_holds_and_reports_an_error(tmp_path):
    # FK reports the origin, so a 1m target leaves a 1m residual: non-convergent.
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(ee_position=[1.0, 0.0, 0.0], ee_rotation=[0.0, 0.0, 0.0, 1.0]),
    )
    operator = make_operator(tmp_path, link, ik_position_tolerance=0.02)
    operator._last_q = [11.0, 22.0, 33.0, 44.0, 55.0]

    # Hold, not `{}`: an out-of-reach hand must leave the arm parked where it
    # is, and `{}` would crash the loop rather than stop it.
    assert operator.get_action()["shoulder_pan.pos"] == 11.0
    assert "IK did not converge" in link.errors()[0]["msg"]


def test_a_sustained_ik_failure_reports_one_error_not_one_per_tick(tmp_path):
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(ee_position=[1.0, 0.0, 0.0], ee_rotation=[0.0, 0.0, 0.0, 1.0]),
    )
    operator = make_operator(tmp_path, link)
    for _ in range(5):
        operator.get_action()
    # The adapter turns an Error into a driver error on its next write; one
    # sustained out-of-reach hand must not flood the link at loop rate.
    assert len(link.errors()) == 1


def test_ik_iterates_until_the_residual_is_inside_tolerance(tmp_path):
    # The real solver takes ONE differential step per call, so a target further
    # away than the tolerance must not be judged unreachable after one step --
    # that would deadlock the arm, since _last_q never advances on failure.
    kin = SteppingKinematics(target_x=0.1)
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(ee_position=[0.1, 0.0, 0.0], ee_rotation=[0.0, 0.0, 0.0, 1.0]),
    )
    operator = make_operator(tmp_path, link, kin=kin, ik_position_tolerance=0.02, ik_max_iterations=10)

    action = operator.get_action()
    assert action != {}, "a reachable target must not be rejected after a single IK step"
    assert kin.ik_calls == 3, "0.1 -> 0.05 -> 0.025 -> 0.0125 <= 0.02 tolerance"
    assert link.errors() == []


def test_ik_iteration_is_capped(tmp_path):
    kin = FakeKinematics()  # FK stuck at the origin: never converges on a far target
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(ee_position=[1.0, 0.0, 0.0], ee_rotation=[0.0, 0.0, 0.0, 1.0]),
    )
    operator = make_operator(tmp_path, link, kin=kin, ik_max_iterations=4)
    operator._last_q = [11.0, 22.0, 33.0, 44.0, 55.0]

    assert operator.get_action()["shoulder_pan.pos"] == 11.0, "non-convergent IK must hold"
    assert kin.ik_calls == 4, "an unreachable target must not spin past the cap"


def test_gripper_only_target_holds_the_last_commanded_joints(tmp_path):
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(positions=[10.0, -20.0, 30.0, -40.0, 50.0], gripper=1.0),
    )
    operator = make_operator(tmp_path, link)
    operator.get_action()

    # A gripper-only Target carries neither ee_pose nor positions.
    link._target = fresh_target(gripper=0.0)
    action = operator.get_action()

    assert action["shoulder_pan.pos"] == pytest.approx(10.0)
    assert action["wrist_roll.pos"] == pytest.approx(50.0)
    assert action["gripper.pos"] == pytest.approx(0.0)


def test_target_without_a_gripper_field_keeps_the_last_gripper(tmp_path):
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(positions=[0.0] * 5, gripper=0.25),
    )
    operator = make_operator(tmp_path, link)
    assert operator.get_action()["gripper.pos"] == pytest.approx(25.0)

    link._target = fresh_target(positions=[0.0] * 5, gripper=None)
    assert operator.get_action()["gripper.pos"] == pytest.approx(25.0)


# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------


def test_reset_generation_bump_commands_home(tmp_path):
    link = FakeLink(control=ControlState(enabled=True), reset_generation=1)
    operator = make_operator(tmp_path, link, home_joints=HOME_JOINTS, home_gripper=HOME_GRIPPER)

    action = operator.get_action()
    assert action["shoulder_pan.pos"] == pytest.approx(0.0)
    assert action["shoulder_lift.pos"] == pytest.approx(-90.0)
    assert action["elbow_flex.pos"] == pytest.approx(90.0)
    assert action["gripper.pos"] == pytest.approx(HOME_GRIPPER)


def test_reset_is_honoured_while_disabled(tmp_path):
    # The bootstrap depends on this: the operator homes the arm *before* the
    # first enable so that Hello's FK(home_joints) is actually true.
    link = FakeLink(control=ControlState(enabled=False), reset_generation=1)
    operator = make_operator(tmp_path, link, home_joints=HOME_JOINTS)
    assert operator.get_action()["shoulder_lift.pos"] == pytest.approx(-90.0)


def test_reset_keeps_commanding_home_until_a_new_target_arrives(tmp_path):
    link = FakeLink(control=ControlState(enabled=True), reset_generation=1)
    operator = make_operator(tmp_path, link, home_joints=HOME_JOINTS)

    # Home must be re-commanded every tick: max_relative_target caps each step,
    # so commanding it once would strand the arm part-way through the slew.
    for _ in range(3):
        assert operator.get_action()["shoulder_lift.pos"] == pytest.approx(-90.0)

    link._target = fresh_target(positions=[10.0, -20.0, 30.0, -40.0, 50.0], gripper=0.5)
    assert operator.get_action()["shoulder_pan.pos"] == pytest.approx(10.0)


def test_reset_ignores_a_target_predating_the_reset(tmp_path):
    stale_but_fresh_enough = fresh_target(
        positions=[10.0, -20.0, 30.0, -40.0, 50.0],
        gripper=0.5,
        recv_monotonic=time.monotonic() - 0.05,
    )
    link = FakeLink(
        control=ControlState(enabled=True), target=stale_but_fresh_enough, reset_generation=1
    )
    operator = make_operator(tmp_path, link, home_joints=HOME_JOINTS)
    # The target arrived before the reset, so it must not cancel the homing.
    assert operator.get_action()["shoulder_lift.pos"] == pytest.approx(-90.0)


def test_same_reset_generation_does_not_re_home(tmp_path):
    link = FakeLink(control=ControlState(enabled=True), reset_generation=1)
    operator = make_operator(tmp_path, link, home_joints=HOME_JOINTS)
    operator.get_action()

    link._target = fresh_target(positions=[10.0, -20.0, 30.0, -40.0, 50.0], gripper=0.5)
    assert operator.get_action()["shoulder_pan.pos"] == pytest.approx(10.0)
    # An unchanged generation (e.g. a re-sent Control after reconnect) is not a
    # fresh edge and must not re-home.
    assert operator.get_action()["shoulder_pan.pos"] == pytest.approx(10.0)


# ---------------------------------------------------------------------------
# State reporting
# ---------------------------------------------------------------------------


def test_state_frames_are_rate_limited(tmp_path):
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(positions=[0.0] * 5, gripper=0.5),
    )
    operator = make_operator(tmp_path, link, state_report_hz=1.0)

    for _ in range(10):
        operator.get_action()

    states = [m for m in link.sent if m["type"] == "State"]
    assert len(states) == 1, "at 1Hz, ten back-to-back calls must emit one State"
    assert len(states[0]["positions"]) == 6
    assert states[0]["positions"][5] == pytest.approx(50.0)  # gripper in RANGE_0_100
    assert set(states[0]["ee"]) == {"position", "rotation"}


def test_state_reporting_refreshes_the_reconnect_hello(tmp_path):
    link = FakeLink(
        control=ControlState(enabled=True),
        target=fresh_target(positions=[10.0, -20.0, 30.0, -40.0, 50.0], gripper=0.5),
    )
    operator = make_operator(tmp_path, link)
    operator.get_action()

    # After the first Hello, the truth is wherever we last commanded the arm.
    assert link.hello["type"] == "Hello"
    assert link.hello["positions"][:5] == pytest.approx([10.0, -20.0, 30.0, -40.0, 50.0])
    assert "ik_error" not in link.hello
    assert link.hello["joint_names"][5] == "gripper"


# ---------------------------------------------------------------------------
# Config validation (draccus cannot decode Literal, so this is hand-rolled)
# ---------------------------------------------------------------------------


def test_config_defaults_match_the_adapter_home_snapshot():
    config = VROperatorConfig()
    assert config.home_joints == [0.0, -90.0, 90.0, 0.0, 0.0]
    # 85.0 is RANGE_0_100 (mostly open), matching the adapter's expected home.
    assert config.home_gripper == 85.0
    assert config.endpoint == "uds:/tmp/lerobot-vr.sock"
    assert config.target_frame == "gripper_frame_link"


@pytest.mark.parametrize(
    "overrides",
    [
        {"endpoint": "http://nope"},
        {"home_joints": [0.0, 0.0]},
        {"home_gripper": 120.0},  # degrees-shaped value in a 0..100 field
        {"home_gripper": -1.0},
        {"command_timeout_ms": 0},
        {"connect_timeout_ms": -1},
        {"state_report_hz": 0.0},
        {"ik_position_tolerance": 0.0},
    ],
)
def test_config_rejects_invalid_values(overrides):
    with pytest.raises(ValueError):
        VROperatorConfig(**overrides)


def test_teleoperator_registration_names():
    assert VROperator.name == "vr_operator"
    assert VROperator.config_class is VROperatorConfig
    # make_device_from_device_class strips "Config" to find the device class.
    assert VROperatorConfig.__name__ == VROperator.__name__ + "Config"
    assert VROperatorConfig().type == "vr_operator"
