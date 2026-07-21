extends RefCounted
## Unit test: ControlMode against a DUAL-arm descriptor.
##
## A dual SO-101 rig drives two arms from two controllers at once, so each hand
## owns its own enable/gripper/pose targets. The properties that matter and that
## the single-arm test cannot cover:
##
##   * both hands command SIMULTANEOUSLY -- neither the driving-hand latch nor
##     the enable latch may let one hand suppress the other;
##   * each hand's deadman is INDEPENDENT, which is what lets the client show or
##     hide that arm's control-frame gizmo on its own;
##   * a released hand publishes no enable, so its arm holds still.

const CASE_ID := "teleop.dual_arm_mapping"

const HAND_LEFT := 0
const HAND_RIGHT := 1


func run(ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var fixture: Dictionary = ctx.get("fixture", {})
	var descriptor: Dictionary = fixture.get("descriptor", fixture)
	if not t.is_true(not descriptor.is_empty(), "dual descriptor fixture must load"):
		return
	var parsed := DeviceDescriptorContract.parse(descriptor)
	t.eq((parsed.get("errors", []) as Array).size(), 0, "dual descriptor must validate")

	var control_mode := ControlMode.new()
	control_mode.configure(parsed.get("descriptor", {}))
	var tracking := FakeTrackingProvider.new()

	tracking.set_controller_pose(HAND_LEFT, {
		"position": Vector3(-0.3, 1.2, -0.4),
		"rotation": Quaternion.IDENTITY,
		"is_active": true,
	})
	tracking.set_controller_pose(HAND_RIGHT, {
		"position": Vector3(0.3, 1.2, -0.4),
		"rotation": Quaternion.IDENTITY,
		"is_active": true,
	})

	# Both grips squeezed: BOTH arms must be enabled in the same command. A
	# single-arm build latches one driving hand, which would starve one arm here.
	tracking.set_controller_input(HAND_LEFT, {"grip": 1.0, "trigger": 0.0})
	tracking.set_controller_input(HAND_RIGHT, {"grip": 1.0, "trigger": 0.0})
	var cmd := control_mode.collect_command(tracking)
	t.is_true(bool(cmd["buttons"].get("left_enable", false)), "left grip asserts left_enable")
	t.is_true(bool(cmd["buttons"].get("right_enable", false)), "right grip asserts right_enable")
	t.contains(cmd.get("poses", {}), "left_end_effector", "left controller pose is published")
	t.contains(cmd.get("poses", {}), "right_end_effector", "right controller pose is published")
	t.is_true(control_mode.is_deadman_engaged_for_hand(HAND_LEFT), "left deadman engaged")
	t.is_true(control_mode.is_deadman_engaged_for_hand(HAND_RIGHT), "right deadman engaged")

	# Release ONLY the left grip. The right arm must keep driving, and the two
	# deadman queries must disagree -- that split is exactly what lets the
	# headset hide the left gizmo while the right one stays live.
	tracking.set_controller_input(HAND_LEFT, {"grip": 0.0, "trigger": 0.0})
	cmd = control_mode.collect_command(tracking)
	t.is_true(not bool(cmd["buttons"].get("left_enable", true)),
		"releasing the left grip drops left_enable immediately")
	t.is_true(bool(cmd["buttons"].get("right_enable", false)),
		"the right arm keeps driving while the left is released")
	t.is_true(not control_mode.is_deadman_engaged_for_hand(HAND_LEFT),
		"left deadman reads released")
	t.is_true(control_mode.is_deadman_engaged_for_hand(HAND_RIGHT),
		"right deadman still reads engaged")

	# Grippers are per side: the left trigger must not move the right gripper.
	# Mapping is invert+offset 1.0, so trigger 1.0 -> 0.0 (closed), 0.0 -> 1.0.
	tracking.set_controller_input(HAND_LEFT, {"grip": 1.0, "trigger": 1.0})
	tracking.set_controller_input(HAND_RIGHT, {"grip": 1.0, "trigger": 0.0})
	cmd = control_mode.collect_command(tracking)
	t.almost_eq(float(cmd["axes"].get("left_gripper", -1.0)), 0.0, 0.001,
		"left trigger closes only the left gripper")
	t.almost_eq(float(cmd["axes"].get("right_gripper", -1.0)), 1.0, 0.001,
		"right gripper stays open on its own trigger")

	# A powered-off controller must not publish a stale pose for its arm.
	tracking.set_controller_pose(HAND_LEFT, {
		"position": Vector3(-0.3, 1.2, -0.4),
		"rotation": Quaternion.IDENTITY,
		"is_active": false,
	})
	cmd = control_mode.collect_command(tracking)
	t.is_true(not (cmd.get("poses", {}) as Dictionary).has("left_end_effector"),
		"an untracked controller publishes no pose for its arm")
	t.contains(cmd.get("poses", {}), "right_end_effector",
		"the tracked arm is unaffected by its peer going dark")

	tracking.free()
