extends "res://scripts/teleop/teleop_target.gd"
## Outside Robot target that speaks XRoboToolkit directly to RoboticsService.
## It has no Session/DeviceDescriptor/video/clock-sync dependencies.

const XrtClientScript = preload("res://scripts/compat/xrobot_toolkit/xrt_client.gd")
const XrtSenderScript = preload("res://scripts/compat/xrobot_toolkit/xrt_sender.gd")

var client: Node
var sender: Node
var endpoint := {"host": "", "port": 0}
var _stopping := false


func _init() -> void:
	target_kind = "outside"
	descriptor = {
		"descriptor_version": 2,
		"device": {"name": "XRoboToolkit Compatible", "type": "xrobot_toolkit"},
		"execution": {"kind": "outside", "environment": "xrobot_toolkit_v1"},
	}


func configure(
	tracking_provider: Node,
	client_override: Node = null,
	sender_override: Node = null
) -> void:
	client = client_override if client_override != null else XrtClientScript.new()
	sender = sender_override if sender_override != null else XrtSenderScript.new()
	if client.get_parent() == null:
		client.name = "XrtClient"
		add_child(client)
	if sender.get_parent() == null:
		sender.name = "XrtSender"
		add_child(sender)
	if sender.has_method("configure"):
		sender.call("configure", tracking_provider, client)
	_bind_client_signals()
	if sender.has_signal("protocol_ready"):
		sender.connect("protocol_ready", Callable(self, "_on_protocol_ready"))
	if sender.has_signal("send_failed"):
		sender.connect("send_failed", Callable(self, "_on_send_failed"))


func start(config: Dictionary) -> void:
	if client == null or sender == null:
		_fail("transport_missing", "XRoboToolkit target is not configured")
		return
	var host := str(config.get("host", config.get("ip", ""))).strip_edges()
	var port := int(config.get("port", 0))
	if host.is_empty() or port <= 0 or port > 65535:
		_fail("invalid_endpoint", "Invalid XRoboToolkit endpoint")
		return
	endpoint = {"host": host, "port": port}
	_stopping = false
	control_enabled = false
	if sender.has_method("set_sending"):
		sender.call("set_sending", false)
	if sender.has_method("reset"):
		sender.call("reset")
	if sender.has_method("set_identity"):
		sender.call("set_identity", config)
	_set_state(State.STARTING, "connecting with XRoboToolkit-compatible protocol")
	client.call("connect_to_server", host, port)


func set_control_enabled(enabled: bool) -> void:
	var effective := enabled and is_ready()
	super.set_control_enabled(effective)
	if sender != null and sender.has_method("set_sending"):
		sender.call("set_sending", effective)


func stop() -> void:
	_stopping = true
	if sender != null and sender.has_method("shutdown"):
		sender.call("shutdown")
	else:
		if sender != null and sender.has_method("set_sending"):
			sender.call("set_sending", false)
		if sender != null and sender.has_method("reset"):
			sender.call("reset")
	if client != null and client.has_method("disconnect_from_server"):
		client.call("disconnect_from_server")
	super.stop()
	_stopping = false


func is_transport_ready() -> bool:
	return (
		client != null
		and client.has_method("is_connected_to_server")
		and bool(client.call("is_connected_to_server"))
		and sender != null
		and sender.has_method("is_protocol_ready")
		and bool(sender.call("is_protocol_ready"))
		and is_ready()
	)


func _bind_client_signals() -> void:
	if client.has_signal("connected"):
		client.connect("connected", Callable(self, "_on_connected"))
	if client.has_signal("disconnected"):
		client.connect("disconnected", Callable(self, "_on_disconnected"))
	if client.has_signal("failed"):
		client.connect("failed", Callable(self, "_on_failed"))


func _on_connected() -> void:
	if not client.has_method("is_connected_to_server") \
			or not bool(client.call("is_connected_to_server")):
		return
	if sender != null \
			and sender.has_method("is_protocol_ready") \
			and bool(sender.call("is_protocol_ready")):
		_on_protocol_ready()
		return
	_set_state(State.STARTING, "transport connected; completing XRoboToolkit handshake")


func _on_protocol_ready() -> void:
	if _stopping or not client.has_method("is_connected_to_server") \
			or not bool(client.call("is_connected_to_server")):
		return
	if is_ready():
		return
	_set_state(State.READY, "XRoboToolkit-compatible connection ready")
	target_ready.emit(descriptor.duplicate(true))


func _on_disconnected(reason := "XRoboToolkit connection closed") -> void:
	control_enabled = false
	if sender != null and sender.has_method("set_sending"):
		sender.call("set_sending", false)
	if sender != null and sender.has_method("reset"):
		sender.call("reset")
	if not _stopping:
		_set_state(State.STARTING, "%s; reconnecting" % reason)


func _on_failed(reason := "XRoboToolkit connection failed") -> void:
	control_enabled = false
	if sender != null and sender.has_method("set_sending"):
		sender.call("set_sending", false)
	if sender != null and sender.has_method("reset"):
		sender.call("reset")
	if not _stopping:
		_set_state(State.STARTING, "%s; reconnecting" % reason)
		warning_raised.emit("connection_failed", reason)


func _on_send_failed(reason: String) -> void:
	if not _stopping:
		warning_raised.emit("send_failed", reason)
