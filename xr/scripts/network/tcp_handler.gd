class_name TcpHandler
extends Node
## TCP client for connecting to the robot server.
## Handles connection lifecycle and frame-level send/receive using XRoboProtocol.
##
## [issue 005 / D-4] Inline drain-loop is the final design. Worker
## threads were attempted (see [opt 6 reverted] history below) but
## Godot 4's StreamPeerTCP isn't reliably thread-safe on swan: the
## very first put_data after the worker started polling returned
## err=1 (FAILED) ~half the time, killing the connection before any
## frames flowed. We accept the ~3–5 ms worst-case scheduling latency
## of inline polling — well under the 100 ms motion-to-photons budget
## — in exchange for a connection that actually stays up.
##
## Trip-wire to revisit: a Godot release that fixes the threading
## bug, OR profiling showing process-tick latency dominating over
## decode/render. The API surface here (signal-driven, no shared
## state) was deliberately kept thread-friendly so re-introducing a
## worker is mechanical when that day comes. Keep this section in
## sync with `claw/issues/005-decisions.md` D-4.
##
## Historical note: [opt 7] introduced the drain-loop after measuring
## a single read per process tick (~11 ms at 90 fps) was adding 30+ ms
## of pure scheduling latency for NALs larger than READ_CHUNK_SIZE.

const XRoboProtocol = preload("res://scripts/network/protocol.gd")
const VideoLatencyTracker = preload("res://scripts/network/video_latency.gd")

signal connected_to_server()
signal disconnected_from_server()
signal connection_failed(reason: String)
signal command_received(command: String, data: PackedByteArray)
signal video_frame_received(packet: Dictionary)

enum State {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
}

enum StreamMode {
	COMMAND,
	VIDEO,
}

## Current connection state
var _state: State = State.DISCONNECTED
## TCP stream peer
var _tcp: StreamPeerTCP = StreamPeerTCP.new()
## Receive buffer for accumulating incoming data
var _recv_buffer: PackedByteArray = PackedByteArray()
## Target host/port
var _host: String = ""
var _port: int = 0
## Connection timeout in seconds
var _connect_timeout: float = 10.0
## Time elapsed since connection attempt started
var _connect_elapsed: float = 0.0
## Stream mode (command or video)
var _mode: StreamMode = StreamMode.COMMAND
## How many CONSECUTIVE process ticks the socket has reported a
## non-CONNECTED status while we believe we're connected. Some Godot 4
## builds + Pico + adb reverse return STATUS_NONE for a single tick
## right after the first put_data; tearing down on that single tick
## was killing the command channel before any data flowed. Require N
## consecutive bad ticks before we declare the socket dead.
var _bad_status_ticks: int = 0
const BAD_STATUS_TOLERANCE: int = 5

## Default cap on the in-process receive buffer. A single 1280x720
## IDR at our 4 Mbps target peaks around 1.5 MiB so 10 MiB gives ~6
## frames of headroom before we declare the producer broken and
## tear down. Operators can override per-handler via
## `set_max_recv_buffer()` (e.g. the video handler can be raised to
## 64 MiB for 4K experiments without forcing a code edit).
##
## See `claw/issues/005-decisions.md` D-5.
const DEFAULT_MAX_RECV_BUFFER := 10 * 1024 * 1024
## Read chunk size per poll
const READ_CHUNK_SIZE := 65536

## [issue 005 / item 6] Per-instance receive buffer cap. Defaults to
## DEFAULT_MAX_RECV_BUFFER but configurable by callers that know they
## need more headroom (e.g. the dedicated video stream handler).
var _max_recv_buffer: int = DEFAULT_MAX_RECV_BUFFER


## [issue 005 / item 6] Override the receive buffer cap for this
## handler. Pass a value > 0 in bytes. Reducing below the current
## buffer size will not truncate it — the cap only takes effect on
## the next read. Setting too low risks losing valid frames during
## bursts; the default (10 MiB) is sized for 720p30 at 4 Mbps with
## roughly 6 frames of slack.
func set_max_recv_buffer(bytes: int) -> void:
	if bytes <= 0:
		push_warning("[TcpHandler] ignoring non-positive max_recv_buffer: %d" % bytes)
		return
	_max_recv_buffer = bytes


## Read the configured receive buffer cap.
func get_max_recv_buffer() -> int:
	return _max_recv_buffer
## Hard cap on drain-loop iterations per process tick. Lets us drain
## several full chunks if the producer burst-sent (e.g. multi-NAL
## access unit larger than one chunk), without risking livelock if a
## buggy producer feeds us forever.
const MAX_DRAIN_PER_TICK: int = 32


func _ready() -> void:
	# Disable Nagle's algorithm. Without this small writes (e.g. our
	# 76-byte timed video header) get coalesced for up to 40 ms before
	# being sent, which adds 40 ms to the `tx=` latency for every NAL.
	# Re-applied on each successful connect (see _process_connecting)
	# because some Godot 4 builds don't honour the flag set before the
	# socket is actually open.
	_tcp.set_no_delay(true)


func _process(delta: float) -> void:
	match _state:
		State.CONNECTING:
			_process_connecting(delta)
		State.CONNECTED:
			_process_connected()
		State.DISCONNECTED:
			pass


func _process_connecting(delta: float) -> void:
	_tcp.poll()
	var status := _tcp.get_status()

	match status:
		StreamPeerTCP.STATUS_CONNECTED:
			_state = State.CONNECTED
			_recv_buffer.clear()
			# Re-apply TCP_NODELAY now that the socket is actually open.
			# In Godot 4 the pre-connect call in _ready() is best-effort.
			_tcp.set_no_delay(true)
			print("[TcpHandler] Connected to %s:%d (%s)" % [_host, _port, _mode_name()])
			connected_to_server.emit()

		StreamPeerTCP.STATUS_CONNECTING:
			_connect_elapsed += delta
			if _connect_elapsed >= _connect_timeout:
				_tcp.disconnect_from_host()
				_state = State.DISCONNECTED
				connection_failed.emit("Connection timed out")

		StreamPeerTCP.STATUS_ERROR:
			_state = State.DISCONNECTED
			connection_failed.emit("Connection error")

		StreamPeerTCP.STATUS_NONE:
			_state = State.DISCONNECTED
			connection_failed.emit("Connection reset")


func _process_connected() -> void:
	_tcp.poll()
	var status := _tcp.get_status()

	if status != StreamPeerTCP.STATUS_CONNECTED:
		_bad_status_ticks += 1
		if _bad_status_ticks <= BAD_STATUS_TOLERANCE:
			# Transient — could be Godot/Pico StreamPeerTCP weirdness
			# right after the first put_data. Stay connected.
			return
		print("[TcpHandler] %s status=%d for %d ticks, disconnecting" % [
			_mode_name(), status, _bad_status_ticks,
		])
		_state = State.DISCONNECTED
		_bad_status_ticks = 0
		_recv_buffer.clear()
		disconnected_from_server.emit()
		return
	_bad_status_ticks = 0

	# [opt 7] Drain the kernel receive buffer in a loop. With one read
	# per process tick (~11 ms at 90 fps) a single 1280x720 NAL larger
	# than READ_CHUNK_SIZE could take several ticks to fully arrive —
	# adding 30+ ms of pure scheduling latency per frame. Looping here
	# keeps `tx=` honest. We cap at MAX_DRAIN_PER_TICK iterations so a
	# pathological producer can't starve other process tasks.
	var drained_iterations: int = 0
	while drained_iterations < MAX_DRAIN_PER_TICK:
		drained_iterations += 1
		var bytes_available := _tcp.get_available_bytes()
		if bytes_available <= 0:
			break

		var to_read := mini(bytes_available, READ_CHUNK_SIZE)
		var result := _tcp.get_data(to_read)
		var error: int = result[0]
		var data: PackedByteArray = result[1]

		if error != OK:
			print("[TcpHandler] %s get_data error %d after %d iters, disconnecting" % [_mode_name(), error, drained_iterations])
			_state = State.DISCONNECTED
			_recv_buffer.clear()
			disconnected_from_server.emit()
			return

		_recv_buffer.append_array(data)

		# Prevent buffer from growing unbounded. See D-5 in
		# claw/issues/005-decisions.md for why we hard-disconnect
		# instead of dropping the head of the buffer.
		if _recv_buffer.size() > _max_recv_buffer:
			print("[TcpHandler] %s receive buffer overflow (%d > %d), disconnecting" % [
				_mode_name(), _recv_buffer.size(), _max_recv_buffer,
			])
			_recv_buffer.clear()
			_state = State.DISCONNECTED
			disconnected_from_server.emit()
			return

	# Parse all frames produced by this tick's drain in one pass.
	_parse_frames()


func _parse_frames() -> void:
	if _mode == StreamMode.VIDEO:
		_parse_video_packets()
		return

	# Try to parse as many complete command frames as possible
	var safety_counter := 0
	while _recv_buffer.size() >= 8 and safety_counter < 100:
		safety_counter += 1

		var result := XRoboProtocol.decode_command(_recv_buffer)
		if result.is_empty():
			# Not enough data yet
			break

		if result.has("error"):
			print("[TcpHandler] Protocol error: %s" % result["error"])
			_recv_buffer.clear()
			break

		var bytes_consumed: int = result["bytes_consumed"]
		var command: String = result["command"]
		var frame_data: PackedByteArray = result["data"]

		# Remove consumed bytes from buffer
		_recv_buffer = _recv_buffer.slice(bytes_consumed)

		# Dispatch
		if command == "VideoFrame":
			video_frame_received.emit({
				"legacy": true,
				"receive_ns": VideoLatencyTracker.now_ns(),
				"nal_data": frame_data,
			})
		else:
			command_received.emit(command, frame_data)


func _parse_video_packets() -> void:
	var safety_counter := 0
	while _recv_buffer.size() >= 60 and safety_counter < 100:
		safety_counter += 1

		var result := XRoboProtocol.decode_timed_video_frame(_recv_buffer)
		if result.is_empty():
			break

		if result.has("error"):
			print("[TcpHandler] Video protocol error: %s" % result["error"])
			_recv_buffer.clear()
			break

		var bytes_consumed: int = result["bytes_consumed"]
		_recv_buffer = _recv_buffer.slice(bytes_consumed)
		result["receive_ns"] = VideoLatencyTracker.now_ns()
		video_frame_received.emit(result)


## Connect to a robot at the given address.
func connect_to_robot(host: String, port: int) -> void:
	_connect(host, port, StreamMode.COMMAND)


## Connect to the dedicated video stream.
func connect_to_video_stream(host: String, port: int) -> void:
	_connect(host, port, StreamMode.VIDEO)


func _connect(host: String, port: int, mode: StreamMode) -> void:
	if _state != State.DISCONNECTED:
		disconnect_from_robot()

	_host = host
	_port = port
	_mode = mode
	_connect_elapsed = 0.0
	_recv_buffer.clear()

	var err := _tcp.connect_to_host(host, port)
	if err != OK:
		connection_failed.emit("Failed to initiate connection: error %d" % err)
		return

	_state = State.CONNECTING
	print("[TcpHandler] Connecting to %s:%d (%s)..." % [host, port, _mode_name()])


## Disconnect from the robot.
func disconnect_from_robot() -> void:
	if _state == State.DISCONNECTED:
		return

	_tcp.disconnect_from_host()
	_state = State.DISCONNECTED
	_recv_buffer.clear()
	disconnected_from_server.emit()


## Send raw bytes over TCP.
func send_raw(data: PackedByteArray) -> Error:
	if _state != State.CONNECTED:
		return ERR_CONNECTION_ERROR
	if _mode != StreamMode.COMMAND:
		return ERR_CONNECTION_ERROR

	var err := _tcp.put_data(data)
	if err != OK:
		print("[TcpHandler] Send error: %d" % err)
		_state = State.DISCONNECTED
		_recv_buffer.clear()
		disconnected_from_server.emit()
	return err


## Send a protocol command frame.
func send_command(command: String, data: PackedByteArray = PackedByteArray()) -> Error:
	var frame := XRoboProtocol.encode_command(command, data)
	return send_raw(frame)


## Check if currently connected.
func is_connected_to_robot() -> bool:
	return _state == State.CONNECTED


## Get current connection state.
func get_state() -> State:
	return _state


## Get the connected host address.
func get_host() -> String:
	return _host


## Get the connected port.
func get_port() -> int:
	return _port


func get_mode() -> StreamMode:
	return _mode


func _mode_name() -> String:
	return "video" if _mode == StreamMode.VIDEO else "command"
