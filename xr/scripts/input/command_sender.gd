class_name CommandSender
extends Node
## Sends DeviceCommand frames for v2 devices.
## Replaces PoseSender when the robot provides a DeviceDescriptor.
## Uses ControlMode to map VR inputs to the device's expected command format.

signal command_sent(command: Dictionary)

var tracking_provider: TrackingProvider
var tcp_handler: TcpHandler
## Preferred v3 boundary. A transport implements `is_transport_ready()` and
## `send_operator_command(Dictionary)`. `tcp_handler` remains as a compatibility
## fallback for tests and older composition code.
var transport: Object
var control_mode: ControlMode
var _sending: bool = false
var _min_send_interval: float = 1.0 / 72.0
var _time_since_last_send: float = 0.0
var _last_enable_state: bool = false
var _has_last_enable_state: bool = false
var _last_command_summary_msec: int = 0


func configure_for_device(descriptor: Dictionary) -> void:
	control_mode = ControlMode.new()
	control_mode.configure(descriptor)
	print("[CommandSender] Configured for device: %s" % descriptor.get("device", {}).get("name", "unknown"))


# Sample + send in _process (render rate, ~72/90Hz on Quest) rather than
# _physics_process (fixed 60Hz). The XR controller transform is freshest at
# render time (predicted to the display photon instant), and sending above the
# robot's 60Hz consume loop means every consume gets a fresh frame instead of a
# repeat, lifting delivered fresh-target rate toward the loop cap. The 1/72 gate
# still bounds the wire rate so a 90/120Hz headset doesn't oversend.
func _process(delta: float) -> void:
	if not _sending or not control_mode: return
	if not _transport_ready(): return
	if not tracking_provider: return
	_time_since_last_send += delta
	if _time_since_last_send < _min_send_interval: return
	_time_since_last_send = 0.0

	var cmd = control_mode.collect_command(tracking_provider)
	_report_enable_transition(cmd)
	_report_active_command_summary(cmd)
	if _send_command(cmd) == OK:
		command_sent.emit(cmd)


func _transport_ready() -> bool:
	if transport != null and transport.has_method("is_transport_ready"):
		return bool(transport.call("is_transport_ready"))
	return tcp_handler != null and tcp_handler.is_connected_to_robot()


func _send_command(command: Dictionary) -> Error:
	if transport != null and transport.has_method("send_operator_command"):
		return transport.call("send_operator_command", command)
	if tcp_handler == null:
		return ERR_CONNECTION_ERROR
	var json_bytes = JSON.stringify(command).to_utf8_buffer()
	return tcp_handler.send_command("DeviceCommand", json_bytes)


func set_sending(enabled: bool) -> void:
	_sending = enabled
	_time_since_last_send = 0.0
	if enabled:
		print("[CommandSender] Sending enabled")
	else:
		print("[CommandSender] Sending disabled")


func _report_enable_transition(cmd: Dictionary) -> void:
	var buttons: Dictionary = cmd.get("buttons", {})
	if not buttons.has("enable"):
		return
	var enabled := bool(buttons.get("enable", false))
	if _has_last_enable_state and enabled == _last_enable_state:
		return
	_has_last_enable_state = true
	_last_enable_state = enabled
	print("[CommandSender] enable=%s (teleop deadman)" % str(enabled))


func _report_active_command_summary(cmd: Dictionary) -> void:
	var buttons: Dictionary = cmd.get("buttons", {})
	if not bool(buttons.get("enable", false)):
		_last_command_summary_msec = 0
		return
	var now_msec := Time.get_ticks_msec()
	if now_msec - _last_command_summary_msec < 1000:
		return
	_last_command_summary_msec = now_msec

	var axes: Dictionary = cmd.get("axes", {})
	var poses: Dictionary = cmd.get("poses", {})
	var has_pose := poses.has("end_effector")
	var pose_msg := "none"
	if has_pose:
		var pose: Dictionary = poses.get("end_effector", {})
		var position: Array = pose.get("position", [])
		if position.size() >= 3:
			pose_msg = "(%.3f, %.3f, %.3f)" % [float(position[0]), float(position[1]), float(position[2])]
	print("[CommandSender] active pose=%s pos=%s gripper=%.2f" % [
		str(has_pose),
		pose_msg,
		float(axes.get("gripper", 0.0)),
	])


func is_sending() -> bool:
	return _sending
