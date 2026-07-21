extends RefCounted
## WP7 unit test: ControlMode descriptor mapping — axis scale/invert,
## dead zones, button thresholds, and the enable-release grace window.
## Uses the fake_robot_descriptor_so101 fixture + FakeTrackingProvider.

const CASE_ID := "teleop.control_mode_mapping"


func run(ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var fixture: Dictionary = ctx.get("fixture", {})
	var descriptor: Dictionary = fixture.get("descriptor", fixture)
	if not t.is_true(not descriptor.is_empty(), "descriptor fixture must load"):
		return
	var parsed := DeviceDescriptorContract.parse(descriptor)
	t.eq((parsed.get("errors", []) as Array).size(), 0, "so101 descriptor must validate")

	var control_mode := ControlMode.new()
	control_mode.configure(parsed.get("descriptor", {}))
	var tracking := FakeTrackingProvider.new()

	# Axis mapping with scale: left joystick x -> shoulder_pan.
	tracking.set_controller_input(0, {"joystick": Vector2(0.8, 0.0)})
	var cmd := control_mode.collect_command(tracking)
	t.almost_eq(float(cmd["axes"].get("shoulder_pan", 0.0)), 0.8, 0.001,
		"joystick x maps to shoulder_pan with scale 1.0")

	# Dead zone: |value| below the axis dead_zone snaps to 0.
	tracking.set_controller_input(0, {"joystick": Vector2(0.05, 0.0)})
	cmd = control_mode.collect_command(tracking)
	t.almost_eq(float(cmd["axes"].get("shoulder_pan", 1.0)), 0.0, 0.0001,
		"values inside the dead zone snap to zero")

	# Invert: right joystick y -> lift with invert=true.
	tracking.set_controller_input(1, {"joystick": Vector2(0.0, 0.5)})
	cmd = control_mode.collect_command(tracking)
	t.almost_eq(float(cmd["axes"].get("lift", 0.0)), -0.5, 0.001,
		"invert flips the mapped axis sign")

	# Trigger -> gripper axis.
	tracking.set_controller_input(1, {"joystick": Vector2.ZERO, "trigger": 1.0})
	cmd = control_mode.collect_command(tracking)
	t.almost_eq(float(cmd["axes"].get("gripper", 0.0)), 1.0, 0.001,
		"right trigger maps to gripper")

	# Enable button via grip, with hysteresis and NO release grace.
	#
	# This used to assert that enable "holds through the release grace window".
	# That grace is gone on purpose: it delayed release by 100 ms, and during
	# those 100 ms the client kept streaming the operator's still-moving hand
	# pose, so the arm visibly kept going after they let go. Asserting the old
	# behaviour here would re-pin the very bug that was fixed.
	tracking.set_controller_input(1, {"grip": 1.0})
	cmd = control_mode.collect_command(tracking)
	t.is_true(bool(cmd["buttons"].get("enable", false)), "grip press asserts enable")
	# Between the two thresholds the latch holds -- that is the chatter immunity
	# the grace window used to provide.
	tracking.set_controller_input(1, {"grip": 0.5})
	cmd = control_mode.collect_command(tracking)
	t.is_true(bool(cmd["buttons"].get("enable", false)),
		"grip between release and press thresholds holds enable")
	# Below the release threshold it drops on the very next command, not a
	# timeout later.
	tracking.set_controller_input(1, {"grip": 0.0})
	cmd = control_mode.collect_command(tracking)
	t.is_true(not bool(cmd["buttons"].get("enable", true)),
		"releasing the grip drops enable immediately, with no grace window")

	# Pose mapping: head pose lands in cmd.poses with position+rotation.
	tracking.set_head_pose({
		"position": Vector3(0.1, 1.6, -0.2),
		"rotation": Quaternion.IDENTITY,
	})
	cmd = control_mode.collect_command(tracking)
	t.contains(cmd.get("poses", {}), "head", "head pose maps to poses.head")

	tracking.free()
