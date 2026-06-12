extends RefCounted
## WP7 integration test: full capture lifecycle with fake providers and a
## RecordingSink. Asserts the state sequence Idle -> RequestingPermission ->
## Ready -> Starting -> Running -> Stopping -> Stopped -> Idle, frame
## routing only to declared types, and permission-denied behavior.

const CASE_ID := "capture.start_stop_with_fake_sources"

const EXPECTED_SEQUENCE := [
	"idle", "requesting_permission", "ready", "starting", "running",
	"stopping", "stopped", "idle",
]


func run(ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var driver := CaptureTestDriver.new()
	var setup_result := driver.setup({"pose_stream": ctx.get("fixture", {})})
	t.is_true(bool(setup_result.get("ok", false)), "driver setup must succeed")

	# Permission denied first: start refused, controller returns to idle.
	driver.command("deny_permission")
	var denied := driver.command("start_capture")
	t.is_false(bool(denied.get("ok", true)), "start with denied permission must fail")
	t.eq(driver.snapshot().get("state_name"), "idle", "denied start returns to idle")

	# Grant and run the nominal lifecycle.
	driver.command("grant_permission")
	driver.state_sequence = ["idle"]  # reset observed sequence for the clean run
	t.is_true(bool(driver.command("start_capture").get("ok", false)), "start must succeed")
	t.eq(driver.snapshot().get("state_name"), "running", "controller reaches running")
	t.eq((driver.snapshot().get("started_dirs") as Array).size(), 1,
		"session_started fired exactly once")

	for i in range(5):
		driver.command("inject_pose_frame")
	driver.command("inject_depth_frame")

	var stop_result := driver.command("stop_capture")
	t.is_true(bool(stop_result.get("ok", false)), "stop must succeed")

	var snap := driver.snapshot()
	t.eq(snap.get("state_sequence"), EXPECTED_SEQUENCE,
		"state machine must walk the full legal lifecycle")
	t.eq((snap.get("stopped_paths") as Array).size(), 1, "session_stopped fired exactly once")
	t.eq(snap.get("writer", {}).get("sessions_started"), 1, "writer opened one session")
	t.eq(snap.get("writer", {}).get("sessions_closed"), 1, "writer closed one session")

	# Frame routing: the recording sink declared all types, so it received
	# pose + depth; counts match what was injected; streams stayed monotonic.
	var frames_by_type: Dictionary = snap.get("frames_by_type", {})
	t.eq(frames_by_type.get(SensorFrameType.POSE, 0), 5, "5 pose frames routed")
	t.eq(frames_by_type.get(SensorFrameType.DEPTH, 0), 1, "1 depth frame routed")
	t.merge_failures(driver.assert_invariants())

	# A sink that does NOT declare DEPTH must never receive depth frames.
	var pose_only := RecordingSink.new([SensorFrameType.POSE])
	driver.binding.add_sink(pose_only)
	driver.command("grant_permission")
	driver.command("start_capture")
	driver.command("inject_pose_frame")
	driver.command("inject_depth_frame")
	driver.command("stop_capture")
	t.eq(pose_only.count(SensorFrameType.POSE), 1, "pose-only sink receives pose frames")
	t.eq(pose_only.count(SensorFrameType.DEPTH), 0,
		"pose-only sink must not receive depth frames")
	t.merge_failures(pose_only.invariant_failures())

	driver.teardown()
