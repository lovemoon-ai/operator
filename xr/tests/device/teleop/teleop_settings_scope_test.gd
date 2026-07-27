extends RefCounted
## Device coverage for the Teleop robot-configuration page.
##
## The page is one group: a Type row picks Inside or Outside, and only that
## side's settings are shown. This runs on the headset because the panel is a
## composition-viewport UI that needs a live rendering environment; a desktop
## fixture would not prove the operator can actually reach these controls.

const CASE_ID := "teleop.settings_scope"
const PanelScript := preload("res://scripts/ui/teleop_settings_panel.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var panel: Node = PanelScript.new()
	if not t.is_true(panel != null, "teleop settings panel instantiates"):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if t.is_true(tree != null, "a scene tree is available"):
		tree.root.add_child(panel)

	var groups: Array = _group_keys(panel)
	t.contains(groups, "robot", "the robot configuration group exists")
	t.is_false(groups.has("target"), "the separate embodiment-location group is gone")
	t.is_false(groups.has("connection"), "robot service is no longer its own group")
	t.is_false(groups.has("inside_robot"), "inside robot is no longer its own group")

	var outside_box: Control = panel.get("_outside_box")
	var inside_box: Control = panel.get("_inside_box")
	var picker: Dictionary = panel.get("_profile_buttons")
	if not t.is_true(
		outside_box != null and inside_box != null and picker != null,
		"the page exposes both configuration sides"
	):
		_dispose(panel)
		return

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
	t.is_true(outside_box.visible, "outside shows the robot-service settings")
	t.is_false(inside_box.visible, "outside hides the inside settings")

	panel.set_options(_options("inside"))
	t.eq(panel.get_options().get("target_scope", ""), "inside", "inside selection round-trips")
	t.is_true(inside_box.visible, "inside shows the robot picker")
	t.is_false(outside_box.visible, "inside hides the robot-service settings")
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
