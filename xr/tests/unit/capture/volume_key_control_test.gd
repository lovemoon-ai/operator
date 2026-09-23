extends RefCounted

const CASE_ID := "capture.volume_key_control"
const CaptureAppBaseScript := preload("res://scripts/app/modes/capture_app_base.gd")
const CaptureSpyScript := preload("res://tests/unit/capture/volume_key_capture_spy.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var volume_up := _key_event(KEY_VOLUMEUP)
	var volume_down := _key_event(KEY_VOLUMEDOWN)
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(volume_up, false, false),
		&"start",
		"volume-up starts ego capture independently of the active XR interaction source"
	)
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(volume_down, true, false),
		&"stop",
		"volume-down stops ego capture independently of the active XR interaction source"
	)

	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(volume_up, true, false),
		&"",
		"volume-up does not restart an active ego recording"
	)
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(volume_down, false, false),
		&"",
		"volume-down does not stop an idle ego recorder"
	)
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(_key_event(KEY_SPACE), false, false),
		&"",
		"ordinary keys do not control ego recording"
	)
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(volume_down, false, true),
		&"cancel_start",
		"volume-down cancels an ego recording that is waiting to start"
	)
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(volume_up, false, true),
		&"",
		"volume-up does not queue another start while one is pending"
	)

	var released := _key_event(KEY_VOLUMEUP)
	released.pressed = false
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(released, false, false),
		&"",
		"key release does not start ego capture"
	)
	var repeated := _key_event(KEY_VOLUMEUP)
	repeated.echo = true
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(repeated, false, false),
		&"",
		"holding volume-up does not repeat the start command"
	)
	var physical_volume_up := InputEventKey.new()
	physical_volume_up.pressed = true
	physical_volume_up.physical_keycode = KEY_VOLUMEUP
	t.eq(
		CaptureAppBaseScript.capture_action_for_key_event(physical_volume_up, false, false),
		&"start",
		"physical keycode fallback starts ego capture"
	)

	# Exercise the actual Node input callback so a future interaction-mode gate
	# around the pure event decoder cannot silently reintroduce the original bug.
	for interaction_mode in ["controllers", "hands", "head"]:
		var start_spy := CaptureSpyScript.new()
		start_spy.capture_options["interaction_mode"] = interaction_mode
		start_spy._unhandled_key_input(volume_up)
		t.eq(
			start_spy.start_requests,
			1,
			"the input callback starts ego capture in %s mode" % interaction_mode
		)
		start_spy.free()

	# The recording view reads the pipeline's lifecycle controller; a bare
	# pipeline with a started controller is enough to be "recording".
	var stop_spy := CaptureSpyScript.new()
	var pipeline := CapturePipeline.new()
	pipeline.controller = CaptureSessionController.new()
	pipeline.controller.configure({
		"writer_adapter": FakeCaptureWriterAdapter.new(),
	})
	stop_spy._pipeline = pipeline
	t.is_true(
		pipeline.controller.request_start({}),
		"stop callback fixture enters the recording state"
	)
	stop_spy._unhandled_key_input(volume_down)
	t.eq(stop_spy.stop_requests, 1, "the input callback stops an active ego recording")
	stop_spy.free()
	pipeline.free()

	var pending_spy := CaptureSpyScript.new()
	pending_spy._export_space_start_pending = true
	pending_spy._unhandled_key_input(volume_down)
	t.is_true(
		pending_spy._capture_start_cancel_requested,
		"the input callback cancels a pending ego recording start"
	)
	pending_spy.free()


func _key_event(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = code
	return event
