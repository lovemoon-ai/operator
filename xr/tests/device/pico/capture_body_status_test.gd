extends RefCounted
## Real Pico API/UI smoke test; model tests do not replace worn-tracker tests.
const CASE_ID := "device.pico.capture_body_status"
const CapturePanel := preload("res://scripts/ui/view_locked_capture_panel.gd")

func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	if not t.is_true(OS.has_feature("pico"), "this test requires Pico"):
		return
	var bridge: Object = PicoPlatformAdapter.new().openxr_bridge_native()
	if not t.is_true(bridge != null, "native Pico bridge exists"):
		return
	var xr := XRServer.find_interface("OpenXR")
	if not t.is_true(xr != null and (xr.is_initialized() or xr.initialize()), "real XR session initializes"):
		return
	var continuity: Dictionary = bridge.call("get_tracking_continuity_state")
	t.log_line("Pico tracking API: %s" % str(continuity))
	t.is_true(bool(continuity.get("available", false)), "supported body_tracking2 status is readable")
	t.eq(continuity.get("state_result"), 0, "tracking-state query succeeds on this firmware")
	t.is_false(bridge.has_method("get_tracker_calibration_state"), "deprecated calibration getter is no longer a dependency")
	var sessions := TrackingSessionService.shared()
	if not t.is_true(sessions != null, "shared service is an application autoload"):
		return
	var capture_owner := RefCounted.new()
	var teleop_owner := RefCounted.new()
	var before: Dictionary = bridge.call("get_status")
	sessions.acquire(capture_owner, ["body"])
	sessions.acquire(teleop_owner, ["body"])
	t.is_false(sessions.status(capture_owner, true)["allowed"], "retained calibration cannot authorize this process")
	t.is_true(sessions.sample_body(capture_owner).is_empty(), "unconfirmed body data does not escape")
	t.is_false(sessions.confirm_calibration(), "real native readiness cannot bypass the setup/confirmation workflow")
	sessions.release(capture_owner)
	t.eq(sessions.summary()["consumers"], 1, "capture release retains teleop demand")
	t.eq(sessions.status(teleop_owner)["mode"], "body", "teleop remains a body consumer")
	var after: Dictionary = bridge.call("get_status")
	for key in ["body_tracker_created", "requested_motion_tracker_count", "motion_request_sent"]:
		t.eq(after.get(key), before.get(key), "unconfirmed demand does not start or switch %s" % key)
	sessions.release(teleop_owner)
	t.is_false(sessions.summary()["needed"], "last release removes demand")
	var panel := CapturePanel.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(panel)
	var label: Label = panel.get("_tracker_status_label")
	var button: Button = panel.get("_tracker_connect_button")
	var confirm: Button = panel.get("_tracker_confirm_button")
	var confirm_slot: Control = panel.get("_tracker_confirm_slot")
	for phase in ["required", "calibrating", "confirming", "ready", "limited", "waiting_body", "motion_setup", "unavailable"]:
		panel.set_pico_calibration_status({"mode": "body", "phase": phase}, true, false)
		t.eq(label.text, panel.tr(TrackingStatusText.key(phase)), "shared wording for %s" % phase)
		t.is_false(button.disabled, "calibration entry remains available for %s" % phase)
	panel.set_pico_calibration_status({"mode": "motion", "phase": "mode_conflict"}, true, false)
	t.is_true(button.disabled, "mode conflict cannot steal another consumer's body mode")
	t.is_false(confirm_slot.visible, "no stale confirmation button after leaving confirmation state")
	panel.set_pico_calibration_status({"mode": "body", "phase": "confirmation_waiting_tracking", "needs_confirmation": true, "can_confirm": false}, true, false)
	t.is_true(confirm_slot.visible and confirm.disabled, "confirmation is visible but disabled until tracking is valid")
	panel.set_pico_calibration_status({"mode": "body", "phase": "confirming", "needs_confirmation": true, "can_confirm": true}, true, false)
	t.is_false(confirm.disabled, "valid data enables the explicit confirmation action")
	t.eq(confirm.text, panel.tr("UI_TRACKING_CONFIRM_CALIBRATION"), "button explicitly states user attestation")
	var clicks: Array = []
	panel.tracker_calibration_confirm_requested.connect(func() -> void: clicks.append(true))
	confirm.pressed.emit()
	t.eq(clicks.size(), 1, "confirmation click emits a separate action")
	panel.queue_free()
