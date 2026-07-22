extends RefCounted
## Regression coverage for SDK-mode stream exclusivity across settings-panel
## suspend/resume transitions.

const CASE_ID := "teleop.sdk_mode_suspension"
const TeleopControllerScript = preload("res://scripts/app/modes/teleop_controller.gd")


class FakeRobotSink:
	extends RobotControlSink
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

	func is_connected_to_robot() -> bool:
		return connected


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var controller = TeleopControllerScript.new()
	var robot_sink := FakeRobotSink.new()
	var xr_sender := FakeXrSender.new()
	var tcp := FakeTcpHandler.new()
	controller._robot_control_sink = robot_sink
	controller._xr_state_sender = xr_sender
	controller._tcp_handler = tcp

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

	controller._on_device_disconnected()
	t.is_false(controller._sdk_mode, "disconnect clears persisted SDK mode")
	t.is_false(robot_sink.is_sending(), "disconnect disables robot commands")
	t.is_false(xr_sender.is_sending(), "disconnect disables XR state")

	controller.free()
	xr_sender.free()
	tcp.free()
