extends RefCounted

const CASE_ID := "device.pico.system_compatibility"
const Adapter := preload("res://scripts/platform/pico/pico_platform_adapter.gd")
const Notice := preload("res://scripts/app/system_compatibility_notice.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var supported := {"session_created": true, "bd_body_tracking_extension": true}
	var unsupported := {"session_created": true, "bd_body_tracking_extension": false}
	for version in ["5.9.9", "5.10.10", "5.11.2", "5.11.3", "5.11.4", "5.12.0", "5.12.99", "Pico OS 5.11.3_S2024", " 5.11.3 "]:
		var report := Adapter.evaluate_system_compatibility(true, version, {})
		t.is_true(report["needs_upgrade"], "%s is below the official minimum" % version)
		t.eq(report["minimum_version"], "5.13.0", "notice carries the official minimum from the version policy")
		t.eq(report["reason"], "old_os", "old version is identified without waiting for body tracking")
	for version in ["5.13.0", "Pico OS 5.13.0_S2025", "5.13.1", "5.14.0", "5.100.1", "6.0.0"]:
		t.is_false(Adapter.evaluate_system_compatibility(true, version, supported)["needs_upgrade"],
			"%s with the required API does not warn" % version)
	var missing := Adapter.evaluate_system_compatibility(true, "5.13.0", unsupported)
	t.is_true(missing["needs_upgrade"], "a newer version still checks actual runtime support")
	t.eq(missing["reason"], "body_extension_unavailable", "a missing API does not mislabel a newer version as old")
	for version in ["", "unknown", "Android 14", "5.11.bad"]:
		t.eq(Adapter.parse_os_version(version), [], "unknown OS version is not interpreted as zero")
		t.is_false(Adapter.evaluate_system_compatibility(true, version, {})["needs_upgrade"],
			"unknown version alone does not cause an upgrade warning")
	t.is_false(Adapter.evaluate_system_compatibility(true, "5.14.0",
		{"session_created": false, "bd_body_tracking_extension": false})["needs_upgrade"],
		"a session that has not initialized is not classified as unsupported")
	t.is_false(Adapter.evaluate_system_compatibility(false, "5.11.3", unsupported)["needs_upgrade"],
		"other platforms never receive a Pico upgrade prompt")
	var adapter := Adapter.new()
	var actual := adapter.system_compatibility()
	var version := str(actual.get("version", ""))
	t.is_true(not version.is_empty(), "native bridge reads the real Pico OS version on this headset")
	t.is_true(not Adapter.parse_os_version(version).is_empty(), "the detected device version is parseable")
	t.log_line("Pico OS: %s; compatibility: %s" % [version, str(actual)])
	_test_notice(t)


func _test_notice(t: OperatorTestAssertions) -> void:
	var root := XROrigin3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	var camera := XRCamera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0, 1.6, 0)
	var notice := Notice.new()
	root.add_child(notice)
	var report := Adapter.evaluate_system_compatibility(true, "5.11.3", {})
	notice.show_for_camera(camera, report)
	var popup: ViewLockedStatusPopup = notice.get("_popup")
	if not t.is_true(popup != null, "upgrade notice creates a real composition panel"):
		root.free()
		return
	t.is_true(popup.visible, "notice is visible")
	var detail: Label = popup.get("_path_label")
	t.contains(detail.text, "5.11.3", "notice identifies the installed system version")
	t.contains(detail.text, "5.13.0", "notice identifies the official minimum system version")
	t.eq(detail.text, str(TranslationServer.translate("UI_PICO_OS_UPDATE_OLD")) % ["5.11.3", "5.13.0"], "notice uses the translated upgrade guidance")
	var button: Button = popup.get("_cancel_button")
	t.eq(button.text, str(TranslationServer.translate("UI_ACKNOWLEDGE")), "warning has an acknowledgement button, not upload cancellation")
	t.is_true(popup.accepts_pointer(), "controller/hand rays can dismiss the notice")
	t.is_true(popup.captures_teleop_input(), "acknowledgement click is not sent as robot control")
	notice.show_for_camera(camera, report)
	t.eq(notice.get("_popup"), popup, "repeated checks do not stack dialogs")
	t.eq(popup.get_parent(), root, "composition layer is parented directly to the active XR origin")
	button.pressed.emit()
	t.is_false(popup.visible, "acknowledgement closes the warning")
	t.is_true(bool(notice.get("_dismissed")), "acknowledgement is retained for this process")
	notice._on_session_focused()
	notice.show_for_camera(camera, report)
	t.is_false(popup.visible, "resume and scene changes cannot reopen an acknowledged warning")
	t.is_false(notice.is_processing(), "acknowledged notice stops polling")
	popup.show_upload_progress("Upload", "Sending", 0.5, "normal", 0.0, true)
	t.eq(button.text, str(TranslationServer.translate("UI_CANCEL_UPLOAD")), "existing upload popup text remains unchanged")
	var cancelled: Array = []
	popup.cancel_requested.connect(func() -> void: cancelled.append(true))
	button.pressed.emit()
	t.eq(cancelled.size(), 1, "existing upload cancellation signal remains unchanged")
	root.free()
