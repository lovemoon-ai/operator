extends RefCounted
## WP7 integration test: one failing sink during recording must not poison
## the session — healthy sinks keep receiving frames, the capture state
## machine keeps RUNNING, and stop still completes cleanly.

const CASE_ID := "capture.sink_failure_during_recording"


func run(ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var driver := CaptureTestDriver.new()
	driver.setup({
		"pose_stream": ctx.get("fixture", {}),
		"with_failing_sink": true,
		"fail_after": 2,
	})

	t.is_true(bool(driver.command("start_capture").get("ok", false)), "start must succeed")

	for i in range(6):
		driver.command("inject_pose_frame")

	var snap := driver.snapshot()
	t.eq(snap.get("state_name"), "running",
		"sink failure must not change the capture state")
	t.is_true(bool(snap.get("failing_sink", {}).get("failed", false)),
		"failing sink tripped after its threshold")
	t.eq(snap.get("frames_by_type", {}).get(SensorFrameType.POSE, 0), 6,
		"healthy recording sink keeps receiving all frames")

	# Forced failure command also isolates.
	driver.command("fail_sink", {"reason": "test forced"})
	driver.command("inject_pose_frame")
	t.eq(driver.snapshot().get("frames_by_type", {}).get(SensorFrameType.POSE, 0), 7,
		"healthy sink unaffected by forced sink failure")

	var stop_result := driver.command("stop_capture")
	t.is_true(bool(stop_result.get("ok", false)), "stop completes despite failed sink")
	t.eq(driver.snapshot().get("state_name"), "idle", "controller returns to idle")
	t.merge_failures(driver.assert_invariants())
	driver.teardown()
