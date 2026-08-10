class_name MemWorldClient
extends Node
## Full-duplex transport for live MemWorld pose conditioning.

signal connected_to_server(endpoint: String)
signal disconnected_from_server()
signal connection_failed(reason: String)
signal image_received(frame_id: int, capture_time_ns: int, jpeg: PackedByteArray)

const STALE_IMAGE_NS := 250_000_000
const MAX_IMAGE_BYTES := 8 * 1024 * 1024
const WEBSOCKET_INBOUND_BUFFER_BYTES := 16 * 1024 * 1024
const HEADER_SIZE := 32
const MAGIC := "PINF"
const TARGET_POSE_HZ := 20.0
const POSE_INTERVAL_S := 1.0 / TARGET_POSE_HZ
const MAX_OUTBOUND_BUFFER_BYTES := 256 * 1024

var _socket := WebSocketPeer.new()
var _url := ""
var _token := ""
var _calibration: Dictionary = {}
var _state: int = WebSocketPeer.STATE_CLOSED
var _frame_id := 0
var _last_sent_time_ns := 0
var _reconnect_after_s := 0.0
var _want_connection := false
var _tracking: TrackingProvider
var _pose_elapsed_s := 0.0


func set_calibration(calibration: Dictionary) -> void:
	_calibration = calibration.duplicate(true)


func configure_from_qr(payload: String) -> bool:
	if not bool(_calibration.get("ok", false)):
		connection_failed.emit("Camera calibration is unavailable; check camera permission/plugin")
		return false
	var parsed: Variant = JSON.parse_string(payload)
	if typeof(parsed) != TYPE_DICTIONARY:
		connection_failed.emit("QR code must contain JSON")
		return false
	var config := parsed as Dictionary
	var url := str(config.get("url", "")).strip_edges()
	if str(config.get("mode", "")) not in ["memWorld", "memworld", "mem_world"]:
		connection_failed.emit("QR code is not a memWorld endpoint")
		return false
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		connection_failed.emit("QR code does not contain a WebSocket URL")
		return false
	_url = url
	_token = str(config.get("token", ""))
	_want_connection = true
	_connect()
	return true


func set_tracking_provider(provider: TrackingProvider) -> void:
	_tracking = provider


func disconnect_from_server() -> void:
	_want_connection = false
	_socket.close()
	_state = WebSocketPeer.STATE_CLOSED


func _process(delta: float) -> void:
	_socket.poll()
	var next_state := _socket.get_ready_state()
	if next_state != _state:
		_on_state_changed(next_state)
		_state = next_state
	if _state == WebSocketPeer.STATE_OPEN:
		_drain_packets()
		_pose_elapsed_s += delta
		if _pose_elapsed_s >= POSE_INTERVAL_S:
			_pose_elapsed_s = fmod(_pose_elapsed_s, POSE_INTERVAL_S)
			_send_pose()
	elif _want_connection and _state == WebSocketPeer.STATE_CLOSED:
		_reconnect_after_s -= delta
		if _reconnect_after_s <= 0.0:
			_connect()


func _connect() -> void:
	if _url.is_empty():
		return
	_socket = WebSocketPeer.new()
	_socket.inbound_buffer_size = WEBSOCKET_INBOUND_BUFFER_BYTES
	var error := _socket.connect_to_url(_url)
	if error != OK:
		connection_failed.emit("WebSocket connect failed: %d" % error)
		_reconnect_after_s = 1.0
		return
	_state = _socket.get_ready_state()


func _on_state_changed(next_state: int) -> void:
	if next_state == WebSocketPeer.STATE_OPEN:
		_pose_elapsed_s = POSE_INTERVAL_S
		_socket.send_text(JSON.stringify({
			"type": "hello",
			"protocol": "operator.memworld.v1",
			"token": _token,
			"calibration": _calibration,
		}))
		connected_to_server.emit(_url)
	elif _state == WebSocketPeer.STATE_OPEN and next_state == WebSocketPeer.STATE_CLOSED:
		disconnected_from_server.emit()
		_reconnect_after_s = 1.0
	elif next_state == WebSocketPeer.STATE_CLOSED and _want_connection:
		connection_failed.emit("Unable to establish the MemWorld WebSocket connection")


func _send_pose() -> void:
	if _tracking == null:
		return
	if _socket.get_current_outbound_buffered_amount() > MAX_OUTBOUND_BUFFER_BYTES:
		return
	_frame_id += 1
	_last_sent_time_ns = Time.get_ticks_usec() * 1000
	var error := _socket.send_text(JSON.stringify({
		"type": "pose",
		"frame_id": _frame_id,
		"capture_time_ns": _last_sent_time_ns,
		"head": _format_pose(_tracking.get_head_pose()),
		"left": _format_hand(0),
		"right": _format_hand(1),
	}))
	if error != OK:
		connection_failed.emit("WebSocket pose send failed: %d" % error)


func _format_hand(hand: int) -> Dictionary:
	var joints := _tracking.get_hand_joints(hand)
	var wrist := joints[1] if joints.size() > 1 else {}
	var packed_joints: Array = []
	for joint in joints:
		packed_joints.append(_format_pose(joint))
	return {
		"tracking": _tracking.is_optical_hand_tracking_active(hand),
		"wrist": _format_pose(wrist),
		"joints": packed_joints,
	}


func _format_pose(value: Dictionary) -> Dictionary:
	if not bool(value.get("tracked", false)) or not value.has("position") or not value.has("rotation"):
		return {"tracked": false}
	var p: Vector3 = value["position"]
	var q: Quaternion = value["rotation"]
	return {
		"tracked": true,
		"position": [p.x, p.y, p.z],
		"rotation": [q.x, q.y, q.z, q.w],
		"radius_m": value.get("radius", 0.0),
	}


func _drain_packets() -> void:
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		if _socket.was_string_packet():
			continue
		_parse_image(packet)


func _parse_image(packet: PackedByteArray) -> void:
	if packet.size() < HEADER_SIZE or packet.size() > HEADER_SIZE + MAX_IMAGE_BYTES:
		return
	if packet.slice(0, 4).get_string_from_ascii() != MAGIC or packet[4] != 1:
		return
	var frame_id := _be_u64(packet, 8)
	var capture_time_ns := _be_u64(packet, 16)
	var jpeg_size := _be_u32(packet, 28)
	if jpeg_size <= 0 or packet.size() != HEADER_SIZE + jpeg_size:
		return
	if _last_sent_time_ns - capture_time_ns > STALE_IMAGE_NS:
		return
	image_received.emit(frame_id, capture_time_ns, packet.slice(HEADER_SIZE))


func _be_u32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]


func _be_u64(bytes: PackedByteArray, offset: int) -> int:
	var value := 0
	for index in range(8):
		value = (value << 8) | bytes[offset + index]
	return value
