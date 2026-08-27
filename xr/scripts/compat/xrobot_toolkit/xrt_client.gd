class_name XrtClient
extends Node
## Minimal TCP transport for the XRoboToolkit-compatible wire protocol.
## It intentionally does not share TcpHandler/XRoboProtocol state: both frame
## formats can target the same port but cannot coexist on one TCP connection.

const XrtProtocolScript = preload("res://scripts/compat/xrobot_toolkit/xrt_protocol.gd")

signal connected
signal disconnected(reason: String)
signal failed(reason: String)
signal packet_received(command: int, payload: PackedByteArray, timestamp_ms: int)

enum State {
	IDLE,
	CONNECTING,
	CONNECTED,
	RECONNECT_WAIT,
}

const DEFAULT_CONNECT_TIMEOUT_SEC := 10.0
const DEFAULT_RECONNECT_DELAY_SEC := 2.0
const MAX_DRAIN_BYTES_PER_TICK := 256 * 1024
## The largest frame the wire format can legally carry. A desynced length field
## otherwise grows the receive buffer without bound while every unpack attempt
## reports INCOMPLETE.
const MAX_RECEIVE_BUFFER_SIZE := (
	XrtProtocolScript.FRAME_OVERHEAD_SIZE + XrtProtocolScript.MAX_PAYLOAD_SIZE
)
const BAD_STATUS_TOLERANCE := 5

var connect_timeout_sec := DEFAULT_CONNECT_TIMEOUT_SEC
var reconnect_delay_sec := DEFAULT_RECONNECT_DELAY_SEC

var _tcp := StreamPeerTCP.new()
var _state: State = State.IDLE
var _host := ""
var _port := 0
var _connect_elapsed := 0.0
var _reconnect_elapsed := 0.0
var _allow_reconnect := false
var _bad_status_ticks := 0
var _receive_buffer := PackedByteArray()


func connect_to_server(host: String, port: int) -> void:
	var normalized_host := host.strip_edges()
	if normalized_host.is_empty() or port <= 0 or port > 65535:
		failed.emit("Invalid XRoboToolkit endpoint")
		return
	_host = normalized_host
	_port = port
	_allow_reconnect = true
	_begin_connect()


func disconnect_from_server() -> void:
	_allow_reconnect = false
	var was_active := _state != State.IDLE
	_tcp.disconnect_from_host()
	_tcp = StreamPeerTCP.new()
	_state = State.IDLE
	_connect_elapsed = 0.0
	_reconnect_elapsed = 0.0
	_bad_status_ticks = 0
	_receive_buffer.clear()
	if was_active:
		disconnected.emit("stopped")


func is_connected_to_server() -> bool:
	return _state == State.CONNECTED


func get_host() -> String:
	return _host


func get_port() -> int:
	return _port


## Never blocks the render thread: the sender is latest-only, so a socket that
## cannot take the whole frame drops it. A short write has already cut the frame
## in half on the wire, and no resync is worth feeding a receiver half a pose, so
## the connection is reset instead of buffering the remainder.
func send_packet(packet: PackedByteArray) -> Error:
	if _state != State.CONNECTED:
		return ERR_CONNECTION_ERROR
	var result := _tcp.put_partial_data(packet)
	var error := int(result[0])
	if error != OK:
		_handle_connection_loss("XRoboToolkit send failed: error %d" % error)
		return ERR_CONNECTION_ERROR
	if int(result[1]) != packet.size():
		_handle_connection_loss("XRoboToolkit send stalled: dropped a partial frame")
		return ERR_BUSY
	return OK


func _process(delta: float) -> void:
	match _state:
		State.CONNECTING:
			_process_connecting(delta)
		State.CONNECTED:
			_process_connected()
		State.RECONNECT_WAIT:
			_reconnect_elapsed += delta
			if _reconnect_elapsed >= reconnect_delay_sec:
				_begin_connect()
		State.IDLE:
			pass


func _begin_connect() -> void:
	_tcp.disconnect_from_host()
	_tcp = StreamPeerTCP.new()
	_connect_elapsed = 0.0
	_reconnect_elapsed = 0.0
	_receive_buffer.clear()
	var error := _tcp.connect_to_host(_host, _port)
	if error != OK:
		_handle_connect_failure("Failed to initiate XRoboToolkit connection: error %d" % error)
		return
	_state = State.CONNECTING


func _process_connecting(delta: float) -> void:
	_tcp.poll()
	match _tcp.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			_tcp.set_no_delay(true)
			_state = State.CONNECTED
			_connect_elapsed = 0.0
			_bad_status_ticks = 0
			connected.emit()
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			_handle_connect_failure("XRoboToolkit connection failed")
		StreamPeerTCP.STATUS_CONNECTING:
			_connect_elapsed += delta
			if _connect_elapsed >= connect_timeout_sec:
				_handle_connect_failure("XRoboToolkit connection timed out")


func _process_connected() -> void:
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_bad_status_ticks += 1
		if _bad_status_ticks <= BAD_STATUS_TOLERANCE:
			return
		_handle_connection_loss("XRoboToolkit connection closed")
		return
	_bad_status_ticks = 0
	var remaining := mini(_tcp.get_available_bytes(), MAX_DRAIN_BYTES_PER_TICK)
	while remaining > 0:
		var buffer_room := MAX_RECEIVE_BUFFER_SIZE - _receive_buffer.size()
		if buffer_room <= 0:
			_handle_connection_loss("XRoboToolkit receive buffer overflow")
			return
		var chunk_size := mini(remaining, mini(buffer_room, 65536))
		var result := _tcp.get_partial_data(chunk_size)
		var error := int(result[0])
		var data: PackedByteArray = result[1]
		if error != OK and error != ERR_BUSY:
			_handle_connection_loss("XRoboToolkit receive failed: error %d" % error)
			return
		if data.is_empty():
			break
		_receive_buffer.append_array(data)
		remaining -= data.size()
	_drain_receive_buffer()


func _drain_receive_buffer() -> void:
	while not _receive_buffer.is_empty():
		var frame: Dictionary = XrtProtocolScript.unpack_server_frame(_receive_buffer)
		var status := int(frame.get("status", XrtProtocolScript.UNPACK_INCOMPLETE))
		if status == XrtProtocolScript.UNPACK_INCOMPLETE:
			return
		var consumed := clampi(int(frame.get("consumed", 0)), 0, _receive_buffer.size())
		if consumed <= 0:
			return
		_receive_buffer = _receive_buffer.slice(consumed)
		if status != XrtProtocolScript.UNPACK_OK:
			continue
		var command := int(frame.get("command", -1))
		var payload: PackedByteArray = frame.get("payload", PackedByteArray())
		var timestamp_ms := int(frame.get("timestamp_ms", 0))
		packet_received.emit(command, payload, timestamp_ms)
		if XrtProtocolScript.is_time_test_request(command, payload):
			send_packet(XrtProtocolScript.pack_text(XrtProtocolScript.CMD_TRACKING, "timeTest"))


func _handle_connect_failure(reason: String) -> void:
	_tcp.disconnect_from_host()
	_schedule_reconnect()
	failed.emit(reason)


func _handle_connection_loss(reason: String) -> void:
	_tcp.disconnect_from_host()
	_schedule_reconnect()
	disconnected.emit(reason)


func _schedule_reconnect() -> void:
	_connect_elapsed = 0.0
	_reconnect_elapsed = 0.0
	_bad_status_ticks = 0
	_receive_buffer.clear()
	_state = State.RECONNECT_WAIT if _allow_reconnect else State.IDLE
