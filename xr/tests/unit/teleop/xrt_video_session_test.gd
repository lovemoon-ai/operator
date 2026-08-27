extends RefCounted
## Loopback lifecycle coverage for the independent XRoboToolkit FPV session.

const CASE_ID := "teleop.xrt_video_session"
const XrtCameraProtocolScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_camera_protocol.gd"
)
const VideoLatencyTracker := preload("res://addons/live_video/live_video_latency.gd")
const XrtVideoSessionScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_video_session.gd"
)


class LoopbackVideoSession:
	extends XrtVideoSession

	func _get_local_addresses() -> PackedStringArray:
		return PackedStringArray([
			"127.0.0.1",
			"169.254.8.9",
			"10.20.30.44",
		])


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_local_ipv4_selection(t)
	_test_loopback_session_lifecycle(t)


func _test_local_ipv4_selection(t: OperatorTestAssertions) -> void:
	var candidates := PackedStringArray([
		"127.0.0.1",
		"169.254.10.2",
		"2001:db8::1",
		"10.0.0.8",
		"192.168.50.9",
		"198.51.100.4",
	])
	t.eq(
		XrtVideoSessionScript.select_local_ipv4("192.168.50.20", candidates),
		"192.168.50.9",
		"local IPv4 selection prefers the PC /24",
	)
	t.eq(
		XrtVideoSessionScript.select_local_ipv4("example.invalid", candidates),
		"10.0.0.8",
		"local IPv4 selection falls back to RFC1918",
	)
	t.eq(
		XrtVideoSessionScript.select_local_ipv4(
			"203.0.113.10", PackedStringArray(["127.0.0.1", "169.254.1.2"])
		),
		"",
		"local IPv4 selection excludes loopback and link-local addresses",
	)


func _test_loopback_session_lifecycle(t: OperatorTestAssertions) -> void:
	var command_server := TCPServer.new()
	t.eq(command_server.listen(0, "127.0.0.1"), OK, "loopback camera command server listens")
	var command_port := command_server.get_local_port()
	var session := LoopbackVideoSession.new()
	session.connect_timeout_sec = 1.0
	session.video_timeout_sec = 1.0
	var packets: Array = []
	var connected_count := [0]
	var failures: Array = []
	var disconnect_reasons: Array = []
	session.video_frame_received.connect(func(packet: Dictionary) -> void:
		packets.append(packet.duplicate(true))
	)
	session.connected.connect(func() -> void: connected_count[0] += 1)
	session.failed.connect(func(message: String) -> void: failures.append(message))
	session.disconnected.connect(func(reason: String) -> void: disconnect_reasons.append(reason))

	session.start({
		"host": "127.0.0.1",
		"command_port": command_port,
		"width": 1280,
		"height": 720,
		"fps": 30,
		"bitrate": 4_000_000,
		"camera_name": "UNITREE_HEAD",
	})
	t.is_true(session.is_active(), "video session is active after choosing a receive port")
	t.is_true(
		session.get_listen_port() >= XrtVideoSessionScript.FIRST_VIDEO_PORT
			and session.get_listen_port() <= XrtVideoSessionScript.LAST_VIDEO_PORT,
		"video session listens in the XRoboToolkit port range",
	)

	var command_peer := _wait_for_command_connection(command_server, session)
	if not t.is_true(command_peer != null, "video session connects to the command server"):
		_cleanup(session, command_peer, null, command_server)
		return
	var open_frame := _read_command_frame(command_peer, session)
	var open_command: Dictionary = XrtCameraProtocolScript.decode_command_frame(open_frame)
	t.eq(open_command.get("command"), XrtCameraProtocolScript.COMMAND_OPEN_CAMERA,
		"session sends OPEN_CAMERA after the command connection")
	var open_payload: Dictionary = XrtCameraProtocolScript.decode_open_camera_payload(
		open_command.get("payload", PackedByteArray())
	)
	t.eq(open_payload.get("listen_port"), session.get_listen_port(),
		"OPEN_CAMERA advertises the active video listener")
	t.eq(open_payload.get("pico_ip"), "10.20.30.44",
		"OPEN_CAMERA advertises the selected non-loopback PICO IPv4")

	var video_sender := StreamPeerTCP.new()
	t.eq(
		video_sender.connect_to_host("127.0.0.1", session.get_listen_port()),
		OK,
		"robot bridge initiates the reverse video connection",
	)
	var streaming := _pump_until(session, command_peer, video_sender, func() -> bool:
		return session.is_streaming()
	)
	t.is_true(streaming, "session accepts the reverse video connection")
	t.eq(connected_count[0], 1, "connected emits after the reverse video link is ready")
	t.eq(session.get_transport_loss_text(), "N/A",
		"XRoboToolkit framing reports transport loss as unavailable")

	var first_au := PackedByteArray([0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
	var second_au := PackedByteArray([0x00, 0x00, 0x01, 0x65, 0x01, 0x02])
	var first_frame: PackedByteArray = XrtCameraProtocolScript.encode_video_access_unit(first_au)
	var second_frame: PackedByteArray = XrtCameraProtocolScript.encode_video_access_unit(second_au)
	video_sender.put_data(first_frame.slice(0, 2))
	_pump(session, command_peer, video_sender, 5)
	t.eq(packets.size(), 0, "fragmented video length remains buffered")
	var combined := first_frame.slice(2)
	combined.append_array(second_frame)
	video_sender.put_data(combined)
	_pump_until(session, command_peer, video_sender, func() -> bool: return packets.size() == 2)
	t.eq(packets.size(), 2, "fragmented and coalesced video frames both decode")
	if packets.size() == 2:
		t.eq((packets[0] as Dictionary).get("nal_data"), first_au,
			"first video packet preserves the complete access unit")
		t.eq((packets[0] as Dictionary).get("frame_id"), 0,
			"video packet frame IDs start at zero")
		t.eq((packets[1] as Dictionary).get("nal_data"), second_au,
			"second coalesced access unit is emitted")
		t.eq((packets[1] as Dictionary).get("frame_id"), 1,
			"video packet frame IDs increase monotonically")
		t.eq((packets[1] as Dictionary).get("nal_count"), 1,
			"each XRoboToolkit access unit is one decoder packet")
		t.eq((packets[1] as Dictionary).get("transport_loss_available"), false,
			"session does not claim unavailable XRoboToolkit transport loss data")
		var receive_age_ns := (
			VideoLatencyTracker.now_ns() - int((packets[1] as Dictionary).get("receive_ns", 0))
		)
		t.is_true(
			receive_age_ns >= 0 and receive_age_ns < 5_000_000_000,
			"video receive timestamps use the wall-clock domain expected by LiveVideoView",
		)

	session.stop()
	var close_frame := _read_command_frame(command_peer, null)
	var close_command: Dictionary = XrtCameraProtocolScript.decode_command_frame(close_frame)
	t.eq(close_command.get("command"), XrtCameraProtocolScript.COMMAND_CLOSE_CAMERA,
		"stopping the session sends CLOSE_CAMERA")
	t.eq(session.get_state(), XrtVideoSessionScript.State.IDLE, "stop returns the session to idle")
	t.is_false(session.is_active(), "stopped session is no longer active")
	t.eq(disconnect_reasons, ["stopped"], "stop reports its reason exactly once")
	t.eq(failures, [], "successful loopback lifecycle emits no failure")

	_cleanup(session, command_peer, video_sender, command_server)


func _wait_for_command_connection(
		server: TCPServer,
		session: Variant
	) -> StreamPeerTCP:
	var peer: StreamPeerTCP = null
	for _index in range(1000):
		session._process(0.005)
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		if peer != null:
			peer.poll()
		if peer != null and session.get_state() == XrtVideoSessionScript.State.WAITING_VIDEO:
			return peer
		OS.delay_msec(1)
	return null


func _read_command_frame(peer: StreamPeerTCP, session: Variant) -> PackedByteArray:
	var buffer := PackedByteArray()
	for _index in range(1000):
		if session != null:
			session._process(0.001)
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			var result := peer.get_data(available)
			if int(result[0]) != OK:
				return PackedByteArray()
			buffer.append_array(result[1])
		var decoded: Dictionary = XrtCameraProtocolScript.decode_command_frame(buffer)
		if not decoded.is_empty():
			return buffer.slice(0, int(decoded.get("bytes_consumed", 0)))
		OS.delay_msec(1)
	return PackedByteArray()


func _pump(
		session: Variant,
		command_peer: StreamPeerTCP,
		video_sender: StreamPeerTCP,
		iterations: int
	) -> void:
	for _index in iterations:
		session._process(0.005)
		if command_peer != null:
			command_peer.poll()
		if video_sender != null:
			video_sender.poll()
		OS.delay_msec(1)


func _pump_until(
		session: Variant,
		command_peer: StreamPeerTCP,
		video_sender: StreamPeerTCP,
		condition: Callable
	) -> bool:
	for _index in range(1000):
		_pump(session, command_peer, video_sender, 1)
		if condition.call():
			return true
	return false


func _cleanup(
		session: Variant,
		command_peer: StreamPeerTCP,
		video_sender: StreamPeerTCP,
		command_server: TCPServer
	) -> void:
	if session != null:
		if session.get_state() != XrtVideoSessionScript.State.IDLE:
			session.stop()
		session.free()
	if command_peer != null:
		command_peer.disconnect_from_host()
	if video_sender != null:
		video_sender.disconnect_from_host()
	command_server.stop()
