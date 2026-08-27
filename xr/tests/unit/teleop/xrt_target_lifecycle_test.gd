extends RefCounted
## Unit coverage for the dependency-injected XRoboToolkit target. The fakes do
## not open sockets or interact with a robot.

const CASE_ID := "teleop.xrt_target_lifecycle"
const TeleopTargetScript := preload("res://scripts/teleop/teleop_target.gd")
const XRobotToolkitTargetScript := preload(
	"res://scripts/teleop/targets/xrobot_toolkit_target.gd"
)


class FakeClient:
	extends Node

	signal connected
	signal disconnected(reason: String)
	signal failed(reason: String)

	var connect_calls := 0
	var disconnect_calls := 0
	var host := ""
	var port := 0
	var transport_connected := false

	func connect_to_server(next_host: String, next_port: int) -> void:
		_record_connect(next_host, next_port)

	func connect_to_host(next_host: String, next_port: int) -> void:
		_record_connect(next_host, next_port)

	func start(host_or_config: Variant, next_port := 0) -> void:
		if host_or_config is Dictionary:
			_record_connect(str(host_or_config.get("host", "")), int(host_or_config.get("port", 0)))
		else:
			_record_connect(str(host_or_config), int(next_port))

	func disconnect_from_server() -> void:
		_record_disconnect()

	func disconnect_from_host() -> void:
		_record_disconnect()

	func stop() -> void:
		_record_disconnect()

	func is_connected_to_server() -> bool:
		return transport_connected

	func emit_connected() -> void:
		transport_connected = true
		connected.emit()

	func emit_disconnected(reason := "test disconnect") -> void:
		transport_connected = false
		disconnected.emit(reason)

	func emit_failed(reason := "test failure") -> void:
		transport_connected = false
		failed.emit(reason)

	func _record_connect(next_host: String, next_port: int) -> void:
		connect_calls += 1
		host = next_host
		port = next_port

	func _record_disconnect() -> void:
		disconnect_calls += 1
		transport_connected = false


class FakeSender:
	extends Node
	signal protocol_ready

	var configure_calls := 0
	var start_calls := 0
	var stop_calls := 0
	var reset_calls := 0
	var shutdown_calls := 0
	var tracking_provider: Object
	var client: Object
	var xrt_client: Object
	var sending := false
	var protocol_ready_state := false
	var identity: Dictionary = {}

	func configure(provider: Object, transport: Object = null) -> void:
		configure_calls += 1
		tracking_provider = provider
		client = transport
		xrt_client = transport

	func start() -> void:
		start_calls += 1

	func stop() -> void:
		stop_calls += 1
		sending = false

	func reset() -> void:
		reset_calls += 1
		protocol_ready_state = false

	func shutdown() -> void:
		shutdown_calls += 1
		sending = false

	func set_identity(options: Dictionary) -> void:
		identity = options.duplicate(true)

	func set_sending(enabled: bool) -> void:
		sending = enabled

	func set_enabled(enabled: bool) -> void:
		sending = enabled

	func set_control_enabled(enabled: bool) -> void:
		sending = enabled

	func is_sending() -> bool:
		return sending

	func is_protocol_ready() -> bool:
		return protocol_ready_state

	func emit_protocol_ready() -> void:
		protocol_ready_state = true
		protocol_ready.emit()


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_connection_and_control_lifecycle(t)
	_test_connection_failure(t)


func _test_connection_and_control_lifecycle(t: OperatorTestAssertions) -> void:
	var target = XRobotToolkitTargetScript.new()
	var provider := TrackingProvider.new()
	var client := FakeClient.new()
	var sender := FakeSender.new()
	var ready_descriptors: Array = []
	var stopped_count := [0]
	target.target_ready.connect(
		func(descriptor: Dictionary) -> void: ready_descriptors.append(descriptor.duplicate(true))
	)
	target.stopped.connect(func() -> void: stopped_count[0] += 1)
	target.configure(provider, client, sender)

	target.start({
		"host": "192.0.2.10",
		"port": 63901,
		"device_sn": "pico-device-sn",
		"app_version": "operator-test-version",
	})
	t.eq(client.connect_calls, 1, "start initiates exactly one client connection")
	t.eq(client.host, "192.0.2.10", "start forwards the configured host")
	t.eq(client.port, 63901, "start forwards the XRoboToolkit port")
	t.eq(sender.identity.get("device_sn"), "pico-device-sn",
		"start injects the configured device identity into the sender")
	t.eq(sender.identity.get("app_version"), "operator-test-version",
		"start injects the configured app version into the sender")
	t.eq(target.state, TeleopTargetScript.State.STARTING,
		"target remains STARTING until the client connects")
	t.is_false(target.is_ready(), "target is not ready before client connected")
	t.is_false(sender.is_sending(), "tracking remains disabled before target readiness")

	client.emit_connected()
	t.eq(target.state, TeleopTargetScript.State.STARTING,
		"TCP connection alone does not make the target ready")
	t.is_false(target.is_ready(), "target waits for handshake and neutral completion")
	t.eq(ready_descriptors.size(), 0, "TCP connection does not emit target_ready")

	sender.emit_protocol_ready()
	t.is_true(target.is_ready(), "protocol_ready transitions the target to ready")
	t.eq(ready_descriptors.size(), 1, "protocol_ready emits target_ready once")
	t.is_false(target.descriptor.is_empty(), "ready target exposes a synthetic local descriptor")
	t.is_false(sender.is_sending(), "ready target does not enable control implicitly")

	target.set_control_enabled(true)
	t.eq(target.state, TeleopTargetScript.State.ACTIVE,
		"enabling control transitions the target to ACTIVE")
	t.is_true(target.control_enabled, "target records enabled control state")
	t.is_true(sender.is_sending(), "enabling control starts the compatibility sender")

	target.set_control_enabled(false)
	t.eq(target.state, TeleopTargetScript.State.READY,
		"disabling control returns the target to READY")
	t.is_false(target.control_enabled, "target clears disabled control state")
	t.is_false(sender.is_sending(), "disabling control stops compatibility frames")

	target.set_control_enabled(true)
	client.emit_disconnected()
	t.is_false(target.is_ready(), "disconnect removes target readiness")
	t.is_false(target.control_enabled, "disconnect clears the control state")
	t.is_false(sender.is_sending(), "disconnect stops compatibility frames")
	t.is_false(sender.is_protocol_ready(), "disconnect clears protocol readiness")
	t.eq(sender.shutdown_calls, 0, "recoverable disconnect does not release sampler resources")

	client.emit_connected()
	t.is_false(target.is_ready(), "reconnected transport still waits for a fresh neutral frame")
	sender.emit_protocol_ready()
	t.is_true(target.is_ready(), "post-reconnect protocol_ready restores readiness")
	t.eq(ready_descriptors.size(), 2, "reconnect emits readiness only after neutral succeeds")

	target.stop()
	t.eq(client.disconnect_calls, 1, "stop closes the compatibility client")
	t.is_false(sender.is_sending(), "stop leaves the compatibility sender disabled")
	t.eq(sender.shutdown_calls, 1, "target stop releases compatibility sampler resources once")
	t.eq(target.state, TeleopTargetScript.State.IDLE, "stop returns the target to IDLE")
	t.eq(stopped_count[0], 1, "stop emits the target stopped signal")

	_free_fixture(target, provider, client, sender)


func _test_connection_failure(t: OperatorTestAssertions) -> void:
	var target = XRobotToolkitTargetScript.new()
	var provider := TrackingProvider.new()
	var client := FakeClient.new()
	var sender := FakeSender.new()
	var warnings: Array = []
	target.warning_raised.connect(
		func(code: String, message: String) -> void: warnings.append([code, message])
	)
	target.configure(provider, client, sender)
	target.start({"host": "192.0.2.11", "port": 63901})

	client.emit_failed("connection refused")
	t.eq(target.state, TeleopTargetScript.State.STARTING,
		"client failure keeps the reconnecting target in STARTING")
	t.is_false(target.control_enabled, "client failure disables control")
	t.is_false(sender.is_sending(), "client failure stops compatibility frames")
	t.eq(warnings.size(), 1, "client failure emits one recoverable warning")
	if not warnings.is_empty():
		t.eq(warnings[0][0], "connection_failed", "target reports a stable failure code")
		t.contains(warnings[0][1], "connection refused", "target preserves client failure detail")

	target.stop()
	_free_fixture(target, provider, client, sender)


func _free_fixture(target: Node, provider: Node, client: Node, sender: Node) -> void:
	var client_owned := client.get_parent() == target
	var sender_owned := sender.get_parent() == target
	target.free()
	if is_instance_valid(provider) and provider.get_parent() == null:
		provider.free()
	if not client_owned and is_instance_valid(client):
		client.free()
	if not sender_owned and is_instance_valid(sender):
		sender.free()
