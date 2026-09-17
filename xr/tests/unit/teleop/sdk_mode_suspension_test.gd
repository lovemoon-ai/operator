extends RefCounted
## Regression coverage for SDK-mode stream exclusivity across settings-panel
## suspend/resume transitions.

const CASE_ID := "teleop.sdk_mode_suspension"
const TeleopControllerScript = preload("res://scripts/app/modes/teleop_controller.gd")


class FakeRobotSink:
	extends RobotControlSink
	# SensorSink is RefCounted, not a scene Node. Never manually free this
	# instance while the controller or the local variable still references it.
	var sending := false
	var configurations := 0

	func configure_for_device(_descriptor: Dictionary) -> void:
		configurations += 1

	func set_sending(enabled: bool) -> void:
		sending = enabled

	func is_sending() -> bool:
		return sending


class FakeXrSender:
	extends XrStateSender
	var sending := false
	var configurations := 0

	func configure(_stream_config: Dictionary) -> void:
		configurations += 1

	func set_sending(enabled: bool) -> void:
		sending = enabled

	func is_sending() -> bool:
		return sending


class FakeTcpHandler:
	extends Node
	var connected := false
	var disconnect_calls := 0
	var host := ""
	var port := 0

	func is_connected_to_robot() -> bool:
		return connected

	func disconnect_from_robot() -> void:
		disconnect_calls += 1
		connected = false

	func get_host() -> String:
		return host

	func get_port() -> int:
		return port


class FakeCommandSender:
	extends CommandSender


class FakeOutsideTarget:
	extends Node
	var starts: Array = []

	func start(options: Dictionary) -> void:
		starts.append(options.duplicate(true))


class FakeXrtTarget:
	extends Node
	var target_ready_state := true
	var control_enabled := false
	var starts: Array = []

	func is_ready() -> bool:
		return target_ready_state

	func set_control_enabled(enabled: bool) -> void:
		control_enabled = enabled

	func start(options: Dictionary) -> void:
		starts.append(options.duplicate(true))


class FakeBlueprint:
	extends BlueprintRuntime
	var clear_calls := 0

	func clear() -> void:
		clear_calls += 1

	func user_visibility_options() -> Array:
		return []


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_stream_exclusivity(t)
	_test_protocol_aware_outside_start(t)
	_test_protocol_aware_discovery_identity(t)


func _test_stream_exclusivity(t: OperatorTestAssertions) -> void:
	var controller = TeleopControllerScript.new()
	var robot_sink := FakeRobotSink.new()
	var xr_sender := FakeXrSender.new()
	var tcp := FakeTcpHandler.new()
	var xrt_target := FakeXrtTarget.new()
	controller._robot_control_sink = robot_sink
	controller._xr_state_sender = xr_sender
	controller._tcp_handler = tcp
	controller._xrt_target = xrt_target

	controller._on_device_connected({
		"device": {"name": "SDK regression", "type": "pyoperator"},
		"xr_stream": {"schema_version": 1, "rate_hz": 72, "streams": ["head"]},
	})
	t.is_true(controller._sdk_mode, "SDK mode persists after descriptor handling")
	t.eq(xr_sender.configurations, 1, "SDK stream descriptor configures XR state sender")

	# The descriptor arrived while disconnected in this fixture. Once connected,
	# opening then closing settings must resume XR state only, never commands.
	tcp.connected = true
	controller._set_teleop_suspended(true)
	t.is_false(robot_sink.is_sending(), "settings suspend robot command sender")
	t.is_false(xr_sender.is_sending(), "settings suspend XR state sender")
	controller._set_teleop_suspended(false)
	t.is_false(robot_sink.is_sending(),
		"closing settings in SDK mode must not re-enable DeviceCommand")
	t.is_true(xr_sender.is_sending(), "closing settings resumes XR state stream")

	# Repeated toggles preserve the same mutual-exclusion invariant.
	controller._set_teleop_suspended(true)
	controller._set_teleop_suspended(false)
	t.is_false(robot_sink.is_sending(), "repeated SDK resume keeps commands disabled")
	t.is_true(xr_sender.is_sending(), "repeated SDK resume keeps XR state enabled")
	t.is_false(xrt_target.control_enabled, "Operator SDK mode keeps XRoboToolkit disabled")

	controller._active_target = xrt_target
	controller._sdk_mode = false
	controller._sync_stream_senders()
	t.is_false(robot_sink.is_sending(), "XRoboToolkit mode disables DeviceCommand")
	t.is_false(xr_sender.is_sending(), "XRoboToolkit mode disables XrStateFrame")
	t.is_true(xrt_target.control_enabled, "XRoboToolkit mode enables only its sender")
	controller._set_teleop_suspended(true)
	t.is_false(xrt_target.control_enabled, "settings suspend XRoboToolkit tracking")
	controller._set_teleop_suspended(false)
	t.is_true(xrt_target.control_enabled, "closing settings resumes XRoboToolkit tracking")

	controller._active_target = controller._outside_target
	controller._sync_stream_senders()
	controller._on_device_disconnected()
	t.is_false(controller._sdk_mode, "disconnect clears persisted SDK mode")
	t.is_false(robot_sink.is_sending(), "disconnect disables robot commands")
	t.is_false(xr_sender.is_sending(), "disconnect disables XR state")
	t.is_false(xrt_target.control_enabled, "returning to Operator disables XRoboToolkit")

	controller.free()
	xr_sender.free()
	tcp.free()
	xrt_target.free()


func _test_protocol_aware_outside_start(t: OperatorTestAssertions) -> void:
	var controller = TeleopControllerScript.new()
	var robot_sink := FakeRobotSink.new()
	var xr_sender := FakeXrSender.new()
	var tcp := FakeTcpHandler.new()
	var command_sender := FakeCommandSender.new()
	var outside_target := FakeOutsideTarget.new()
	var xrt_target := FakeXrtTarget.new()
	var blueprint := FakeBlueprint.new()
	controller._robot_control_sink = robot_sink
	controller._xr_state_sender = xr_sender
	controller._tcp_handler = tcp
	controller._command_sender = command_sender
	controller._outside_target = outside_target
	controller._xrt_target = xrt_target
	controller._blueprint_runtime = blueprint

	var started := bool(controller._start_outside_with_options({
		"protocol": "xrobot_toolkit_v1",
		"ip": "192.168.1.20",
		"port": 63901,
		"xrobot_toolkit_device_sn": "PICO-SN-123",
	}))
	t.is_true(started, "XRoboToolkit outside target starts successfully")
	t.eq(controller._active_target, xrt_target,
		"XRoboToolkit selection activates only the compatibility target")
	t.eq(command_sender.transport, null,
		"XRoboToolkit selection detaches the Operator command transport")
	t.eq(xrt_target.starts.size(), 1, "XRoboToolkit target receives one start request")
	t.eq((xrt_target.starts[0] as Dictionary).get("device_sn"), "PICO-SN-123",
		"XRoboToolkit target receives the configured legacy device SN")
	t.eq(outside_target.starts.size(), 0,
		"XRoboToolkit selection does not start the Operator target")
	t.eq(tcp.disconnect_calls, 1,
		"XRoboToolkit selection closes any Operator protocol connection")
	t.eq(blueprint.clear_calls, 1,
		"XRoboToolkit selection clears the Operator blueprint runtime")

	started = bool(controller._start_outside_with_options({
		"protocol": "operator",
		"ip": "192.168.1.30",
		"port": 63901,
	}))
	t.is_true(started, "Operator outside target starts successfully")
	t.eq(controller._active_target, outside_target,
		"Operator selection activates the native outside target")
	t.eq(command_sender.transport, outside_target,
		"Operator selection restores the command transport")
	t.eq(outside_target.starts.size(), 1, "Operator target receives one start request")
	t.eq((outside_target.starts[0] as Dictionary).get("host"), "192.168.1.30",
		"Operator target receives the configured host")

	controller.free()
	xr_sender.free()
	tcp.free()
	command_sender.free()
	outside_target.free()
	xrt_target.free()
	blueprint.free()


func _test_protocol_aware_discovery_identity(t: OperatorTestAssertions) -> void:
	var controller = TeleopControllerScript.new()
	var shared_ip := "192.168.1.40"
	var operator_info := {
		"name": "g1d-debug",
		"ip": shared_ip,
		"pose_port": 63901,
		"protocol": "operator",
	}
	var xrt_info := {
		"name": "XRoboToolkit %s" % shared_ip,
		"ip": shared_ip,
		"pose_port": 63901,
		"protocol": "xrobot_toolkit_v1",
	}
	controller._known_robots = {
		TeleopControllerScript._operator_discovery_key(shared_ip, 63901): operator_info,
		TeleopControllerScript._xrt_discovery_key(shared_ip, 63901): xrt_info,
	}

	t.eq(controller._known_robots.size(), 2,
		"Operator and XRoboToolkit services on one IP remain separate choices")
	t.eq(controller._find_known_robot(shared_ip, "operator", 63901), operator_info,
		"Operator lookup selects the native service")
	t.eq(controller._find_known_robot(shared_ip, "xrobot_toolkit_v1", 63901), xrt_info,
		"XRoboToolkit lookup selects the HoloMotion-compatible service")
	var alternate_operator_info := {
		"name": "g1d-debug-alt",
		"ip": shared_ip,
		"pose_port": 64001,
		"video_port": 12445,
		"protocol": "operator",
	}
	controller._known_robots[
		TeleopControllerScript._operator_discovery_key(shared_ip, 64001)
	] = alternate_operator_info
	t.eq(controller._find_known_robot(shared_ip, "operator", 64001), alternate_operator_info,
		"Operator lookup keeps same-IP services separated by command port")
	var active_transport := FakeTcpHandler.new()
	active_transport.connected = true
	active_transport.host = shared_ip
	active_transport.port = 63901
	controller._tcp_handler = active_transport
	controller._active_telemetry_port = 63903
	controller._on_robot_found(
		"g1d-debug-alt", shared_ip, 64001, 12445, 64003, "unitree_g1d", ""
	)
	t.eq(controller._active_telemetry_port, 63903,
		"a same-IP announcement on another command port cannot retarget active media")
	t.is_false(TeleopControllerScript._discovery_matches_options(xrt_info, {
		"ip": shared_ip,
		"port": 63901,
		"protocol": "operator",
	}), "auto-connect requires the saved protocol as well as IP and port")
	t.is_true(TeleopControllerScript._discovery_matches_options(xrt_info, {
		"ip": shared_ip,
		"port": 63901,
		"protocol": "xrobot_toolkit_v1",
	}), "the exact saved XRoboToolkit endpoint remains eligible for auto-connect")
	t.is_false(TeleopControllerScript._can_auto_connect_discovered(xrt_info, {
		"loaded": false,
		"ip": shared_ip,
		"port": 63901,
		"protocol": "xrobot_toolkit_v1",
	}), "fresh defaults never auto-connect to the only discovered service")

	var second_ip := "192.168.1.41"
	controller._known_robots = {
		TeleopControllerScript._operator_discovery_key(shared_ip, 63901): operator_info,
		TeleopControllerScript._operator_discovery_key(second_ip, 63901): {
			"name": "g1d-debug",
			"ip": second_ip,
			"pose_port": 63901,
			"protocol": "operator",
		},
	}
	t.eq(controller._known_robots.size(), 2,
		"same-name Operator services retain separate endpoint identities")
	t.eq(controller._find_known_robot(second_ip, "operator", 63901).get("name"), "g1d-debug",
		"same-name Operator lookup resolves the requested endpoint")
	t.is_true(TeleopControllerScript._can_auto_connect_discovered(xrt_info, {
		"loaded": true,
		"ip": shared_ip,
		"port": 63901,
		"protocol": "xrobot_toolkit_v1",
	}), "an explicitly saved exact endpoint may still auto-connect")

	active_transport.free()
	controller.free()
