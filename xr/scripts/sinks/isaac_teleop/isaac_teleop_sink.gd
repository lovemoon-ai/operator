class_name IsaacTeleopSink
extends SensorSink
## Low-latency SensorFrame sink for the Operator IsaacTeleop gateway.
##
## The sink owns one connected UDP peer.  Frames are encoded and sent as
## independent channels so a lost hand/body packet cannot delay head or
## controller control.  There is deliberately no retry queue: every new
## SensorFrame supersedes older data for that channel.

const DEFAULT_UDP_PORT := 63904
const DEFAULT_DESCRIPTOR_VERSION := 1

# PoseSampler controller input bit assignments.
const INPUT_THUMBSTICK_CLICK := 1 << 3
const INPUT_A_CLICK := 1 << 5
const INPUT_B_CLICK := 1 << 7
const INPUT_X_CLICK := 1 << 9
const INPUT_Y_CLICK := 1 << 11
const INPUT_MENU_CLICK := 1 << 13

var _udp: PacketPeerUDP = null
var _active := false
var _host := ""
var _port := DEFAULT_UDP_PORT
var _session_token := 0
var _descriptor_version := DEFAULT_DESCRIPTOR_VERSION
var _sequences: Dictionary = {}
var _controllers: Dictionary = {}
var _sent_packets := 0
var _sent_bytes := 0
var _send_errors := 0
var _dropped_invalid := 0
var _dropped_unmappable_body := 0
var _mapped_meta_body_frames := 0
var _mapped_meta_body_joints := 0
var _mapped_meta_valid_joints := 0
var _last_sent_timestamp_ns := 0


func accepted_frame_types() -> Array:
	return [
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.INPUT_EVENT,
		SensorFrameType.HAND,
		SensorFrameType.BODY,
	]


## Options: host, udp_port (default 63904), session_token (default 0),
## descriptor_version (default 1).  token=0 is the intentional anonymous
## first-version mode accepted by the gateway.
func start(options: Dictionary) -> bool:
	stop()
	_host = String(options.get("host", "")).strip_edges()
	_port = int(options.get("udp_port", DEFAULT_UDP_PORT))
	_session_token = int(options.get("session_token", 0))
	_descriptor_version = int(options.get("descriptor_version", DEFAULT_DESCRIPTOR_VERSION))
	if _host.is_empty() or _port <= 0 or _port > 65535:
		_send_errors += 1
		return false
	_udp = PacketPeerUDP.new()
	var error := _udp.connect_to_host(_host, _port)
	if error != OK:
		_udp.close()
		_udp = null
		_send_errors += 1
		return false
	_active = true
	_controllers.clear()
	return true


func stop() -> Dictionary:
	_active = false
	if _udp != null:
		_udp.close()
	_udp = null
	_controllers.clear()
	# Keep per-kind sequences monotonic across reconnects.  Anonymous token=0
	# cannot give the gateway a fresh session identity, so resetting to 1 here
	# would make every packet look stale until the bridge restarts.
	return {}


func is_sending() -> bool:
	return _active and _udp != null


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null or not is_sending():
		return false
	if frame.timestamp_ns <= 0:
		_dropped_invalid += 1
		return false
	var sent := false
	match frame.frame_type:
		SensorFrameType.POSE:
			sent = _send_head(frame)
		SensorFrameType.CONTROLLER:
			sent = _update_controller_pose(frame)
		SensorFrameType.INPUT_EVENT:
			sent = _update_controller_input(frame)
		SensorFrameType.HAND:
			sent = _send_hand(frame)
		SensorFrameType.BODY:
			sent = _send_body(frame)
	return sent


func send_control(
	kill: bool,
	run_toggle: bool = false,
	reset: bool = false,
	deadman: bool = false,
	timestamp_ns: int = 0
) -> bool:
	var sample_time := timestamp_ns if timestamp_ns > 0 else Time.get_ticks_usec() * 1000
	return _send(IsaacTeleopPacketCodec.KIND_CONTROL, sample_time,
		IsaacTeleopPacketCodec.encode_control(kill, run_toggle, reset, deadman))


func send_anchor(transform: Transform3D, valid: bool = true, timestamp_ns: int = 0) -> bool:
	var sample_time := timestamp_ns if timestamp_ns > 0 else Time.get_ticks_usec() * 1000
	return _send(IsaacTeleopPacketCodec.KIND_ANCHOR, sample_time,
		IsaacTeleopPacketCodec.encode_pose(transform, valid))


func _send_head(frame: SensorFrame) -> bool:
	if frame.source_id != "head" and not frame.source_id.is_empty():
		_dropped_invalid += 1
		return false
	var transform: Transform3D = frame.payload.get("transform", Transform3D.IDENTITY)
	var valid := frame.valid and bool(frame.payload.get("tracking_valid", frame.valid))
	return _send(IsaacTeleopPacketCodec.KIND_HEAD, frame.timestamp_ns,
		IsaacTeleopPacketCodec.encode_pose(transform, valid))


func _update_controller_pose(frame: SensorFrame) -> bool:
	var side := _controller_side(frame.source_id)
	if side.is_empty():
		_dropped_invalid += 1
		return false
	var state := _controller_state(side)
	var payload := frame.payload

	# A future sampler may supply both poses in one frame.  The current
	# Operator ControllerFrame supplies only `transform` (grip); aim remains
	# explicitly invalid instead of being forged from the grip pose.
	if payload.get("grip_transform") is Transform3D:
		state["grip_transform"] = payload["grip_transform"]
		state["grip_valid"] = frame.valid and bool(payload.get("grip_tracking_valid", true))
	if payload.get("aim_transform") is Transform3D:
		state["aim_transform"] = payload["aim_transform"]
		state["aim_valid"] = frame.valid and bool(payload.get("aim_tracking_valid", true))
	var pose_role := String(payload.get("pose_role", "grip")).to_lower()
	if payload.get("transform") is Transform3D:
		if pose_role == "aim" or frame.source_id.to_lower().contains("aim"):
			state["aim_transform"] = payload["transform"]
			state["aim_valid"] = frame.valid and bool(payload.get("tracking_valid", frame.valid))
		else:
			state["grip_transform"] = payload["transform"]
			state["grip_valid"] = frame.valid and bool(payload.get("tracking_valid", frame.valid))
	_controllers[side] = state
	return _send_controller(side, frame.timestamp_ns)


func _update_controller_input(frame: SensorFrame) -> bool:
	var side := _controller_side(frame.source_id)
	if side.is_empty():
		_dropped_invalid += 1
		return false
	var state := _controller_state(side)
	var pressed_mask := int(frame.payload.get("pressed_mask", 0))
	var primary_mask := INPUT_X_CLICK if side == "left" else INPUT_A_CLICK
	var secondary_mask := INPUT_Y_CLICK if side == "left" else INPUT_B_CLICK
	state["input"] = {
		"primary_pressed": (pressed_mask & primary_mask) != 0,
		"secondary_pressed": (pressed_mask & secondary_mask) != 0,
		"thumb_click": (pressed_mask & INPUT_THUMBSTICK_CLICK) != 0,
		"menu_pressed": (pressed_mask & INPUT_MENU_CLICK) != 0,
		"trigger": float(frame.payload.get("trigger_value", 0.0)),
		"grip": float(frame.payload.get("grip_value", 0.0)),
		"thumbstick": frame.payload.get("thumbstick", Vector2.ZERO),
	}
	_controllers[side] = state
	return _send_controller(side, frame.timestamp_ns)


func _send_controller(side: String, timestamp_ns: int) -> bool:
	var state := _controller_state(side)
	var payload := IsaacTeleopPacketCodec.encode_controller(
		state.get("grip_transform", Transform3D.IDENTITY),
		bool(state.get("grip_valid", false)),
		state.get("aim_transform", Transform3D.IDENTITY),
		bool(state.get("aim_valid", false)),
		state.get("input", {}))
	var kind := IsaacTeleopPacketCodec.KIND_LEFT_CONTROLLER \
		if side == "left" else IsaacTeleopPacketCodec.KIND_RIGHT_CONTROLLER
	return _send(kind, timestamp_ns, payload)


func _send_hand(frame: SensorFrame) -> bool:
	var hand := String(frame.payload.get("hand", frame.source_id)).to_lower()
	var kind := ""
	if hand.begins_with("left"):
		kind = IsaacTeleopPacketCodec.KIND_LEFT_HAND
	elif hand.begins_with("right"):
		kind = IsaacTeleopPacketCodec.KIND_RIGHT_HAND
	else:
		_dropped_invalid += 1
		return false
	var joints: Array = frame.payload.get("joints", [])
	return _send(kind, frame.timestamp_ns,
		IsaacTeleopPacketCodec.encode_joints(joints, 26, frame.valid))


func _send_body(frame: SensorFrame) -> bool:
	var joints: Array = frame.payload.get("joints", [])
	var runtime := String(frame.payload.get("runtime", "")).to_lower()
	var mapped := IsaacTeleopBodyMapper.to_pico24(joints, runtime, frame.valid)
	if not bool(mapped.get("ok", false)):
		_dropped_unmappable_body += 1
		return false
	if String(mapped.get("mapping", "")) == "godot87_to_pico24":
		_mapped_meta_body_frames += 1
		_mapped_meta_body_joints += int(mapped.get("mapped_joint_count", 0))
		_mapped_meta_valid_joints += int(mapped.get("valid_joint_count", 0))
	var mapped_joints: Array = mapped.get("joints", [])
	return _send(IsaacTeleopPacketCodec.KIND_BODY, frame.timestamp_ns,
		IsaacTeleopPacketCodec.encode_joints(mapped_joints, 24, frame.valid))


func _send(kind: String, timestamp_ns: int, payload: PackedByteArray) -> bool:
	if not is_sending():
		return false
	var sequence := int(_sequences.get(kind, 0)) + 1
	var packet := IsaacTeleopPacketCodec.encode_packet(
		kind, timestamp_ns, sequence, _session_token, _descriptor_version, payload)
	if packet.is_empty():
		_send_errors += 1
		return false
	var error := _udp.put_packet(packet)
	if error != OK:
		_send_errors += 1
		return false
	_sequences[kind] = sequence
	_sent_packets += 1
	_sent_bytes += packet.size()
	_last_sent_timestamp_ns = timestamp_ns
	return true


func _controller_side(source_id: String) -> String:
	var source := source_id.to_lower()
	if source.begins_with("left"):
		return "left"
	if source.begins_with("right"):
		return "right"
	return ""


func _controller_state(side: String) -> Dictionary:
	return _controllers.get(side, {
		"grip_transform": Transform3D.IDENTITY,
		"grip_valid": false,
		"aim_transform": Transform3D.IDENTITY,
		"aim_valid": false,
		"input": {},
	})


func policy() -> Dictionary:
	return {
		"ordering": "per_channel_sequence",
		"durability": "none",
		"drop_policy": "latest_only",
		"transport": "udp",
		"default_port": DEFAULT_UDP_PORT,
	}


func health() -> Dictionary:
	return {
		"active": is_sending(),
		"host": _host,
		"port": _port,
		"descriptor_version": _descriptor_version,
		"sent_packets": _sent_packets,
		"sent_bytes": _sent_bytes,
		"send_errors": _send_errors,
		"dropped_invalid": _dropped_invalid,
		"dropped_unmappable_body": _dropped_unmappable_body,
		# Compatibility alias for existing health consumers.
		"dropped_unsupported_body": _dropped_unmappable_body,
		"mapped_meta_body_frames": _mapped_meta_body_frames,
		"mapped_meta_body_joints": _mapped_meta_body_joints,
		"mapped_meta_valid_joints": _mapped_meta_valid_joints,
		"last_sent_timestamp_ns": _last_sent_timestamp_ns,
		"channel_sequences": _sequences.duplicate(),
	}
