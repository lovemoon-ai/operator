extends "res://scripts/teleop/teleop_target.gd"
## Adapter around the existing robot-service command transport. The robot type,
## control mapping, video, telemetry, and safety contract all come from the
## DeviceDescriptor received after connection; this target never owns a local
## robot profile.

var tcp_handler: TcpHandler
var endpoint := {"host": "", "port": 0}


func _init() -> void:
	target_kind = "outside"


func configure(handler: TcpHandler) -> void:
	tcp_handler = handler


func start(config: Dictionary) -> void:
	if tcp_handler == null:
		_fail("transport_missing", "Outside Robot requires a robot-service transport")
		return
	var host := str(config.get("host", config.get("ip", ""))).strip_edges()
	var port := int(config.get("port", 0))
	if host.is_empty() or port <= 0 or port > 65535:
		_fail("invalid_endpoint", "Invalid robot-service endpoint")
		return
	endpoint = {"host": host, "port": port}
	descriptor.clear()
	_set_state(State.STARTING, "connecting to robot-service")
	tcp_handler.connect_to_robot(host, port)


func mark_transport_connected() -> void:
	_set_state(State.STARTING, "waiting for DeviceDescriptor")


func apply_descriptor(value: Dictionary) -> void:
	descriptor = value.duplicate(true)
	_set_state(State.READY, "robot-service descriptor accepted")
	target_ready.emit(descriptor)


func mark_transport_disconnected(reason := "robot-service disconnected") -> void:
	control_enabled = false
	descriptor.clear()
	_set_state(State.IDLE, reason)


func mark_connection_failed(reason: String) -> void:
	_fail("connection_failed", reason)


func stop() -> void:
	control_enabled = false
	if tcp_handler != null:
		tcp_handler.disconnect_from_robot()
	super.stop()


func is_transport_ready() -> bool:
	return tcp_handler != null and tcp_handler.is_connected_to_robot() and is_ready()


func send_operator_command(command: Dictionary) -> Error:
	if not is_transport_ready():
		return ERR_CONNECTION_ERROR
	var json_bytes := JSON.stringify(command).to_utf8_buffer()
	return tcp_handler.send_command("DeviceCommand", json_bytes)


func submit_operator_frame(frame: Dictionary) -> Error:
	return send_operator_command(frame)
