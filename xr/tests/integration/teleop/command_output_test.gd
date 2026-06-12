extends RefCounted
## WP7 integration test: teleop command output through the TeleopTestDriver
## (real ControlMode + FakeTrackingProvider + FakeRobotControlSink).
## Verifies mapped command frames, latest-only sink behavior, and that no
## emitted command references unmapped controls.

const CASE_ID := "teleop.command_output"


func run(ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var driver := TeleopTestDriver.new()
	var fixture: Dictionary = ctx.get("registry").fixture("fake_robot_descriptor_so101") \
			if ctx.get("fixture", {}).is_empty() else ctx.get("fixture")
	var setup_result := driver.setup(fixture)
	t.is_true(bool(setup_result.get("ok", false)), "descriptor must load without errors")

	# Grip sequence drives the gripper axis through successive steps.
	driver.command("inject_controller_input", {"hand": 1, "input": {"trigger": 0.25}})
	driver.step(1.0 / 72.0)
	driver.command("inject_controller_input", {"hand": 1, "input": {"trigger": 0.75}})
	driver.step(1.0 / 72.0)

	var snap := driver.snapshot()
	t.eq(snap.get("commands_emitted"), 2, "one command per step")
	var last_command: Dictionary = snap.get("last_command", {})
	t.almost_eq(float(last_command.get("axes", {}).get("gripper", 0.0)), 0.75, 0.001,
		"latest command reflects the latest injected input (latest-only)")
	t.is_true(int(last_command.get("timestamp_ns", 0)) > 0, "commands carry timestamps")

	# Latest-only frame cache on the sink contract surface.
	var input_frame := ControllerFrame.build_input("right_controller", 1_000, 0,
		{"trigger_value": 0.1}, 0)
	var newer_frame := ControllerFrame.build_input("right_controller", 2_000, 0,
		{"trigger_value": 0.9}, 0)
	driver.sink.on_frame(input_frame)
	driver.sink.on_frame(newer_frame)
	var cached := driver.sink.latest_frame(SensorFrameType.INPUT_EVENT)
	t.eq(cached.timestamp_ns, 2_000, "sink keeps only the latest frame per type")

	# Pose mapping emits poses.head; invariants confirm no unmapped controls.
	driver.command("inject_pose_frame", {"head_pose": {
		"position": Vector3(0.0, 1.6, 0.0), "rotation": Quaternion.IDENTITY}})
	driver.step(1.0 / 72.0)
	t.contains(driver.snapshot().get("last_command", {}).get("poses", {}), "head",
		"head pose mapped into command poses")
	t.merge_failures(driver.assert_invariants())
	driver.teardown()
