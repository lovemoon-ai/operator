class_name UdpVideoHandler
extends Node
## [opt 9] UDP receiver for the video stream.
##
## Mirrors the API surface of TcpHandler (`video_frame_received` signal,
## `connect_to_video_stream`/`disconnect_from_robot`) so the teleop controller can
## swap between transports with minimal plumbing. The wire format is
## the same TimedVideoFrame layout as the TCP path, so the GDScript
## decoder (XRoboProtocol.decode_timed_video_frame) and RobotView code
## work unchanged.
##
## Caveats:
## - UDP doesn't traverse `adb reverse`; only useful over actual Wi-Fi.
## - No retransmit, no FEC. A single dropped *fragment* = the whole
##   reassembled NAL is dropped. The XR decoder will recover at the
##   next IDR (we set GOP to 0.5 s in [opt 4]). See
##   `claw/issues/005-video-transport-decode.md` for why we accept
##   that loss model — short version: tail-latency over reliability
##   is the right tradeoff for sub-100 ms teleop.
## - Server-side fan-out is unicast triggered by us sending a "Hello"
##   datagram once. We re-send every 5 s in case the server restarts.
## - [issue 005 / item 3] Large NALs (typically IDRs) arrive in
##   multiple fragments tagged with frame_id + fragment_index. We
##   reassemble in `_reassembler` keyed by frame_id+nal_index, drop
##   stale partials when a newer frame_id arrives, and emit only when
##   ALL fragments of a NAL have shown up.

const XRoboProtocol = preload("res://scripts/network/protocol.gd")
const VideoLatencyTracker = preload("res://scripts/network/video_latency.gd")

signal connected_to_server()
signal disconnected_from_server()
signal connection_failed(reason: String)
signal video_frame_received(packet: Dictionary)

const HELLO_REPEAT_SEC: float = 5.0

var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _connected: bool = false
var _host: String = ""
var _port: int = 0
var _hello_timer: Timer
var _last_packet_received_ns: int = 0

## Reassembly buffer. Key = "frame_id:nal_index", value = Dictionary:
##   {
##     "fragment_count": int,
##     "received_count": int,
##     "fragments": Array  # nullable PackedByteArrays indexed by fragment_index
##     "timed_header": PackedByteArray  # 80B, captured from any fragment
##     "nal_total_len": int
##     "started_ns": int,
##     "metadata": Dictionary  # nal_index, frame_id, timing fields, ...
##   }
##
## When `received_count == fragment_count` we concatenate `fragments`,
## emit `video_frame_received`, and drop the entry.
##
## We cap the number of in-flight reassembly entries at REASSEMBLY_MAX
## and time them out at REASSEMBLY_TTL_NS to bound memory if a fragment
## is lost forever.
var _reassembler: Dictionary = {}
const REASSEMBLY_MAX: int = 16
## Drop partial reassemblies older than this many ns. 200ms is plenty
## of slack for any reasonable Wi-Fi reordering at 30+ fps; missing a
## fragment for longer than that is essentially "the IDR is gone, wait
## for the next one".
const REASSEMBLY_TTL_NS: int = 200_000_000


func _ready() -> void:
	_hello_timer = Timer.new()
	_hello_timer.wait_time = HELLO_REPEAT_SEC
	_hello_timer.one_shot = false
	_hello_timer.autostart = false
	_hello_timer.timeout.connect(_send_hello)
	add_child(_hello_timer)


func _process(_delta: float) -> void:
	if not _connected:
		return
	# Drain all available datagrams. Each one is either:
	#   (a) a fragmented packet starting with the "NLFR" magic, or
	#   (b) a legacy single-datagram TimedVideoFrame (no fragment header).
	# We try (a) first — its parser checks the 4-byte magic and returns
	# an empty dict if it doesn't match, so the cost of the failed
	# match for legacy datagrams is just a memcmp.
	var safety := 0
	while _udp.get_available_packet_count() > 0 and safety < 256:
		safety += 1
		var bytes := _udp.get_packet()
		if bytes.is_empty():
			continue

		var frag := XRoboProtocol.decode_udp_fragment(bytes)
		if not frag.is_empty():
			if frag.has("error"):
				continue
			_handle_fragment(frag)
			continue

		# Legacy non-fragmented path (single datagram = whole NAL).
		# Kept so the headset can talk to older robot builds without
		# a flag day.
		var result := XRoboProtocol.decode_timed_video_frame(bytes)
		if result.is_empty() or result.has("error"):
			continue
		result["receive_ns"] = VideoLatencyTracker.now_ns()
		_last_packet_received_ns = result["receive_ns"]
		video_frame_received.emit(result)

	_evict_stale_reassemblies()


func _handle_fragment(frag: Dictionary) -> void:
	var key := "%d:%d" % [frag["frame_id"], frag["nal_index"]]
	var now_ns := VideoLatencyTracker.now_ns()
	var entry: Dictionary = _reassembler.get(key, {})
	if entry.is_empty():
		# Backpressure cap: if we already have too many partial NALs
		# in flight, drop the oldest one. Otherwise a lossy link can
		# accumulate dozens of half-frames and chew memory.
		if _reassembler.size() >= REASSEMBLY_MAX:
			_drop_oldest_reassembly()
		var fragments_arr: Array = []
		fragments_arr.resize(int(frag["fragment_count"]))
		entry = {
			"fragment_count": int(frag["fragment_count"]),
			"received_count": 0,
			"fragments": fragments_arr,
			"received_bytes": 0,
			"timed_header": frag["timed_header"],
			"nal_total_len": int(frag["nal_total_len"]),
			"started_ns": now_ns,
			"metadata": {
				"frame_id": frag["frame_id"],
				"nal_index": frag["nal_index"],
				"nal_count": frag["nal_count"],
				"pipeline_mode": frag["pipeline_mode"],
				"capture_start_ns": frag["capture_start_ns"],
				"capture_end_ns": frag["capture_end_ns"],
				"encode_start_ns": frag["encode_start_ns"],
				"encode_end_ns": frag["encode_end_ns"],
				"read_wait_ns": frag["read_wait_ns"],
				"parse_ns": frag["parse_ns"],
				"send_ns": frag["send_ns"],
			},
		}
		_reassembler[key] = entry

	# Tolerate fragment_count mismatch (shouldn't happen; defensive).
	if int(entry["fragment_count"]) != int(frag["fragment_count"]):
		_reassembler.erase(key)
		return

	var idx: int = frag["fragment_index"]
	var fragments: Array = entry["fragments"]
	if idx < 0 or idx >= fragments.size():
		_reassembler.erase(key)
		return
	if fragments[idx] != null:
		# Duplicate — silently ignore. Wi-Fi retransmits at the L2 layer
		# can occasionally surface as application-layer dups.
		return
	var payload: PackedByteArray = frag["fragment_payload"]
	fragments[idx] = payload
	entry["received_count"] = int(entry["received_count"]) + 1
	entry["received_bytes"] = int(entry["received_bytes"]) + payload.size()

	if int(entry["received_count"]) >= int(entry["fragment_count"]):
		_finalize_reassembly(key, entry, now_ns)


func _finalize_reassembly(key: String, entry: Dictionary, now_ns: int) -> void:
	# Reassemble: concatenate fragments in index order.
	var nal := PackedByteArray()
	nal.resize(int(entry["nal_total_len"]))
	var offset := 0
	var fragments: Array = entry["fragments"]
	for i in fragments.size():
		var f: PackedByteArray = fragments[i]
		# Copy fragment bytes into the right slot. resize+set is faster
		# than append_array because we know the total size up front.
		for j in f.size():
			nal[offset + j] = f[j]
		offset += f.size()
	if offset != int(entry["nal_total_len"]):
		# Length mismatch — usually means the sender's nal_total_len
		# was wrong or a fragment was the wrong size. Drop the frame.
		_reassembler.erase(key)
		return

	var meta: Dictionary = entry["metadata"]
	var packet := {
		"frame_id": meta["frame_id"],
		"nal_index": meta["nal_index"],
		"nal_count": meta["nal_count"],
		"pipeline_mode": meta["pipeline_mode"],
		"capture_start_ns": meta["capture_start_ns"],
		"capture_end_ns": meta["capture_end_ns"],
		"encode_start_ns": meta["encode_start_ns"],
		"encode_end_ns": meta["encode_end_ns"],
		"read_wait_ns": meta["read_wait_ns"],
		"parse_ns": meta["parse_ns"],
		"send_ns": meta["send_ns"],
		"nal_data": nal,
		"receive_ns": now_ns,
	}
	_reassembler.erase(key)
	_last_packet_received_ns = now_ns
	video_frame_received.emit(packet)


## Total reassembly drops since handler start: TTL evictions + oldest
## evictions when REASSEMBLY_MAX is hit. Surfaced via get_drop_count() so
## RobotView's HUD can show "udp drops: N" alongside the latency lines.
var _reassembly_drop_count: int = 0


func get_drop_count() -> int:
	return _reassembly_drop_count


func _evict_stale_reassemblies() -> void:
	if _reassembler.is_empty():
		return
	var now_ns := VideoLatencyTracker.now_ns()
	var to_drop: Array = []
	for key in _reassembler.keys():
		var entry: Dictionary = _reassembler[key]
		if now_ns - int(entry["started_ns"]) > REASSEMBLY_TTL_NS:
			to_drop.append(key)
	for key in to_drop:
		_reassembler.erase(key)
		_reassembly_drop_count += 1


func _drop_oldest_reassembly() -> void:
	var oldest_key: String = ""
	var oldest_ns: int = 0x7FFFFFFFFFFFFFFF
	for key in _reassembler.keys():
		var entry: Dictionary = _reassembler[key]
		if int(entry["started_ns"]) < oldest_ns:
			oldest_ns = int(entry["started_ns"])
			oldest_key = key
	if not oldest_key.is_empty():
		_reassembler.erase(oldest_key)
		_reassembly_drop_count += 1


## Bind a local UDP socket and tell the server (host:port) we want frames.
## host is informational here — the server replies to whatever address
## our Hello arrived from, so the server learns it dynamically.
func connect_to_video_stream(host: String, port: int) -> void:
	disconnect_from_robot()
	_host = host
	_port = port
	# Bind to ephemeral local port so the OS picks one we own.
	var err := _udp.bind(0)
	if err != OK:
		connection_failed.emit("UDP bind failed: %d" % err)
		return
	# Set destination so set_dest_address + put_packet works for our
	# Hello datagrams.
	var dest_err := _udp.set_dest_address(host, port)
	if dest_err != OK:
		connection_failed.emit("UDP set_dest failed: %d" % dest_err)
		_udp.close()
		return
	_connected = true
	_hello_timer.start()
	_send_hello()  # immediate, don't wait HELLO_REPEAT_SEC for the first one
	print("[UdpVideoHandler] Bound, registering with %s:%d" % [host, port])
	connected_to_server.emit()


func disconnect_from_robot() -> void:
	if not _connected:
		return
	_hello_timer.stop()
	_udp.close()
	_connected = false
	# Drop any half-assembled NALs — when we reconnect the robot will
	# start a new GOP from frame 0 and old fragment_indices would
	# never complete.
	_reassembler.clear()
	disconnected_from_server.emit()


func is_connected_to_robot() -> bool:
	return _connected


func get_host() -> String:
	return _host


func get_port() -> int:
	return _port


func _send_hello() -> void:
	if not _connected:
		return
	var _err: int = int(_udp.put_packet("Hello".to_utf8_buffer()))
