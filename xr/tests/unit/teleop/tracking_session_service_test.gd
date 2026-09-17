extends RefCounted
const CASE_ID := "contracts.tracking_sessions"

# State-machine double, not an XR runtime or a replacement for Pico device tests.
class NativeCalls:
	extends RefCounted
	var body_started := false
	var body_starts := 0
	var body_stops := 0
	var body_reads := 0
	var motion_requests := 0
	var motion_count := 0
	var continuity := {"available": true, "body_lost_epoch": 0}
	var collapsed := false
	var motion_valid := true
	var disconnect_epoch := 0
	func get_status() -> Dictionary:
		return {"session_created": true, "pico_body_tracking2_extension": true,
			"body_tracker_created": body_started, "tracker_disconnect_epoch": disconnect_epoch,
			"motion_tracker_count": motion_count, "motion_request_sent": motion_count > 0,
			"last_motion_request_result": 0}
	func get_tracking_continuity_state(_refresh := true) -> Dictionary:
		return continuity.duplicate()
	func set_tracking_monitor_enabled(_enabled: bool) -> bool:
		return true
	func get_body_tracking_state() -> Dictionary:
		return {"available": true, "status": 1 if body_started else 0}
	func start_body_tracking(_lengths: Dictionary) -> bool:
		body_starts += 1
		body_started = true
		return true
	func stop_body_tracking() -> void:
		body_stops += 1
		body_started = false
	func request_motion_trackers(count: int) -> bool:
		if count > 0:
			motion_requests += 1
		motion_count = count
		return true
	func sample_body_joints() -> Dictionary:
		body_reads += 1
		return {"active": true, "status": 1, "joints": [
			{"joint": 0, "flags": 2, "position": {"x": 0.0, "y": 0.0, "z": 0.0}},
			{"joint": 1, "flags": 2, "position": {"x": 0.0, "y": 0.0 if collapsed else 1.5, "z": 0.0}},
		]}
	func sample_motion_trackers(count: int) -> Array:
		var records: Array = []
		for index in range(mini(count, motion_count)):
			records.append({"id": index, "tracking_valid": motion_valid, "transform": Transform3D.IDENTITY})
		return records
	func start_body_tracking_calibration_app() -> bool:
		return true


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_freshness(t)
	var sessions := TrackingSessionService.new()
	var native := NativeCalls.new()
	sessions.set("_pico", true)
	sessions.set("_native", native)
	var capture := RefCounted.new()
	var teleop := RefCounted.new()
	var motion := RefCounted.new()
	sessions.acquire(capture, ["body"])
	t.is_false(sessions.status(capture)["allowed"], "old calibrated state cannot authorize first use")
	t.is_true(sessions.sample_body(capture).is_empty(), "data boundary blocks old calibration")
	t.eq(native.body_reads, 0, "blocked publication never samples raw body")
	t.eq(native.body_starts, 0, "declaration does not bypass calibration")
	t.is_true(sessions.begin_calibration(), "an explicit request opens setup")
	t.is_false(sessions.confirm_calibration(), "cannot confirm before leaving and returning from setup")
	sessions.call("_on_tracking_focus", false)
	sessions.call("_on_tracking_focus", true)
	t.is_false(sessions.status(capture, true)["allowed"], "return plus valid tracking never automatically authorizes use")
	t.is_true(sessions.status(capture)["can_confirm"], "return exposes the separate confirmation action")
	native.collapsed = true
	t.is_false(sessions.confirm_calibration(), "a collapsed placeholder skeleton cannot be confirmed")
	t.eq(sessions.status(capture)["phase"], "confirmation_waiting_tracking", "invalid data explains the disabled confirmation")
	native.collapsed = false
	t.is_true(sessions.confirm_calibration(), "explicit attestation with usable body data authorizes use")
	t.is_true(sessions.status(capture, true)["allowed"], "confirmed body data is usable")
	t.eq(sessions.status(capture)["confirmation_source"], "user", "never claim automatic verification")
	sessions.acquire(teleop, ["body"])
	t.eq(native.body_starts, 1, "two owners share one body tracker")
	sessions.release(capture)
	t.eq(native.body_stops, 0, "stopping recording cannot stop teleop tracking")
	t.is_true(sessions.status(teleop)["allowed"], "capture release cannot clear shared calibration")
	t.is_true(sessions.sample_body(capture).is_empty(), "released owner cannot read another owner's data")
	sessions.acquire(motion, ["motion"], 2)
	t.eq(sessions.status(motion)["phase"], "mode_conflict", "incompatible independent mode is explicit")
	t.eq(native.motion_requests, 0, "motion demand cannot steal body mode")
	sessions.release(motion)
	sessions.release(teleop)
	t.eq(native.body_stops, 1, "last body owner stops the tracker")
	t.is_false(sessions.summary()["needed"], "no consumers means no calibration UI demand")
	sessions.acquire(teleop, ["body"])
	sessions.status(teleop, true)
	t.is_true(sessions.status(teleop, true)["allowed"], "page changes retain calibration without disconnection")
	native.disconnect_epoch = 1
	t.is_false(sessions.status(teleop, true)["allowed"], "disconnect invalidates all consumers")
	t.is_true(sessions.sample_body(teleop).is_empty(), "no cached body after invalidation")
	sessions.release(teleop)
	sessions.acquire(motion, ["motion"], 2)
	t.is_false(sessions.status(motion)["allowed"], "switching capabilities cannot bypass disconnection")
	sessions.begin_calibration()
	sessions.call("_on_tracking_focus", false)
	sessions.call("_on_tracking_focus", true)
	native.motion_valid = false
	sessions.retry_setup()
	t.is_false(sessions.confirm_calibration(), "motion confirmation needs actual valid tracker poses")
	var body_starts_before_dialog := native.body_starts
	sessions.call("_on_tracking_focus", false)
	sessions.status(motion, true)
	t.eq(native.body_starts, body_starts_before_dialog, "independent setup dialog cannot restart body mode")
	t.is_false(sessions.confirm_calibration(), "cannot confirm while another app has focus")
	sessions.call("_on_tracking_focus", true)
	native.motion_valid = true
	t.is_true(sessions.confirm_calibration(), "motion confirmation uses its own live data after setup")
	t.is_true(sessions.status(motion, true)["allowed"], "motion setup proceeds after manual confirmation")
	var starts_before_display := native.body_starts
	sessions.acquire(teleop, ["body"])
	t.eq(sessions.status(teleop)["phase"], "mode_conflict", "new body display cannot preempt active motion tracking")
	t.is_true(sessions.status(motion)["allowed"], "existing motion consumer remains ready")
	t.eq(native.body_starts, starts_before_display, "mode conflict does not silently switch the runtime")
	sessions.release(teleop)
	sessions.release(motion)
	var abandoned := RefCounted.new()
	sessions.acquire(abandoned, ["body"])
	abandoned = null
	t.is_false(sessions.summary()["needed"], "weak ownership cleans abandoned consumers")
	sessions.free()


func _test_freshness(t: OperatorTestAssertions) -> void:
	var policy := PicoTrackingCalibration.new()
	var raw := {"available": true, "body_status": 1, "body_lost_epoch": 0}
	var runtime := {"session_created": true, "tracker_disconnect_epoch": 0, "tracking_session_epoch": 1}
	t.is_false(policy.observe(raw, runtime)["confirmed"], "fresh app rejects retained tracking validity")
	t.is_false(policy.confirm(true), "confirmation without a setup request is rejected")
	policy.begin_calibration()
	policy.launch_succeeded()
	t.is_false(policy.confirm(true), "opening setup is not returning from setup")
	policy.note_focus(false)
	policy.note_focus(true)
	t.is_false(policy.observe(raw, runtime)["confirmed"], "return/cancel without confirmation stays blocked")
	t.is_false(policy.confirm(false), "user click with invalid tracking is rejected")
	t.is_true(policy.confirm(true), "separate user confirmation accepts ready tracking")
	runtime["tracking_session_epoch"] = 2
	t.is_true(policy.observe(raw, runtime)["confirmed"], "session recreation alone preserves physical calibration")
	runtime["tracker_disconnect_epoch"] = 1
	t.is_false(policy.observe(raw, runtime)["confirmed"], "hardware disconnection invalidates calibration")
	t.is_false(policy.confirm(true), "reconnection cannot reuse the previous confirmation action")
	policy.begin_calibration()
	policy.launch_failed()
	policy.note_focus(false)
	policy.note_focus(true)
	t.is_false(policy.confirm(true), "failed launch cannot be confirmed after unrelated focus changes")
	t.is_false(policy.observe(raw, runtime)["confirmed"], "failed launch cannot authorize use")
	policy.begin_calibration()
	policy.launch_succeeded()
	policy.note_focus(false)
	policy.note_focus(true)
	runtime["tracker_disconnect_epoch"] = 2
	policy.observe(raw, runtime)
	t.is_false(policy.confirm(true), "disconnect after return cancels the pending confirmation")
	t.is_false(PicoTrackingCalibration.new().observe(raw, runtime)["confirmed"], "restart never inherits confirmation")
