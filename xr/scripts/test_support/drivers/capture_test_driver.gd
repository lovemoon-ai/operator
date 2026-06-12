class_name CaptureTestDriver
extends ModuleTestDriver
## v2 test harness (WP7): automation driver for core/capture. Wraps a real
## CaptureSessionController wired entirely with fakes (permission provider,
## writer adapter, fanout + fake sinks) so the capture lifecycle runs
## deterministically without a headset.
##
## Commands: start_capture, stop_capture, grant_permission,
## deny_permission, inject_pose_frame, inject_depth_frame, fail_sink.
## Snapshot: controller.snapshot() + state sequence + sink health.

var controller: CaptureSessionController
var permissions: FakePermissionProvider
var writer: FakeCaptureWriterAdapter
var binding: StreamBinding
var recording_sink: RecordingSink
var failing_sink: FailingSink
var pose_provider: FakePoseProvider
var depth_provider: FakeDepthProvider
var clock: OperatorTestClock

var state_sequence: Array = []  # Array[String] of entered state names
var started_dirs: Array = []
var stopped_paths: Array = []
var errors: Array = []


func module_id() -> String:
	return "core/capture"


func supported_cases() -> Array:
	return [
		"start_stop_with_fake_sources",
		"permission_denied",
		"sink_failure_during_recording",
		"illegal_transitions",
	]


## Fixture keys (all optional): pose_stream (pose fixture dict),
## depth (depth fixture dict), with_failing_sink (bool),
## fail_after (int), permission_granted (bool), live_mode (bool).
func setup(fixture: Dictionary) -> Dictionary:
	clock = OperatorTestClock.new()
	permissions = FakePermissionProvider.new()
	if not bool(fixture.get("permission_granted", true)):
		permissions.deny()
	writer = FakeCaptureWriterAdapter.new()
	recording_sink = RecordingSink.new()
	binding = StreamBinding.new()
	binding.add_sink(recording_sink)
	if bool(fixture.get("with_failing_sink", false)):
		failing_sink = FailingSink.new(int(fixture.get("fail_after", 3)))
		binding.add_sink(failing_sink)
	pose_provider = FakePoseProvider.new(clock)
	pose_provider.configure(fixture.get("pose_stream", {}))
	depth_provider = FakeDepthProvider.new(clock)
	depth_provider.configure(fixture.get("depth", {}))

	controller = CaptureSessionController.new()
	controller.configure({
		"writer_adapter": writer,
		"permission_check": permissions.as_callable(),
		"option_samplers": [],
		"stop_chain": [],
		"live_mode": bool(fixture.get("live_mode", false)),
	})
	controller.state_changed.connect(_on_state_changed)
	controller.session_started.connect(func(session_dir: String): started_dirs.append(session_dir))
	controller.session_stopped.connect(func(final_path: String): stopped_paths.append(final_path))
	controller.session_error.connect(func(message: String): errors.append(message))
	state_sequence = [CaptureState.state_name(controller.state())]
	return {"ok": true}


func command(name: String, args: Dictionary = {}) -> Dictionary:
	match name:
		"grant_permission":
			permissions.grant()
			return {"ok": true}
		"deny_permission":
			permissions.deny()
			return {"ok": true}
		"start_capture":
			var started := controller.request_start(args.get("options", {}))
			return {"ok": started}
		"stop_capture":
			return controller.request_stop()
		"notify_pause":
			return {"ok": controller.notify_pause()}
		"notify_resume":
			return {"ok": controller.notify_resume()}
		"inject_pose_frame":
			var pose_frame := pose_provider.next_frame()
			var routed: Variant = binding.on_frame(pose_frame)
			return {"ok": true, "routed": routed}
		"inject_depth_frame":
			var depth_frame := depth_provider.next_frame(str(args.get("eye", "left")))
			var depth_routed: Variant = binding.on_frame(depth_frame)
			return {"ok": true, "routed": depth_routed}
		"fail_sink":
			if failing_sink == null:
				return {"ok": false, "error": "no failing sink in fixture"}
			failing_sink.fail_now(str(args.get("reason", "forced failure")))
			return {"ok": true}
	return {"ok": false, "error": "unknown command '%s'" % name}


func step(delta_s: float, ticks: int = 1) -> Dictionary:
	for i in range(ticks):
		clock.advance_seconds(delta_s)
	return {"now_ticks_ns": clock.now_ticks_ns()}


func snapshot() -> Dictionary:
	var snap := controller.snapshot()
	snap["state_sequence"] = state_sequence.duplicate()
	snap["started_dirs"] = started_dirs.duplicate()
	snap["stopped_paths"] = stopped_paths.duplicate()
	snap["errors"] = errors.duplicate()
	snap["writer"] = {
		"sessions_started": writer.sessions_started,
		"sessions_closed": writer.sessions_closed,
		"open": writer.is_open(),
	}
	snap["recording_sink"] = recording_sink.health()
	snap["frames_by_type"] = recording_sink.received_by_type.duplicate()
	if failing_sink != null:
		snap["failing_sink"] = failing_sink.health()
	return snap


func assert_invariants() -> Array:
	var out: Array = []
	out.append_array(recording_sink.invariant_failures())
	# Every observed transition must be legal per the contract table.
	# (state_sequence stores names; recompute ids for the check.)
	var ids: Array = []
	for state_name_v in state_sequence:
		for state_id in range(CaptureState.RECOVERING + 1):
			if CaptureState.state_name(state_id) == str(state_name_v):
				ids.append(state_id)
				break
	for i in range(1, ids.size()):
		if not CaptureState.legal(int(ids[i - 1]), int(ids[i])):
			out.append(OperatorTestFailure.create(
				"illegal_transition",
				"observed illegal transition %s -> %s" % [
					CaptureState.state_name(int(ids[i - 1])),
					CaptureState.state_name(int(ids[i]))]))
	return out


func teardown() -> void:
	if controller != null and controller.is_session_active():
		controller.request_stop()


func _on_state_changed(_from: int, to: int) -> void:
	state_sequence.append(CaptureState.state_name(to))
