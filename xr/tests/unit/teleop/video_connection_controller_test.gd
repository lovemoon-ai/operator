extends RefCounted
## Controller-level coverage for manual FPV connection and preview behavior.

const CASE_ID := "teleop.video_connection_controller"
const TeleopControllerScript = preload("res://scripts/app/modes/teleop_controller.gd")
const EEPoseTrajectoryScript = preload("res://scripts/ui/ee_pose_trajectory.gd")


class FakeVideoHandler:
	extends Node
	var connects: Array[Dictionary] = []
	var disconnect_calls := 0

	func connect_to_video_stream(host: String, port: int) -> void:
		connects.append({"host": host, "port": port})

	func disconnect_from_robot() -> void:
		disconnect_calls += 1

	func is_connected_to_robot() -> bool:
		return false


class FakeXrtVideoSession:
	extends Node
	var starts: Array[Dictionary] = []
	var stop_calls := 0

	func start(options: Dictionary) -> void:
		starts.append(options.duplicate(true))

	func stop() -> void:
		stop_calls += 1

	func get_transport_loss_text() -> String:
		return "N/A"


class FakeRobotView:
	extends Node
	var display_size := Vector2(3.2, 1.8)
	var follow_distance := 3.0
	var follow_camera := true
	var feeds: Array[Dictionary] = []
	var packet_source: Node
	var packets: Array[Dictionary] = []
	var show_values: Array[bool] = []
	var clear_calls := 0
	var receiving_video := false
	var panel_distances: Array[float] = []

	func configure_video_stream(feed: Dictionary) -> void:
		feeds.append(feed.duplicate(true))

	func set_packet_source(source: Node) -> void:
		packet_source = source

	func report_video_packet(packet: Dictionary) -> void:
		packets.append(packet.duplicate(true))

	func set_show_video_panel(value: bool) -> void:
		show_values.append(value)

	func set_panel_distance(value: float) -> void:
		follow_distance = value
		panel_distances.append(value)

	func clear_video_stream() -> void:
		clear_calls += 1
		receiving_video = false

	func is_receiving_video() -> bool:
		return receiving_video


class FakeSettingsPanel:
	extends Node3D
	var close_calls := 0
	var video_status := ""
	var show_video_panel_enabled: Array[bool] = []

	func close() -> void:
		close_calls += 1
		visible = false

	func set_video_status(text: String) -> void:
		video_status = text

	func set_show_video_panel_enabled(enabled: bool) -> void:
		show_video_panel_enabled.append(enabled)


class FakeSettingsButton:
	extends Node3D
	var preview_modes: Array[bool] = []

	func set_video_preview_mode(enabled: bool) -> void:
		preview_modes.append(enabled)


class FakeControllerPanel:
	extends Node3D
	var blueprint_enabled_values: Array[bool] = []

	func set_blueprint_enabled(enabled: bool) -> void:
		blueprint_enabled_values.append(enabled)

	func is_blueprint_enabled() -> bool:
		return blueprint_enabled_values.back() if not blueprint_enabled_values.is_empty() else false


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var controller = TeleopControllerScript.new()
	var tcp := FakeVideoHandler.new()
	var udp := FakeVideoHandler.new()
	var xrt := FakeXrtVideoSession.new()
	var robot_view := FakeRobotView.new()
	var settings := FakeSettingsPanel.new()
	var settings_button := FakeSettingsButton.new()
	var controller_panel := FakeControllerPanel.new()
	var trajectory := EEPoseTrajectoryScript.new()
	var control_frame_gizmo := Node3D.new()
	control_frame_gizmo.visible = true
	settings.visible = true
	settings_button.visible = false
	# Video transports belong to the host session; the controller drives them
	# through it.
	var host_session := HostSession.new()
	host_session.video_tcp_handler = tcp
	host_session.video_udp_handler = udp
	host_session.video_view = robot_view
	controller._host_session = host_session
	controller._xrt_video_session = xrt
	controller._robot_view = robot_view
	controller._settings_panel = settings
	controller._settings_ui = settings
	controller._settings_button = settings_button
	controller._teleop_controller_panel = controller_panel
	controller._ee_pose_trajectory = trajectory
	controller._control_frame_gizmos = {0: control_frame_gizmo}
	var close_offset: Transform3D = controller._video_preview_close_button_offset()
	t.is_true(
		close_offset.origin.is_equal_approx(Vector3(1.47, 0.77, -2.96)),
		"preview close button is anchored at the video panel's top-right corner",
	)

	var launch_options := {"show_video_panel": false}
	TeleopControllerScript._apply_show_video_panel_launch_override(launch_options, "true")
	t.eq(launch_options.get("show_video_panel"), true,
		"direct-launch true overrides a persisted hidden video panel")
	TeleopControllerScript._apply_show_video_panel_launch_override(launch_options, "off")
	t.eq(launch_options.get("show_video_panel"), false,
		"direct-launch false explicitly hides the video panel")
	TeleopControllerScript._apply_show_video_panel_launch_override(launch_options, "")
	t.eq(launch_options.get("show_video_panel"), false,
		"an absent launch override preserves the persisted setting")

	robot_view.follow_distance = 4.25
	controller._apply_runtime_settings({
		"target_scope": "outside",
		"protocol": "operator",
		"video_face_locked": false,
		"show_video_panel": true,
	})
	t.is_true(robot_view.follow_camera,
		"native Operator ignores local video placement until Blueprint declares it")
	t.eq(robot_view.show_values.back(), false,
		"native Operator cannot show video from a persisted local toggle")
	t.eq(controller_panel.blueprint_enabled_values.back(), false,
		"native Operator cannot auto-enable controller help")

	controller._apply_runtime_settings({
		"target_scope": "outside",
		"protocol": "xrobot_toolkit_v1",
		"video_face_locked": false,
		"show_video_panel": true,
	})
	t.is_false(robot_view.follow_camera,
		"XRoboToolkit compatibility keeps its legacy world-locked placement")
	t.eq(robot_view.show_values.back(), true,
		"XRoboToolkit compatibility keeps its local video visibility setting")
	t.eq(controller_panel.blueprint_enabled_values.back(), true,
		"XRoboToolkit compatibility keeps legacy controller help")

	controller._apply_runtime_settings({
		"target_scope": "outside",
		"protocol": "operator",
		"video_face_locked": true,
		"show_video_panel": false,
	})
	controller._on_blueprint_external_view_changed(
		"fpv",
		"video_panel",
		true,
		{"follow_camera": true, "distance": 2.5},
	)
	t.is_true(robot_view.follow_camera, "Blueprint configures the existing video view")
	t.eq(robot_view.panel_distances.back(), 2.5, "Blueprint applies video placement once")
	t.eq(robot_view.show_values.back(), true, "Blueprint opens the existing video panel")
	controller._apply_runtime_settings({
		"target_scope": "outside",
		"protocol": "xrobot_toolkit_v1",
		"video_face_locked": false,
		"show_video_panel": true,
	})
	t.is_true(is_equal_approx(robot_view.follow_distance, 4.25),
		"leaving Blueprint ownership restores the prior local video distance")
	t.eq(robot_view.panel_distances.back(), 4.25,
		"the restored local video distance is applied through the shared view API")
	controller._on_blueprint_external_view_changed("fpv", "video_panel", false, {})
	var hidden_packet := {
		"frame_id": 3,
		"nal_index": 0,
		"nal_count": 1,
		"nal_data": PackedByteArray([0, 0, 0, 1, 0x65]),
	}
	controller._on_video_frame_received(hidden_packet)
	t.eq(robot_view.show_values.back(), false, "Blueprint can hide the video blueprint")
	t.eq(robot_view.packets.back(), hidden_packet,
		"hidden video still follows the unchanged packet and decoder path")
	robot_view.packets.clear()
	controller_panel.blueprint_enabled_values.clear()
	controller._on_blueprint_external_view_changed(
		"controller_help", "controller_help", true, {}
	)
	t.eq(controller_panel.blueprint_enabled_values, [true],
		"Blueprint enables controller help through the existing renderer")
	controller._on_blueprint_external_view_changed(
		"trajectory", "operation_trajectory", true, {}
	)
	t.is_true(trajectory.is_enabled(), "Blueprint enables the existing trajectory renderer")
	control_frame_gizmo.visible = true
	controller._on_blueprint_external_view_changed(
		"control_frame", "control_frame", false, {}
	)
	t.is_false(control_frame_gizmo.visible, "Blueprint gate hides existing control-frame gizmos")

	controller._on_video_connect_requested({
		"video_protocol": "operator_timed_h264",
		"video_ip": "192.168.1.20",
		"video_port": 12345,
		"video_sbs": true,
	})
	t.eq(tcp.connects, [{"host": "192.168.1.20", "port": 12345}],
		"Operator video uses the configured endpoint")
	t.eq(xrt.stop_calls, 1, "Operator video stops the XRobotToolkit video session")
	t.eq(robot_view.clear_calls, 1, "Operator video clears any previously presented frame")
	t.eq(robot_view.packet_source, tcp, "Operator video selects the timed-video source")
	t.is_true(bool((robot_view.feeds.back() as Dictionary).get("stereo")),
		"Operator video applies SBS to the shared display")
	t.is_true(controller._video_test_active, "Connect enters preview mode")
	t.eq(robot_view.show_values.back(), true, "Connect forces the video panel visible")
	t.eq(settings.close_calls, 1, "Connect closes the settings surface")
	t.is_true(settings_button.visible, "Connect leaves the preview close button available")
	t.eq(settings_button.preview_modes, [true], "Connect turns the launcher into a close button")
	controller._end_video_test()

	controller._on_video_connect_requested({
		"video_protocol": "xrobot_toolkit_fpv",
		"video_ip": "192.168.1.30",
		"video_port": 13579,
		"video_sbs": false,
		"show_video_panel": false,
	})
	t.eq(xrt.starts.size(), 1, "XRobotToolkit Connect starts one compatibility session")
	t.eq(robot_view.clear_calls, 2, "XRobotToolkit Connect clears any previously presented frame")
	if not xrt.starts.is_empty():
		var start_options: Dictionary = xrt.starts[0]
		t.eq(start_options.get("host"), "192.168.1.30", "XRT uses the configured PC IP")
		t.eq(start_options.get("command_port"), 13579, "XRT uses the command port")
		t.is_false(start_options.has("listen_port"), "XRT selects the PICO receive port automatically")
	t.eq(robot_view.packet_source, xrt, "XRT video selects the compatibility source")
	t.is_false(bool((robot_view.feeds.back() as Dictionary).get("stereo")),
		"XRT video can configure mono display")
	t.is_true(controller._video_test_active, "XRobotToolkit Connect enters preview mode")
	t.eq(robot_view.show_values.back(), true, "XRobotToolkit Connect forces the video panel visible")
	t.eq(settings.close_calls, 2, "XRobotToolkit Connect closes the settings surface")
	t.is_true(settings_button.visible, "XRobotToolkit Connect leaves the close button available")
	t.eq(settings_button.preview_modes.back(), true, "XRobotToolkit Connect shows a close button")

	controller._on_xrt_video_frame_received({
		"frame_id": 4,
		"nal_index": 0,
		"nal_count": 1,
		"nal_data": PackedByteArray([0, 0, 0, 1, 0x65]),
		"receive_ns": 10,
	})
	t.eq(robot_view.packets.size(), 1, "XRT access units reach the shared video view")
	t.eq((robot_view.packets[0] as Dictionary).get("transport_loss_available"), false,
		"XRT packets mark transport loss unavailable")

	controller._end_video_test()
	t.is_false(controller._video_test_active, "closing preview leaves test mode")
	t.eq(robot_view.show_values.back(), false, "closing preview restores video visibility")
	t.eq(settings_button.preview_modes.back(), false, "closing preview restores the settings button")

	settings.visible = false
	controller._begin_video_test({"show_video_panel": false})
	var timeout_generation: int = controller._video_test_generation
	controller._handle_video_test_first_frame_timeout(timeout_generation)
	t.is_false(controller._video_test_active, "first-frame timeout leaves preview mode")
	t.is_true(settings.visible, "first-frame timeout restores the settings panel")
	t.eq(settings.video_status, "Video preview timed out waiting for a decoded frame",
		"first-frame timeout explains why preview closed")

	# Regression: the video panel is only meant to be visible during a running
	# preview or after the operator confirms to start teleop. A preview that
	# decoded frames used to force the panel on and silently tick the settings
	# toggle, which meant closing the preview with × (or dismissing the
	# settings panel) left video visible even though the operator did not ask
	# for it. Closing a successful preview must now hide the panel and must
	# not mutate the settings toggle.
	settings.visible = false
	robot_view.show_values.clear()
	settings.show_video_panel_enabled.clear()
	controller._begin_video_test({"show_video_panel": false})
	robot_view.receiving_video = true
	controller._end_video_test()
	t.eq(robot_view.show_values.back(), false,
		"closing a successful preview hides the video panel")
	t.eq(settings.show_video_panel_enabled, [],
		"a successful preview does not silently tick the settings toggle")
	robot_view.receiving_video = false

	# Blueprint-owned visibility survives the preview: outside/operator
	# sessions restore what `_apply_blueprint_video_panel` last declared, in
	# both directions (blueprint hides → stays hidden; blueprint shows →
	# stays shown).
	var outside_target := Node.new()
	controller._outside_target = outside_target
	controller._active_target = outside_target
	controller._blueprint_external_view_visibility["video_panel"] = false
	controller._begin_video_test({"show_video_panel": true})
	controller._end_video_test()
	t.eq(robot_view.show_values.back(), false,
		"native Operator preview restores Blueprint visibility (hidden)")

	controller._blueprint_external_view_visibility["video_panel"] = true
	controller._begin_video_test({"show_video_panel": false})
	controller._end_video_test()
	t.eq(robot_view.show_values.back(), true,
		"native Operator preview restores Blueprint visibility (visible)")

	controller.free()
	host_session.free()
	outside_target.free()
	tcp.free()
	udp.free()
	xrt.free()
	robot_view.free()
	settings.free()
	settings_button.free()
	controller_panel.free()
	trajectory.free()
	control_frame_gizmo.free()
