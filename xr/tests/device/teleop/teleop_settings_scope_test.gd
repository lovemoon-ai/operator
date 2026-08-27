extends RefCounted
## Device coverage for the Teleop robot-configuration page.
##
## The page is one group: a Type row picks Inside or Outside, and only that
## side's settings are shown. This runs on the headset because the panel is a
## composition-viewport UI that needs a live rendering environment; a desktop
## fixture would not prove the operator can actually reach these controls.

const CASE_ID := "teleop.settings_scope"


class TestPanel:
	extends TeleopSettingsPanel

	var saved_options: Dictionary = {}

	func _save_settings(options: Dictionary) -> Error:
		saved_options = options.duplicate(true)
		return OK


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var panel := TestPanel.new()
	if not t.is_true(panel != null, "teleop settings panel instantiates"):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if t.is_true(tree != null, "a scene tree is available"):
		tree.root.add_child(panel)

	var groups: Array = _group_keys(panel)
	t.contains(groups, "robot", "the robot configuration group exists")
	t.contains(groups, "video", "the video configuration group exists")
	t.eq(groups.find("video"), groups.find("robot") + 1, "Video follows Robot in the sidebar")
	t.is_false(groups.has("target"), "the separate embodiment-location group is gone")
	t.is_false(groups.has("connection"), "robot service is no longer its own group")
	t.is_false(groups.has("inside_robot"), "inside robot is no longer its own group")

	var outside_box: Control = panel.get("_outside_box")
	var inside_box: Control = panel.get("_inside_box")
	var protocol_row: HBoxContainer = panel.get("_protocol_row")
	var protocol_buttons: Dictionary = panel.get("_protocol_buttons")
	var xrobot_device_sn_input: LineEdit = panel.get("_xrobot_toolkit_device_sn_input")
	var pico_body_calibration_button: Button = panel.get("_pico_body_calibration_button")
	var picker: Dictionary = panel.get("_profile_buttons")
	if not t.is_true(
		outside_box != null
		and inside_box != null
		and protocol_row != null
		and protocol_buttons != null
		and xrobot_device_sn_input != null
		and pico_body_calibration_button != null
		and picker != null,
		"the page exposes both configuration sides"
	):
		_dispose(panel)
		return
	t.eq(protocol_buttons.size(), 2, "outside offers both wire protocols")
	t.is_true(protocol_buttons.has("operator"), "Operator protocol is offered")
	t.is_true(
		protocol_buttons.has("xrobot_toolkit_v1"),
		"XRoboToolkit-compatible protocol is offered"
	)
	t.is_true(
		outside_box.is_ancestor_of(protocol_row),
		"protocol selection belongs to Outside Robot settings"
	)
	_test_video_settings(panel, groups, t)

	# Every robot is its own always-visible button: a dropdown popup cannot
	# render in this panel's composition viewport, so the operator would never
	# see anything but the current selection.
	var offered := RobotProfileRegistry.ids()
	var listed: Array = picker.keys()
	listed.sort()
	t.eq(listed, offered, "one button per available robot, matching the registry")
	for profile_id in picker:
		var button: Button = picker[profile_id]
		t.is_true(button.visible, "%s is visible without opening a popup" % profile_id)
		t.is_true(button.get_parent() != null, "%s button is in the page" % profile_id)
	t.log_line("picker offers %s" % str(listed))

	panel.set_options(_options("outside"))
	t.eq(panel.get_options().get("target_scope", ""), "outside", "outside selection round-trips")
	t.eq(
		panel.get_options().get("protocol", ""),
		"operator",
		"legacy settings without protocol default to Operator"
	)
	t.is_true(outside_box.visible, "outside shows the robot-service settings")
	t.is_true(protocol_row.visible, "outside shows protocol selection")
	t.is_false(xrobot_device_sn_input.visible, "Operator protocol hides the PICO device SN")
	t.is_false(
		pico_body_calibration_button.visible,
		"Operator protocol hides PICO Body Calibration"
	)
	t.is_false(inside_box.visible, "outside hides the inside settings")

	var xrobot_options := _options("outside")
	xrobot_options["protocol"] = "xrobot_toolkit_v1"
	xrobot_options["xrobot_toolkit_device_sn"] = "PICO-SN-123"
	panel.set_options(xrobot_options)
	t.eq(
		panel.get_options().get("protocol", ""),
		"xrobot_toolkit_v1",
		"XRoboToolkit-compatible protocol round-trips"
	)
	var operator_button: Button = protocol_buttons["operator"]
	var xrobot_button: Button = protocol_buttons["xrobot_toolkit_v1"]
	t.is_true(xrobot_button.button_pressed, "XRoboToolkit-compatible choice stays selected")
	t.is_false(operator_button.button_pressed, "Operator choice is released")
	t.is_true(xrobot_device_sn_input.visible, "XRoboToolkit protocol shows the PICO device SN")
	t.is_true(
		pico_body_calibration_button.visible,
		"XRoboToolkit-compatible Outside settings show PICO Body Calibration"
	)
	t.eq(
		panel.get_options().get("xrobot_toolkit_device_sn", ""),
		"PICO-SN-123",
		"PICO device SN round-trips through settings"
	)
	var calibration_requests: Array = []
	panel.pico_body_calibration_requested.connect(func() -> void:
		calibration_requests.append(true)
	)
	var options_before_calibration := panel.get_options()
	pico_body_calibration_button.emit_signal("pressed")
	t.eq(calibration_requests.size(), 1, "PICO Body Calibration emits one request")
	t.eq(
		panel.get_options(),
		options_before_calibration,
		"PICO Body Calibration does not alter settings"
	)
	t.is_true(panel.saved_options.is_empty(), "PICO Body Calibration does not save settings")
	operator_button.emit_signal("pressed")
	t.eq(panel.get_options().get("protocol", ""), "operator", "Operator button changes protocol")
	t.is_false(
		pico_body_calibration_button.visible,
		"switching to Operator hides PICO Body Calibration"
	)
	xrobot_button.emit_signal("pressed")
	t.eq(
		panel.get_options().get("protocol", ""),
		"xrobot_toolkit_v1",
		"XRoboToolkit-compatible button changes protocol"
	)
	t.is_true(
		pico_body_calibration_button.visible,
		"switching back to XRoboToolkit Compatible shows PICO Body Calibration"
	)

	var applied: Array = []
	panel.settings_applied.connect(func(options: Dictionary) -> void:
		applied.append(options.duplicate(true))
	)
	panel.call("_on_confirm_requested")
	t.eq(applied.size(), 1, "applying Outside settings emits one options dictionary")
	if not applied.is_empty():
		t.eq(
			applied[0].get("protocol", ""),
			"xrobot_toolkit_v1",
			"settings_applied includes the selected protocol"
		)
		t.eq(
			applied[0].get("xrobot_toolkit_device_sn", ""),
			"PICO-SN-123",
			"settings_applied includes the configured PICO device SN"
		)
	t.eq(
		panel.saved_options.get("protocol", ""),
		"xrobot_toolkit_v1",
		"saved settings include the selected protocol"
	)

	var invalid_protocol_options := _options("outside")
	invalid_protocol_options["protocol"] = "unknown"
	panel.set_options(invalid_protocol_options)
	t.eq(
		panel.get_options().get("protocol", ""),
		"operator",
		"unknown protocol values safely fall back to Operator"
	)

	var inside_xrobot_options := _options("inside")
	inside_xrobot_options["protocol"] = "xrobot_toolkit_v1"
	panel.set_options(inside_xrobot_options)
	t.eq(panel.get_options().get("target_scope", ""), "inside", "inside selection round-trips")
	t.is_true(inside_box.visible, "inside shows the robot picker")
	t.is_false(outside_box.visible, "inside hides the robot-service settings")
	t.is_false(outside_box.visible and protocol_row.visible, "inside does not show protocol selection")
	t.is_false(
		pico_body_calibration_button.visible,
		"Inside scope hides PICO Body Calibration even for XRoboToolkit Compatible"
	)
	t.eq(
		str(panel.get_options().get("inside_profile", "")),
		str(offered[0]),
		"the requested inside robot is selected"
	)

	# Switching robots by pressing its button is the whole point of the row.
	if offered.size() > 1:
		var second := str(offered[1])
		(picker[second] as Button).emit_signal("pressed")
		t.eq(
			str(panel.get_options().get("inside_profile", "")),
			second,
			"pressing a robot button selects it"
		)
		var backends: Dictionary = panel.get("_backend_buttons")
		t.eq(backends.size(), 2, "native and remote are both offered as buttons")
		for backend in backends:
			var supported := RobotProfileRegistry.supports_backend(second, str(backend))
			t.eq(
				not (backends[backend] as Button).disabled,
				supported,
				"%s backend button matches what %s supports" % [backend, second]
			)

	# Both retargeting buttons are persistent toggle choices. In XR the pointer
	# leaves the clicked control in hover_pressed, so verify both the semantic
	# selection and the visible accent colour move to the clicked button.
	var dual_backend_profile := ""
	for profile_id in offered:
		if (
			RobotProfileRegistry.supports_backend(str(profile_id), "native")
			and RobotProfileRegistry.supports_backend(str(profile_id), "remote")
		):
			dual_backend_profile = str(profile_id)
			break
	if not dual_backend_profile.is_empty():
		var backend_options := _options("inside")
		backend_options["inside_profile"] = dual_backend_profile
		backend_options["retargeting_backend"] = "native"
		panel.set_options(backend_options)
		var backend_buttons: Dictionary = panel.get("_backend_buttons")
		var native_button: Button = backend_buttons["native"]
		var remote_button: Button = backend_buttons["remote"]
		var selected_color := native_button.get_theme_color("font_color")
		var idle_color := remote_button.get_theme_color("font_color")
		remote_button.emit_signal("pressed")
		t.eq(
			panel.get_options().get("retargeting_backend", ""),
			"remote",
			"Remote Retargeting button changes the selected backend"
		)
		t.is_true(remote_button.button_pressed, "Remote Retargeting button stays pressed")
		t.is_false(native_button.button_pressed, "Native Retargeting button is released")
		t.eq(
			remote_button.get_theme_color("font_color"),
			selected_color,
			"Remote Retargeting receives the selected accent colour"
		)
		t.eq(
			native_button.get_theme_color("font_color"),
			idle_color,
			"Native Retargeting returns to the idle colour"
		)
		t.eq(
			remote_button.get_theme_color("font_hover_pressed_color"),
			selected_color,
			"selected colour survives XR pointer hover"
		)

	var pose_options := _options("inside")
	pose_options["show_vr_pose"] = true
	panel.set_options(pose_options)
	t.is_true(
		bool(panel.get_options().get("show_vr_pose", false)),
		"Display's Show VR Pose toggle round-trips"
	)

	# Pressing the Type buttons is what the operator actually does.
	var outside_button: Button = panel.get("_outside_scope_button")
	var inside_button: Button = panel.get("_inside_scope_button")
	outside_button.emit_signal("pressed")
	t.eq(panel.get_options().get("target_scope", ""), "outside", "Outside button switches the page")
	t.is_true(outside_box.visible, "Outside button reveals the service settings")
	inside_button.emit_signal("pressed")
	t.eq(panel.get_options().get("target_scope", ""), "inside", "Inside button switches the page")
	t.is_true(inside_box.visible, "Inside button reveals the robot picker")

	_dispose(panel)


func _test_video_settings(panel: TestPanel, groups: Array, t: OperatorTestAssertions) -> void:
	var containers: Dictionary = panel.get("_group_containers")
	var video_group: Control = containers.get("video")
	var display_group: Control = containers.get("display")
	var protocol_buttons: Dictionary = panel.get("_video_protocol_buttons")
	var video_ip_input: LineEdit = panel.get("_video_ip_input")
	var video_port_label: Label = panel.get("_video_port_label")
	var video_port_input: LineEdit = panel.get("_video_port_input")
	var video_sbs_toggle: CheckButton = panel.get("_video_sbs_toggle")
	var video_face_toggle: CheckButton = panel.get("_video_face_toggle")
	var show_video_panel_toggle: CheckButton = panel.get("_show_video_panel_toggle")
	var connect_button: Button = panel.get("_video_connect_button")
	var status_label: Label = panel.get("_video_status_label")
	if not t.is_true(
		video_group != null
		and display_group != null
		and protocol_buttons != null
		and video_ip_input != null
		and video_port_label != null
		and video_port_input != null
		and video_sbs_toggle != null
		and video_face_toggle != null
		and show_video_panel_toggle != null
		and connect_button != null
		and status_label != null,
		"Video exposes all configuration and action controls"
	):
		return

	t.eq(groups.find("display"), groups.find("video") + 1, "Display follows Video")
	t.eq(protocol_buttons.size(), 2, "Video offers both stream protocols")
	t.is_true(
		protocol_buttons.has("operator_timed_h264"),
		"Operator Timed H.264 video protocol is offered"
	)
	t.is_true(
		protocol_buttons.has("xrobot_toolkit_fpv"),
		"XRobotToolkit FPV video protocol is offered"
	)
	t.is_true(video_group.is_ancestor_of(video_face_toggle), "face lock moved into Video")
	t.is_true(video_group.is_ancestor_of(show_video_panel_toggle), "video visibility moved into Video")
	t.is_false(display_group.is_ancestor_of(video_face_toggle), "Display no longer owns face lock")
	t.is_false(
		display_group.is_ancestor_of(show_video_panel_toggle),
		"Display no longer owns video visibility"
	)

	var legacy_options := _options("outside")
	for key in ["video_protocol", "video_ip", "video_port", "video_sbs"]:
		legacy_options.erase(key)
	panel.set_options(legacy_options)
	var defaults := panel.get_options()
	t.eq(defaults.get("video_protocol", ""), "operator_timed_h264", "legacy settings default to Operator video")
	t.eq(defaults.get("video_ip", ""), "127.0.0.1", "video IP has an independent default")
	t.eq(defaults.get("video_port", 0), 12345, "Operator video defaults to port 12345")
	t.is_false(defaults.has("video_receive_port"), "PICO receive port is not user-configurable")
	t.is_false(bool(defaults.get("video_sbs", true)), "SBS defaults off")
	t.eq(video_port_label.text, panel.tr("UI_VIDEO_STREAM_PORT"), "Operator video labels its stream port")
	t.eq(
		video_ip_input.get_parent().get_parent(),
		connect_button.get_parent(),
		"Connect is placed beside the video IP input",
	)

	var connect_requests: Array = []
	panel.video_connect_requested.connect(func(options: Dictionary) -> void:
		connect_requests.append(options.duplicate(true))
	)
	connect_button.emit_signal("pressed")
	t.eq(connect_requests.size(), 1, "Connect emits one validated request")
	if not connect_requests.is_empty():
		t.eq(
			connect_requests[0].get("video_protocol", ""),
			"operator_timed_h264",
			"Connect includes the Operator video protocol"
		)
		t.eq(connect_requests[0].get("video_port", 0), 12345, "Connect includes the video port")

	var xrt_button: Button = protocol_buttons["xrobot_toolkit_fpv"]
	var operator_button: Button = protocol_buttons["operator_timed_h264"]
	xrt_button.emit_signal("pressed")
	t.is_true(xrt_button.button_pressed, "XRobotToolkit FPV choice stays selected")
	t.is_false(operator_button.button_pressed, "Operator video choice is released")
	t.eq(panel.get_options().get("video_port", 0), 13579, "XRT switches a default port to 13579")
	t.eq(video_port_label.text, panel.tr("UI_VIDEO_COMMAND_PORT"), "XRT labels the command port")

	var xrt_options := _options("outside")
	xrt_options["video_protocol"] = "xrobot_toolkit_fpv"
	xrt_options["video_ip"] = "10.42.0.8"
	xrt_options["video_port"] = 14000
	# Old saved settings may still contain this key; it must be ignored.
	xrt_options["video_receive_port"] = 12350
	xrt_options["video_sbs"] = true
	xrt_options["video_face_locked"] = false
	xrt_options["show_video_panel"] = true
	panel.set_options(xrt_options)
	var round_trip := panel.get_options()
	t.eq(round_trip.get("video_protocol", ""), "xrobot_toolkit_fpv", "XRT video protocol round-trips")
	t.eq(round_trip.get("video_ip", ""), "10.42.0.8", "video IP round-trips independently")
	t.eq(round_trip.get("video_port", 0), 14000, "video command port round-trips")
	t.is_false(round_trip.has("video_receive_port"), "legacy receive-port settings are ignored")
	t.is_true(bool(round_trip.get("video_sbs", false)), "SBS round-trips")
	t.is_false(bool(round_trip.get("video_face_locked", true)), "face lock key remains compatible")
	t.is_true(bool(round_trip.get("show_video_panel", false)), "show video key remains compatible")
	t.eq(round_trip.get("ip", ""), "127.0.0.1", "video IP does not overwrite robot IP")

	connect_button.emit_signal("pressed")
	t.eq(connect_requests.size(), 2, "Connect emits the updated XRobotToolkit request")
	if connect_requests.size() >= 2:
		t.eq(connect_requests[1].get("video_ip", ""), "10.42.0.8", "Connect includes the video IP")
		t.eq(connect_requests[1].get("video_port", 0), 14000, "Connect includes the command port")
		t.is_false(connect_requests[1].has("video_receive_port"), "Connect leaves receive-port selection to PICO")
		t.is_true(bool(connect_requests[1].get("video_sbs", false)), "Connect includes SBS")
	t.is_true(panel.saved_options.is_empty(), "video connection does not save settings")
	panel.set_video_status("Connected")
	t.eq(status_label.text, "Connected", "Controller can update the public video status")

	video_ip_input.text = ""
	connect_button.emit_signal("pressed")
	t.eq(connect_requests.size(), 2, "empty video IP blocks Connect")
	t.eq(status_label.text, panel.tr("UI_VIDEO_IP_REQUIRED"), "empty video IP reports validation")
	video_ip_input.text = "10.42.0.8"
	video_port_input.text = "70000"
	connect_button.emit_signal("pressed")
	t.eq(connect_requests.size(), 2, "invalid video port blocks Connect")
	t.eq(status_label.text, panel.tr("UI_VIDEO_INVALID_PORT"), "invalid video port reports validation")

	var invalid_protocol_options := _options("outside")
	invalid_protocol_options["video_protocol"] = "unknown"
	panel.set_options(invalid_protocol_options)
	t.eq(
		panel.get_options().get("video_protocol", ""),
		"operator_timed_h264",
		"unknown video protocols safely fall back to Operator"
	)


func _options(scope: String) -> Dictionary:
	var offered := RobotProfileRegistry.ids()
	return {
		"target_scope": scope,
		"ip": "127.0.0.1",
		"port": 63901,
		"xrobot_toolkit_device_sn": "",
		"inside_profile": str(offered[0]) if not offered.is_empty() else "",
		"retargeting_backend": "native",
		"retargeting_host": "127.0.0.1",
		"retargeting_port": 8000,
		"retargeting_tls": false,
		"video_protocol": "operator_timed_h264",
		"video_ip": "127.0.0.1",
		"video_port": 12345,
		"video_sbs": false,
		"video_face_locked": true,
		"show_video_panel": false,
		"show_operation_trajectory": false,
		"show_vr_pose": false,
		"show_on_launch": false,
	}


func _group_keys(panel: Node) -> Array:
	var containers: Dictionary = panel.get("_group_containers")
	return containers.keys() if containers != null else []


func _dispose(panel: Node) -> void:
	if panel.get_parent() != null:
		panel.get_parent().remove_child(panel)
	panel.queue_free()
