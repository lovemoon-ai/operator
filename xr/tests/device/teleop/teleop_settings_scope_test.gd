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

	const PREFERENCES_PATH := "user://teleop_settings_scope_test.cfg"

	var saved_options: Dictionary = {}

	# Preference saves go through the real writer, into a scratch file, so the
	# test can check what Confirm actually persists without touching user data.
	func _settings_path() -> String:
		return PREFERENCES_PATH

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
	t.contains(groups, "blueprint", "the robot-authored UI group exists")
	t.eq(groups.find("video"), groups.find("robot") + 1, "Video follows Robot in the sidebar")
	t.is_false(groups.has("target"), "the separate embodiment-location group is gone")
	t.is_false(groups.has("connection"), "robot service is no longer its own group")
	t.is_false(groups.has("inside_robot"), "inside robot is no longer its own group")

	var outside_box: Control = panel.get("_outside_box")
	var inside_box: Control = panel.get("_inside_box")
	var protocol_row: HBoxContainer = panel.get("_protocol_row")
	var protocol_buttons: Dictionary = panel.get("_protocol_buttons")
	var pico_body_calibration_button: Button = panel.get("_pico_body_calibration_button")
	var picker: Dictionary = panel.get("_profile_buttons")
	if not t.is_true(
		outside_box != null
		and inside_box != null
		and protocol_row != null
		and protocol_buttons != null
		and pico_body_calibration_button != null
		and picker != null,
		"the page exposes both configuration sides"
	):
		_dispose(panel)
		return
	var xrt_available := PicoPlatformAdapter.is_pico_build()
	t.eq(
		protocol_buttons.size(),
		2 if xrt_available else 1,
		"outside offers the wire protocols this platform supports"
	)
	t.is_true(protocol_buttons.has("operator"), "Operator protocol is offered")
	t.eq(
		protocol_buttons.has("xrobot_toolkit_v1"),
		xrt_available,
		"XRoboToolkit-compatible protocol is Pico-only"
	)
	t.is_true(
		outside_box.is_ancestor_of(protocol_row),
		"protocol selection belongs to Outside Robot settings"
	)
	_test_video_settings(panel, groups, t)
	_test_blueprint_settings(panel, t)

	# Every robot is its own always-visible button: a dropdown popup cannot
	# render in this panel's composition viewport, so the operator would never
	# see anything but the current selection.
	var offered := RobotProfileRegistry.ids()
	var inside_available := not offered.is_empty()
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
	# On Pico the left-column (default) protocol is XRoboToolkit Compatible;
	# non-Pico builds only expose Operator, so the load-time default lands
	# there instead.
	t.eq(
		panel.get_options().get("protocol", ""),
		"xrobot_toolkit_v1" if xrt_available else "operator",
		"legacy settings without protocol default to the platform's left-column choice"
	)
	t.is_true(outside_box.visible, "outside shows the robot-service settings")
	t.is_true(protocol_row.visible, "outside shows protocol selection")
	# The XRoboToolkit sender identifies the headset by its own unique id; the
	# page no longer offers (or persists) a hand-typed device SN.
	t.is_false(
		panel.get_options().has("xrobot_toolkit_device_sn"),
		"the settings page carries no PICO device SN"
	)
	t.eq(
		pico_body_calibration_button.visible,
		false,
		"a selected protocol alone does not create tracking demand"
	)
	t.is_false(inside_box.visible, "outside hides the inside settings")
	var discovery_option: OptionButton = panel.get("_discovery_option")
	var ip_input: LineEdit = panel.get("_ip_input")
	var port_input: LineEdit = panel.get("_port_input")
	var endpoint_connect_button: Button = panel.get("_connect_button")
	t.is_true(endpoint_connect_button != null, "the page exposes one link action button")
	if endpoint_connect_button != null:
		t.eq(endpoint_connect_button.text, panel.tr("UI_CONNECT"), "the link action starts as Connect")
		t.eq(endpoint_connect_button.get_parent().get_child_count(), 1, "only one link action is displayed")
		# An Inside embodiment starts and stops with the same action, so the
		# row must outlive the scope switch that hides the Outside fields.
		t.is_false(
			outside_box.is_ancestor_of(endpoint_connect_button),
			"the link action is not hidden with the Outside endpoint fields",
		)
		var disconnect_requests: Array = []
		panel.disconnect_requested.connect(func() -> void:
			disconnect_requests.append(true)
		)
		panel.set_link_active(true)
		t.eq(endpoint_connect_button.text, panel.tr("UI_DISCONNECT"), "an active link changes the action to Disconnect")
		endpoint_connect_button.emit_signal("pressed")
		t.eq(disconnect_requests.size(), 1, "the active link action emits one disconnect request")
		panel.set_link_active(false)
		t.eq(endpoint_connect_button.text, panel.tr("UI_CONNECT"), "a stopped link changes the action back to Connect")
	var action_row: HBoxContainer = panel.get("_actions_row")
	var confirm_button := _first_button(action_row)
	t.is_true(confirm_button != null, "settings expose the primary bottom action")
	if confirm_button != null:
		t.eq(
			confirm_button.text,
			panel.tr("UI_OK"),
			"the bottom action uses the Confirm label",
		)
	var wifi_status_indicator: TextureRect = panel.get("_wifi_status_indicator")
	t.is_true(wifi_status_indicator != null, "the title bar exposes a Wi-Fi status icon")
	if wifi_status_indicator != null:
		t.is_true(wifi_status_indicator.texture != null, "the Wi-Fi status icon is loaded")
		t.eq(
			wifi_status_indicator.get_index(),
			(panel.get("_input_mode_indicator") as TextureRect).get_index() - 1,
			"the Wi-Fi icon sits immediately beside the hand/controller icon",
		)
	var title_send_rate_label: Label = panel.get("_send_rate_label")
	if title_send_rate_label != null and wifi_status_indicator != null:
		t.eq(
			title_send_rate_label.get_index(),
			wifi_status_indicator.get_index() - 1,
			"send FPS is third from the right, before Wi-Fi and input mode",
		)
	t.eq(
		TeleopSettingsPanel._wifi_connection_address([
			{"name": "lo", "friendly": "Loopback", "addresses": ["127.0.0.1"]},
			{"name": "wlan0", "friendly": "Wi-Fi", "addresses": ["192.168.1.25"]},
		]),
		"192.168.1.25",
		"Wi-Fi detection reports the active wireless interface address",
	)
	var shared_ip := "192.168.1.40"
	var discovered := {
		"operator|%s|63901" % shared_ip: {
			"name": "G1-D Debug",
			"ip": shared_ip,
			"pose_port": 63901,
			"device_type": "unitree_g1d",
			"protocol": "operator",
		},
		"operator|192.168.1.41|63901": {
			"name": "G1-D Debug",
			"ip": "192.168.1.41",
			"pose_port": 63901,
			"device_type": "unitree_g1d",
			"protocol": "operator",
		},
	}
	if xrt_available:
		discovered["xrobot_toolkit_v1|%s|63901" % shared_ip] = {
			"name": "XRoboToolkit %s" % shared_ip,
			"ip": shared_ip,
			"pose_port": 63901,
			"device_type": "xrobot_toolkit",
			"protocol": "xrobot_toolkit_v1",
		}
	panel.set_discovery_state(discovered)
	# One protocol at a time: a host only answers the protocol its beacon
	# announced, so offering the others' hosts only ever produced rows that
	# cannot connect.
	t.eq(discovery_option.item_count, 2 if xrt_available else 3,
		"only hosts speaking the selected protocol are offered")
	t.eq(discovery_option.selected, 0,
		"discovery without an explicitly saved endpoint leaves Manual selected")
	if xrt_available:
		(protocol_buttons["operator"] as Button).emit_signal("pressed")
		t.eq(discovery_option.item_count, 3,
			"switching to Operator re-lists that protocol's hosts")
		(protocol_buttons["xrobot_toolkit_v1"] as Button).emit_signal("pressed")
		t.eq(discovery_option.item_count, 2,
			"switching back offers the XRoboToolkit host again")

	# A discovered host's name and address are not length-bounded, so the page
	# grows to fit the longest row rather than clipping it.
	var narrow_width := panel.quad_size.x
	var selected_protocol := str(panel.get_options().get("protocol", "operator"))
	var long_label_endpoints := discovered.duplicate(true)
	long_label_endpoints["%s|192.168.1.42|63901" % selected_protocol] = {
		"name": "Robot with an exceptionally long descriptive name on one row",
		"ip": "192.168.1.42",
		"pose_port": 63901,
		"device_type": "robot_arm",
		"protocol": selected_protocol,
	}
	panel.set_discovery_state(long_label_endpoints)
	var wide_width := panel.quad_size.x
	t.is_true(wide_width > narrow_width, "a long endpoint label widens the page")
	t.eq(
		panel.layer_viewport,
		panel.get("_viewport"),
		"a resized page is rebound to its viewport so the layer is rebuilt at the new size"
	)
	panel.call("_show_ip_dropdown")
	var dropdown: VBoxContainer = panel.get("_ip_dropdown")
	if t.is_true(dropdown.get_child_count() > 0, "the host list opens with the long endpoint"):
		t.is_true(
			(dropdown.get_child(0) as Button).clip_text,
			"host rows clip instead of pushing the page past its layer"
		)
	panel.set_discovery_state(discovered)
	t.is_true(panel.quad_size.x < wide_width, "the page narrows again without that host")
	# The IP field is read-only until the operator double-clicks into edit
	# mode; the port field, which has no discovery UX, stays freely editable.
	t.is_false(ip_input.editable, "IP field is read-only until the operator double-clicks it")
	panel.call("_enter_ip_edit_mode")
	t.is_true(ip_input.editable, "double-click flips the IP field editable")
	panel.call("_leave_ip_edit_mode")
	t.is_true(port_input.editable, "manual robot port remains editable when services are discovered")
	if xrt_available:
		panel.set_discovery_state(discovered, shared_ip, "xrobot_toolkit_v1", 63901)
		t.eq(
			str(discovery_option.get_item_metadata(discovery_option.selected)),
			"xrobot_toolkit_v1|%s|63901" % shared_ip,
			"saved protocol disambiguates services that share an IP and port"
		)
		t.eq(panel.get_options().get("protocol", ""), "xrobot_toolkit_v1",
			"selecting the HoloMotion-compatible entry switches the wire protocol")
		ip_input.text = "192.168.1.41"
		panel.call("_on_manual_endpoint_changed", ip_input.text)
		t.eq(discovery_option.selected, 0, "editing a discovered endpoint switches back to Manual")

	if xrt_available:
		var xrobot_options := _options("outside")
		xrobot_options["protocol"] = "xrobot_toolkit_v1"
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
		panel.set_tracking_status({"needed": true, "mode": "body", "phase": "required", "can_calibrate": true})
		var confirm_button: Button = panel.get("_tracking_confirm_button")
		var confirm_slot: Control = panel.get("_tracking_confirm_slot")
		t.is_false(confirm_slot.visible, "confirmation is hidden before a setup round trip")
		panel.set_tracking_status({"needed": true, "mode": "body", "phase": "confirmation_waiting_tracking", "needs_confirmation": true, "can_confirm": false, "can_calibrate": true})
		t.is_true(confirm_slot.visible and confirm_button.disabled, "return shows confirmation but invalid tracking keeps it disabled")
		var confirmations: Array = []
		panel.tracker_calibration_confirm_requested.connect(func() -> void: confirmations.append(true))
		panel.set_tracking_status({"needed": true, "mode": "body", "phase": "confirming", "needs_confirmation": true, "can_confirm": true, "can_calibrate": true})
		t.is_false(confirm_button.disabled, "live tracking permits explicit user confirmation")
		confirm_button.pressed.emit()
		t.eq(confirmations.size(), 1, "confirmation emits its own action, not another calibration launch")
		panel.set_tracking_status({"needed": true, "mode": "body", "phase": "required", "can_calibrate": true})
		t.is_true(
			pico_body_calibration_button.visible,
			"active body demand shows shared calibration controls"
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
		t.is_true(
			pico_body_calibration_button.visible,
			"switching protocol cannot hide another consumer's calibration demand"
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
		var closes: Array = []
		panel.close_requested.connect(func() -> void: closes.append(true))
		# Connect starts the link and stays put so the operator can watch the
		# send rate come up; the bottom action only closes the page.
		(panel.get("_connect_button") as Button).emit_signal("pressed")
		t.eq(applied.size(), 1, "Connect emits one options dictionary")
		t.eq(closes.size(), 0, "Connect leaves the page open")
		panel.call("_on_confirm_requested")
		t.eq(applied.size(), 1, "closing the page does not restart the link")
		t.eq(closes.size(), 1, "the bottom action closes the page")
		if not applied.is_empty():
			t.eq(
				applied[0].get("protocol", ""),
				"xrobot_toolkit_v1",
				"settings_applied includes the selected protocol"
			)
		t.eq(
			panel.saved_options.get("protocol", ""),
			"xrobot_toolkit_v1",
			"saved settings include the selected protocol"
		)
	else:
		var xrobot_options := _options("outside")
		xrobot_options["protocol"] = "xrobot_toolkit_v1"
		panel.set_options(xrobot_options)
		t.eq(
			panel.get_options().get("protocol", ""),
			"operator",
			"XRoboToolkit-compatible protocol normalizes to Operator off Pico"
		)
		t.is_false(
			pico_body_calibration_button.visible,
			"non-Pico builds never show PICO Body Calibration"
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
	t.eq(panel.get_options().get("target_scope", ""), "inside" if inside_available else "outside", "Inside is selectable only when robot assets exist")
	t.eq(inside_box.visible, inside_available, "robot picker visibility follows available Inside assets")
	t.eq(outside_box.visible, not inside_available, "unavailable Inside selection keeps Outside settings")
	if inside_available:
		t.is_false(outside_box.visible and protocol_row.visible, "inside does not show protocol selection")
	t.is_false(outside_box.is_ancestor_of(pico_body_calibration_button), "shared calibration is outside the Outside-only group")
	t.is_false(inside_box.is_ancestor_of(pico_body_calibration_button), "shared calibration is outside the Inside-only group")
	t.eq(
		pico_body_calibration_button.visible,
		xrt_available,
		"Inside scope shares the same demand-driven calibration controls"
	)
	panel.set_tracking_status({"needed": false})
	t.is_false(pico_body_calibration_button.visible, "last demand release hides calibration controls")
	t.eq(
		str(panel.get_options().get("inside_profile", "")),
		str(offered[0]) if not offered.is_empty() else "",
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

	# Main menu placement: view-locked by default, world-locked on request.
	var menu_lock_buttons: Dictionary = panel.get("_menu_lock_buttons")
	t.eq(menu_lock_buttons.size(), 2, "Display offers view- and world-locked placement")
	t.is_false(
		bool(panel.get_options().get("menu_world_locked", true)),
		"the main menu is view locked by default"
	)
	var display_changes: Array = []
	panel.display_options_changed.connect(func(options: Dictionary) -> void:
		display_changes.append(options.duplicate(true))
	)
	(menu_lock_buttons["world"] as Button).emit_signal("pressed")
	t.is_true(
		bool(panel.get_options().get("menu_world_locked", false)),
		"World locked round-trips through the options dictionary"
	)
	t.eq(display_changes.size(), 1, "a display change applies immediately, without Connect")
	(menu_lock_buttons["view"] as Button).emit_signal("pressed")
	t.is_false(
		bool(panel.get_options().get("menu_world_locked", true)),
		"View locked is selectable again"
	)

	# The send rate is the page's proof that frames are going out; it belongs
	# to Connect/Disconnect, not to opening or closing the page.
	var send_rate_label: Label = panel.get("_send_rate_label")
	t.is_true(send_rate_label != null, "the page exposes a send-rate indicator")
	if send_rate_label != null:
		t.is_false(send_rate_label.visible, "the send rate is hidden while disconnected")
		panel.set_link_active(true)
		t.is_true(send_rate_label.visible, "Connect reveals the send rate")
		t.eq(
			send_rate_label.text,
			panel.tr("UI_SEND_RATE_IDLE"),
			"a link with nothing flowing yet says it is not sending"
		)
		panel.set_send_rate(72.0)
		t.is_true(
			send_rate_label.text.contains("72"),
			"the indicator reports the measured rate"
		)
		panel.set_send_rate(0.0)
		t.eq(
			send_rate_label.text,
			panel.tr("UI_SEND_RATE_IDLE"),
			"a link whose frames stopped says so instead of Sending 0.0 Hz"
		)
		panel.set_link_active(false)
		t.is_false(send_rate_label.visible, "Disconnect hides the send rate again")

	# Pointing at or clicking the page must never also drive the robot.
	t.is_true(
		panel.captures_teleop_input() and panel.captures_teleop_hover(),
		"the page neutralises teleop controller input while the pointer is on it"
	)

	# Confirm and the Display toggles keep preferences but never the endpoint:
	# launch auto-connects to a saved endpoint, so only Connect may save one.
	var preferences_path: String = TestPanel.PREFERENCES_PATH
	if FileAccess.file_exists(preferences_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(preferences_path))
	var unconfirmed := _options("outside")
	unconfirmed["ip"] = "192.168.1.50"
	unconfirmed["show_vr_pose"] = true
	panel.set_options(unconfirmed)
	panel.call("_on_confirm_requested")
	var saved := ConfigFile.new()
	if t.is_true(saved.load(preferences_path) == OK, "Confirm persists the operator's preferences"):
		t.is_true(
			bool(saved.get_value(TeleopSettingsPanel.SECTION, "show_vr_pose", false)),
			"Confirm keeps a display preference"
		)
		for link_key in TeleopSettingsPanel.LINK_OPTION_KEYS:
			t.is_false(
				saved.has_section_key(TeleopSettingsPanel.SECTION, str(link_key)),
				"Confirm does not save the unconfirmed %s" % link_key
			)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(preferences_path))

	# Pressing the Type buttons is what the operator actually does.
	var outside_button: Button = panel.get("_outside_scope_button")
	var inside_button: Button = panel.get("_inside_scope_button")
	outside_button.emit_signal("pressed")
	t.eq(panel.get_options().get("target_scope", ""), "outside", "Outside button switches the page")
	t.is_true(outside_box.visible, "Outside button reveals the service settings")
	inside_button.emit_signal("pressed")
	t.eq(inside_button.disabled, not inside_available, "Inside button requires generated robot assets")
	t.eq(panel.get_options().get("target_scope", ""), "inside" if inside_available else "outside", "Inside button respects asset availability")
	t.eq(inside_box.visible, inside_available, "Inside button reveals only an available robot picker")

	_dispose(panel)


func _test_blueprint_settings(panel: TestPanel, t: OperatorTestAssertions) -> void:
	var group_buttons: Dictionary = panel.get("_group_buttons")
	var blueprint_button: Button = group_buttons.get("blueprint")
	t.is_true(blueprint_button != null, "robot UI has a sidebar button")
	t.is_false(blueprint_button.visible, "robot UI stays hidden without a blueprint")
	var requests: Array = []
	panel.blueprint_visibility_override_requested.connect(
		func(component_id: String, visible: Variant) -> void:
			requests.append({"id": component_id, "visible": visible})
	)
	panel.set_blueprint_visibility_options([
		{"id": "hand_control", "label": "Hand control", "override": null},
		{"id": "status", "label": "Robot status", "override": false},
	])
	t.is_true(blueprint_button.visible, "robot UI appears when overridable components exist")
	var rows: Dictionary = panel.get("_blueprint_override_buttons")
	t.eq(rows.size(), 2, "one override selector is built per component")
	var hand_buttons: Dictionary = rows.get("hand_control")
	t.is_true((hand_buttons["follow"] as Button).button_pressed, "default choice follows robot")
	(hand_buttons["hide"] as Button).emit_signal("pressed")
	t.eq(requests.size(), 1, "changing a robot UI choice emits one request")
	t.eq(requests[0].get("id"), "hand_control", "override request identifies the component")
	t.eq(requests[0].get("visible"), false, "hide emits a local false override")
	(hand_buttons["follow"] as Button).emit_signal("pressed")
	t.eq(requests.size(), 2, "returning to robot control emits another request")
	t.eq(requests[1].get("visible"), null, "follow clears the local override")
	panel.set_blueprint_visibility_options([])
	t.is_false(blueprint_button.visible, "robot UI hides again when the blueprint clears")


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
	var operation_trajectory_toggle: CheckButton = panel.get("_show_operation_trajectory_toggle")
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
		and operation_trajectory_toggle != null
		and connect_button != null
		and status_label != null,
		"Video exposes all configuration and action controls"
	):
		return

	t.eq(groups.find("display"), groups.find("video") + 1, "Display follows Video")
	var xrt_available := PicoPlatformAdapter.is_pico_build()
	t.eq(
		protocol_buttons.size(),
		2 if xrt_available else 1,
		"Video offers the stream protocols this platform supports"
	)
	t.is_true(
		protocol_buttons.has("operator_timed_h264"),
		"Operator Timed H.264 video protocol is offered"
	)
	t.eq(
		protocol_buttons.has("xrobot_toolkit_fpv"),
		xrt_available,
		"XRobotToolkit FPV video protocol is Pico-only"
	)
	t.is_true(video_group.is_ancestor_of(video_face_toggle), "face lock moved into Video")
	t.is_true(video_group.is_ancestor_of(show_video_panel_toggle), "video visibility moved into Video")
	t.is_false(display_group.is_ancestor_of(video_face_toggle), "Display no longer owns face lock")
	t.is_false(
		display_group.is_ancestor_of(show_video_panel_toggle),
		"Display no longer owns video visibility"
	)
	# The assertions below all describe the native Operator wire-protocol
	# branch, so bake the protocol into the options that will land on the
	# panel rather than switching first and having the next set_options
	# overwrite it back to the XRoboToolkit default.
	var operator_options := _options("outside")
	operator_options["protocol"] = "operator"
	panel.set_options(operator_options)
	t.is_false(
		(show_video_panel_toggle.get_parent() as Control).visible,
		"native Operator hides the legacy video visibility toggle",
	)
	t.is_false(
		(video_face_toggle.get_parent() as Control).visible,
		"native Operator hides the legacy video placement toggle",
	)
	t.is_false(
		(operation_trajectory_toggle.get_parent() as Control).visible,
		"native Operator hides the legacy trajectory toggle",
	)
	if xrt_available:
		panel._on_protocol_pressed("xrobot_toolkit_v1")
		t.is_true(
			(show_video_panel_toggle.get_parent() as Control).visible,
			"XRoboToolkit keeps its local video visibility control",
		)
		panel._on_protocol_pressed("operator")

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

	var expected_requests := 1
	if xrt_available:
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
		expected_requests = 2
		t.eq(connect_requests.size(), 2, "Connect emits the updated XRobotToolkit request")
		if connect_requests.size() >= 2:
			t.eq(connect_requests[1].get("video_ip", ""), "10.42.0.8", "Connect includes the video IP")
			t.eq(connect_requests[1].get("video_port", 0), 14000, "Connect includes the command port")
			t.is_false(connect_requests[1].has("video_receive_port"), "Connect leaves receive-port selection to PICO")
			t.is_true(bool(connect_requests[1].get("video_sbs", false)), "Connect includes SBS")
		t.is_true(panel.saved_options.is_empty(), "video connection does not save settings")
	else:
		var xrt_options := _options("outside")
		xrt_options["video_protocol"] = "xrobot_toolkit_fpv"
		panel.set_options(xrt_options)
		t.eq(
			panel.get_options().get("video_protocol", ""),
			"operator_timed_h264",
			"XRT video protocol normalizes to Operator off Pico"
		)
	panel.set_video_status("Connected")
	t.eq(status_label.text, "Connected", "Controller can update the public video status")

	video_ip_input.text = ""
	connect_button.emit_signal("pressed")
	t.eq(connect_requests.size(), expected_requests, "empty video IP blocks Connect")
	t.eq(status_label.text, panel.tr("UI_VIDEO_IP_REQUIRED"), "empty video IP reports validation")
	video_ip_input.text = "10.42.0.8"
	video_port_input.text = "70000"
	connect_button.emit_signal("pressed")
	t.eq(connect_requests.size(), expected_requests, "invalid video port blocks Connect")
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


func _first_button(node: Node) -> Button:
	if node == null:
		return null
	if node is Button:
		return node as Button
	for child in node.get_children():
		var found := _first_button(child)
		if found != null:
			return found
	return null


func _dispose(panel: Node) -> void:
	if panel.get_parent() != null:
		panel.get_parent().remove_child(panel)
	panel.queue_free()
