class_name XrtVideoSession
extends Node
## PICO-side XRoboToolkit FPV session.
##
## This transport is intentionally independent from XrtClient. It first opens
## a local video listener, then sends OPEN_CAMERA over the PC command socket so
## the PC can connect back and stream length-prefixed Annex-B H.264 access units.

const XrtCameraProtocolScript = preload(
	"res://scripts/compat/xrobot_toolkit/xrt_camera_protocol.gd"
)
const VideoLatencyTracker = preload("res://addons/live_video/live_video_latency.gd")

signal connected
signal disconnected(reason: String)
signal failed(reason: String)
signal video_frame_received(packet: Dictionary)

enum State {
	IDLE,
	CONNECTING_COMMAND,
	WAITING_VIDEO,
	STREAMING,
	ERROR,
}

const DEFAULT_COMMAND_PORT := 13579
const FIRST_VIDEO_PORT := 12346
const LAST_VIDEO_PORT := 12353
const DEFAULT_CONNECT_TIMEOUT_SEC := 10.0
const DEFAULT_VIDEO_TIMEOUT_SEC := 15.0
const MAX_DRAIN_BYTES_PER_TICK := 2 * 1024 * 1024
const MAX_FRAMES_PER_TICK := 64
const MAX_RECEIVE_BUFFER_SIZE := XrtCameraProtocolScript.MAX_VIDEO_ACCESS_UNIT_SIZE + 4
const BAD_STATUS_TOLERANCE := 5

var connect_timeout_sec := DEFAULT_CONNECT_TIMEOUT_SEC
var video_timeout_sec := DEFAULT_VIDEO_TIMEOUT_SEC

var _state: State = State.IDLE
var _last_error := ""
var _pc_host := ""
var _command_port := DEFAULT_COMMAND_PORT
var _local_ip := ""
var _listen_port := 0
var _camera_options := {}
var _connect_elapsed := 0.0
var _video_wait_elapsed := 0.0
var _command_bad_status_ticks := 0
var _video_bad_status_ticks := 0
var _open_camera_sent := false
var _frame_id := 0

var _video_server := TCPServer.new()
var _command_peer := StreamPeerTCP.new()
var _video_peer: StreamPeerTCP
var _video_buffer := PackedByteArray()


func start(options: Dictionary) -> void:
	_close_transports(true)
	_set_state(State.IDLE)
	_last_error = ""

	_pc_host = str(options.get("host", "")).strip_edges()
	_command_port = int(options.get("command_port", DEFAULT_COMMAND_PORT))
	_camera_options = options.duplicate(true)
	if _pc_host.is_empty() or _command_port <= 0 or _command_port > 65535:
		_fail("Invalid XRoboToolkit camera command endpoint")
		return
	if not _validate_camera_options(_camera_options):
		_fail("Invalid XRoboToolkit camera options")
		return

	_local_ip = select_local_ipv4(_pc_host, _get_local_addresses())
	if _local_ip.is_empty():
		_fail("No usable local IPv4 address for XRoboToolkit video")
		return

	var listen_error := _start_video_listener(int(options.get("listen_port", FIRST_VIDEO_PORT)))
	if listen_error != OK:
		_fail(
			"Unable to listen on XRoboToolkit video ports %d..%d" % [
				FIRST_VIDEO_PORT, LAST_VIDEO_PORT,
			]
		)
		return

	_command_peer = StreamPeerTCP.new()
	var connect_error := _command_peer.connect_to_host(_pc_host, _command_port)
	if connect_error != OK:
		_fail(
			"Failed to initiate XRoboToolkit camera command connection: error %d" % connect_error
		)
		return
	_connect_elapsed = 0.0
	_video_wait_elapsed = 0.0
	_command_bad_status_ticks = 0
	_video_bad_status_ticks = 0
	_open_camera_sent = false
	_frame_id = 0
	_video_buffer.clear()
	_set_state(State.CONNECTING_COMMAND)


func stop() -> void:
	var was_active := _state != State.IDLE
	_close_transports(true)
	_last_error = ""
	_set_state(State.IDLE)
	if was_active:
		disconnected.emit("stopped")


func is_active() -> bool:
	return _state == State.CONNECTING_COMMAND \
		or _state == State.WAITING_VIDEO \
		or _state == State.STREAMING


func get_transport_loss_text() -> String:
	return "N/A"


func get_state() -> State:
	return _state


func get_status() -> Dictionary:
	return {
		"state": _state,
		"state_name": _state_name(_state),
		"pc_host": _pc_host,
		"command_port": _command_port,
		"local_ip": _local_ip,
		"listen_port": _listen_port,
		"streaming": _state == State.STREAMING,
		"last_error": _last_error,
	}


func get_last_error() -> String:
	return _last_error


func get_listen_port() -> int:
	return _listen_port


func get_local_ip() -> String:
	return _local_ip


func is_streaming() -> bool:
	return _state == State.STREAMING


func _process(delta: float) -> void:
	if _state == State.IDLE or _state == State.ERROR:
		return
	_process_command_peer(delta)
	if _state == State.ERROR:
		return
	_process_video_listener(delta)
	if _state == State.STREAMING:
		_process_video_peer()


func _process_command_peer(delta: float) -> void:
	_command_peer.poll()
	var status := _command_peer.get_status()
	if _state == State.CONNECTING_COMMAND:
		match status:
			StreamPeerTCP.STATUS_CONNECTED:
				_command_peer.set_no_delay(true)
				_connect_elapsed = 0.0
				_command_bad_status_ticks = 0
				_send_open_camera()
			StreamPeerTCP.STATUS_CONNECTING:
				_connect_elapsed += delta
				if _connect_elapsed >= connect_timeout_sec:
					_fail("XRoboToolkit camera command connection timed out")
			StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
				_fail("XRoboToolkit camera command connection failed")
		return

	if status == StreamPeerTCP.STATUS_CONNECTED:
		_command_bad_status_ticks = 0
		return
	_command_bad_status_ticks += 1
	if _command_bad_status_ticks > BAD_STATUS_TOLERANCE:
		_disconnect("XRoboToolkit camera command connection closed")


func _process_video_listener(delta: float) -> void:
	if _state != State.WAITING_VIDEO:
		return
	if _video_server.is_connection_available():
		_video_peer = _video_server.take_connection()
		if _video_peer == null:
			_fail("XRoboToolkit video listener returned no connection")
			return
		_video_peer.set_no_delay(true)
		_video_server.stop()
		_video_wait_elapsed = 0.0
		_video_bad_status_ticks = 0
		_set_state(State.STREAMING)
		connected.emit()
		return
	_video_wait_elapsed += delta
	if _video_wait_elapsed >= video_timeout_sec:
		_fail("Timed out waiting for XRoboToolkit reverse video connection")


func _process_video_peer() -> void:
	if _video_peer == null:
		_disconnect("XRoboToolkit video connection is unavailable")
		return
	_video_peer.poll()
	if _video_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_video_bad_status_ticks += 1
		if _video_bad_status_ticks > BAD_STATUS_TOLERANCE:
			_disconnect("XRoboToolkit video connection closed")
		return
	_video_bad_status_ticks = 0

	var remaining := mini(_video_peer.get_available_bytes(), MAX_DRAIN_BYTES_PER_TICK)
	while remaining > 0:
		var buffer_room := MAX_RECEIVE_BUFFER_SIZE - _video_buffer.size()
		if buffer_room <= 0:
			_fail("XRoboToolkit video receive buffer overflow")
			return
		var chunk_size := mini(remaining, mini(buffer_room, 64 * 1024))
		var read_result := _video_peer.get_partial_data(chunk_size)
		var read_error := int(read_result[0])
		var data: PackedByteArray = read_result[1]
		if read_error != OK and read_error != ERR_BUSY:
			_fail("XRoboToolkit video receive failed: error %d" % read_error)
			return
		if data.is_empty():
			break
		_video_buffer.append_array(data)
		remaining -= data.size()
		if not _parse_video_buffer():
			return


func _parse_video_buffer() -> bool:
	var parsed_frames := 0
	while parsed_frames < MAX_FRAMES_PER_TICK:
		var decoded: Dictionary = XrtCameraProtocolScript.decode_video_access_unit(_video_buffer)
		if decoded.is_empty():
			return true
		if decoded.has("error"):
			_fail(str(decoded["error"]))
			return false

		var consumed := int(decoded.get("bytes_consumed", 0))
		if consumed <= 0 or consumed > _video_buffer.size():
			_fail("XRoboToolkit video parser consumed an invalid length")
			return false
		_video_buffer = _video_buffer.slice(consumed)
		var access_unit: PackedByteArray = decoded.get("access_unit", PackedByteArray())
		video_frame_received.emit({
			"frame_id": _frame_id,
			"nal_index": 0,
			"nal_count": 1,
			"nal_data": access_unit,
			"receive_ns": VideoLatencyTracker.now_ns(),
			"source": "xrobot_toolkit_fpv",
			"transport_loss_available": false,
		})
		_frame_id += 1
		parsed_frames += 1
	return true


func _send_open_camera() -> void:
	var options := _camera_options.duplicate(true)
	options["listen_port"] = _listen_port
	options["pico_ip"] = _local_ip
	var frame: PackedByteArray = XrtCameraProtocolScript.encode_open_camera(options)
	if frame.is_empty():
		_fail("Failed to encode XRoboToolkit OPEN_CAMERA")
		return
	var send_result := _command_peer.put_partial_data(frame)
	var send_error := int(send_result[0])
	if send_error != OK:
		_fail("Failed to send XRoboToolkit OPEN_CAMERA: error %d" % send_error)
		return
	if int(send_result[1]) != frame.size():
		_fail("XRoboToolkit OPEN_CAMERA was only partially written")
		return
	_open_camera_sent = true
	_video_wait_elapsed = 0.0
	_set_state(State.WAITING_VIDEO)


## Best-effort teardown notice. It runs on the render thread during shutdown, so
## a stalled PC socket must never block: an unwritten CLOSE_CAMERA is dropped and
## the PC observes the closed connection instead.
func _send_close_camera() -> void:
	if not _open_camera_sent:
		return
	_command_peer.poll()
	if _command_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var frame: PackedByteArray = XrtCameraProtocolScript.encode_close_camera()
		if not frame.is_empty():
			_command_peer.put_partial_data(frame)
	_open_camera_sent = false


func _start_video_listener(preferred_port: int) -> Error:
	_video_server.stop()
	_video_server = TCPServer.new()
	_listen_port = 0
	var last_error: Error = ERR_CANT_CREATE
	var ports: Array[int] = []
	ports.append(preferred_port)
	for port in range(FIRST_VIDEO_PORT, LAST_VIDEO_PORT + 1):
		if port != preferred_port:
			ports.append(port)
	for port in ports:
		last_error = _video_server.listen(port)
		if last_error == OK:
			_listen_port = port
			return OK
	return last_error


func _close_transports(send_close: bool) -> void:
	if send_close:
		_send_close_camera()
	if _video_peer != null:
		_video_peer.disconnect_from_host()
		_video_peer = null
	_video_server.stop()
	_command_peer.disconnect_from_host()
	_command_peer = StreamPeerTCP.new()
	_video_buffer.clear()
	_connect_elapsed = 0.0
	_video_wait_elapsed = 0.0
	_command_bad_status_ticks = 0
	_video_bad_status_ticks = 0
	_open_camera_sent = false
	_listen_port = 0


func _fail(message: String) -> void:
	_last_error = message
	_close_transports(true)
	_set_state(State.ERROR)
	failed.emit(message)


func _disconnect(reason: String) -> void:
	_last_error = ""
	_close_transports(false)
	_set_state(State.IDLE)
	disconnected.emit(reason)


func _set_state(next_state: State) -> void:
	if _state == next_state:
		return
	_state = next_state


func _validate_camera_options(options: Dictionary) -> bool:
	var width := int(options.get("width", 1280))
	var height := int(options.get("height", 720))
	var fps := int(options.get("fps", 30))
	var bitrate := int(options.get("bitrate", 6_000_000))
	var enable_mv_hevc := int(options.get("enable_mv_hevc", 0))
	var render_mode := int(options.get("render_mode", 2))
	var preferred_port := int(options.get("listen_port", FIRST_VIDEO_PORT))
	var camera_name := str(options.get("camera_name", "UNITREE_HEAD"))
	return (
		width > 0
		and height > 0
		and fps > 0
		and bitrate > 0
		and (enable_mv_hevc == 0 or enable_mv_hevc == 1)
		and render_mode >= 0
		and preferred_port >= FIRST_VIDEO_PORT
		and preferred_port <= LAST_VIDEO_PORT
		and not camera_name.to_utf8_buffer().is_empty()
		and camera_name.to_utf8_buffer().size() <= 0xFF
	)


func _get_local_addresses() -> PackedStringArray:
	return IP.get_local_addresses()


static func select_local_ipv4(
		pc_host: String,
		candidates: PackedStringArray = PackedStringArray()
	) -> String:
	var addresses := candidates
	if addresses.is_empty():
		addresses = IP.get_local_addresses()
	var valid: Array[String] = []
	for candidate in addresses:
		var octets := _parse_ipv4(candidate)
		if octets.is_empty() or _is_excluded_ipv4(octets):
			continue
		valid.append(candidate)
	if valid.is_empty():
		return ""

	var pc_octets := _parse_ipv4(pc_host.strip_edges())
	if not pc_octets.is_empty():
		for candidate in valid:
			var octets := _parse_ipv4(candidate)
			if octets[0] == pc_octets[0] \
					and octets[1] == pc_octets[1] \
					and octets[2] == pc_octets[2]:
				return candidate

	for candidate in valid:
		if _is_private_ipv4(_parse_ipv4(candidate)):
			return candidate
	return valid[0]


static func _parse_ipv4(address: String) -> Array[int]:
	var parts := address.split(".")
	if parts.size() != 4:
		return []
	var octets: Array[int] = []
	for part in parts:
		if part.is_empty() or not part.is_valid_int():
			return []
		var value := int(part)
		if value < 0 or value > 255:
			return []
		octets.append(value)
	return octets


static func _is_excluded_ipv4(octets: Array[int]) -> bool:
	return (
		octets[0] == 0
		or octets[0] == 127
		or (octets[0] == 169 and octets[1] == 254)
		or octets[0] >= 224
	)


static func _is_private_ipv4(octets: Array[int]) -> bool:
	return (
		octets[0] == 10
		or (octets[0] == 172 and octets[1] >= 16 and octets[1] <= 31)
		or (octets[0] == 192 and octets[1] == 168)
	)


static func _state_name(value: State) -> String:
	match value:
		State.IDLE:
			return "idle"
		State.CONNECTING_COMMAND:
			return "connecting_command"
		State.WAITING_VIDEO:
			return "waiting_video"
		State.STREAMING:
			return "streaming"
		State.ERROR:
			return "error"
	return "unknown"
