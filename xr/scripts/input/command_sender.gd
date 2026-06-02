class_name CommandSender
extends Node
## Sends DeviceCommand frames for v2 devices.
## Replaces PoseSender when the robot provides a DeviceDescriptor.
## Uses ControlMode to map VR inputs to the device's expected command format.

var tracking_provider: TrackingProvider
var tcp_handler: TcpHandler
var control_mode: ControlMode
var _sending: bool = false
var _min_send_interval: float = 1.0 / 72.0
var _time_since_last_send: float = 0.0


func configure_for_device(descriptor: Dictionary) -> void:
	control_mode = ControlMode.new()
	control_mode.configure(descriptor)
	print("[CommandSender] Configured for device: %s" % descriptor.get("device", {}).get("name", "unknown"))


func _physics_process(delta: float) -> void:
	if not _sending or not control_mode: return
	if not tcp_handler or not tcp_handler.is_connected_to_robot(): return
	if not tracking_provider: return
	_time_since_last_send += delta
	if _time_since_last_send < _min_send_interval: return
	_time_since_last_send = 0.0

	var cmd = control_mode.collect_command(tracking_provider)
	var json_bytes = JSON.stringify(cmd).to_utf8_buffer()
	tcp_handler.send_command("DeviceCommand", json_bytes)


func set_sending(enabled: bool) -> void:
	_sending = enabled
	_time_since_last_send = 0.0
	if enabled:
		print("[CommandSender] Sending enabled")
	else:
		print("[CommandSender] Sending disabled")


func is_sending() -> bool:
	return _sending
