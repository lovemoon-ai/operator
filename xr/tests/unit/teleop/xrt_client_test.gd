extends RefCounted
## Loopback coverage for the XRoboToolkit TCP transport. This exercises the
## real StreamPeerTCP path without requiring RoboticsService or an XR runtime.

const CASE_ID := "teleop.xrt_client"
const XrtClientScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_client.gd"
)
const XrtProtocolScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_protocol.gd"
)


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_receive_buffer_cap(t)
	var server := TCPServer.new()
	t.eq(server.listen(0, "127.0.0.1"), OK, "loopback RoboticsService listens")
	var port := server.get_local_port()
	t.is_true(port > 0, "loopback RoboticsService receives an ephemeral port")

	var client = XrtClientScript.new()
	client.reconnect_delay_sec = 0.0
	var received: Array = []
	var disconnects: Array = []
	client.packet_received.connect(func(command: int, payload: PackedByteArray, timestamp_ms: int) -> void:
		received.append({
			"command": command,
			"payload": payload.get_string_from_utf8(),
			"timestamp_ms": timestamp_ms,
		})
	)
	client.disconnected.connect(func(reason: String) -> void: disconnects.append(reason))

	client.connect_to_server("127.0.0.1", port)
	var first_peer := _wait_for_connection(server, client)
	if not t.is_true(first_peer != null, "client establishes a real TCP connection"):
		client.disconnect_from_server()
		server.stop()
		client.free()
		return

	var time_test := _server_frame(
		XrtProtocolScript.CMD_SERVER_FUNCTION,
		'{"functionName":"timeTest"}',
		1_700_000_000_001,
	)
	var other := _server_frame(0x71, "opaque", 1_700_000_000_002)
	first_peer.put_data(time_test.slice(0, 5))
	_pump(client, first_peer, 5)
	t.eq(received.size(), 0, "fragmented server header remains buffered")
	var combined := time_test.slice(5)
	combined.append_array(other)
	first_peer.put_data(combined)
	_pump_until(client, first_peer, func() -> bool: return received.size() == 2)
	t.eq(received.size(), 2, "fragmented and coalesced server frames both decode")
	if received.size() == 2:
		t.eq(received[0].get("command"), XrtProtocolScript.CMD_SERVER_FUNCTION,
			"first server command is preserved")
		t.eq(received[0].get("payload"), '{"functionName":"timeTest"}',
			"first server payload is preserved")
		t.eq(received[0].get("timestamp_ms"), 1_700_000_000_001,
			"first server timestamp is preserved")
		t.eq(received[1].get("command"), 0x71, "second coalesced command is preserved")

	var response := _read_client_frame(first_peer)
	t.eq(response.get("head"), XrtProtocolScript.PACKET_HEAD,
		"timeTest response uses the client packet header")
	t.eq(response.get("command"), XrtProtocolScript.CMD_TRACKING,
		"timeTest response uses legacy command 0x6D")
	t.eq(response.get("payload"), "timeTest",
		"timeTest response preserves the raw legacy payload")

	first_peer.disconnect_from_host()
	_pump_until(client, null, func() -> bool: return not disconnects.is_empty())
	t.eq(disconnects.size(), 1, "peer close transitions the client into reconnect")
	var second_peer := _wait_for_connection(server, client)
	t.is_true(second_peer != null, "client reconnects through a fresh socket")

	client.disconnect_from_server()
	if second_peer != null:
		second_peer.disconnect_from_host()
	server.stop()
	client.free()


## A desynced length field under MAX_PAYLOAD_SIZE keeps every unpack attempt at
## INCOMPLETE, so the receive buffer used to grow without any cap while the
## render thread copied it on every discard.
func _test_receive_buffer_cap(t: OperatorTestAssertions) -> void:
	var server := TCPServer.new()
	t.eq(server.listen(0, "127.0.0.1"), OK, "buffer-cap fixture listens on loopback")
	var client = XrtClientScript.new()
	# Long enough that the client stays parked after the overflow drop.
	client.reconnect_delay_sec = 3600.0
	var disconnects: Array = []
	client.disconnected.connect(func(reason: String) -> void: disconnects.append(reason))
	client.connect_to_server("127.0.0.1", server.get_local_port())
	var peer := _wait_for_connection(server, client)
	if not t.is_true(peer != null, "buffer-cap fixture establishes a TCP connection"):
		client.disconnect_from_server()
		server.stop()
		client.free()
		return

	t.is_true(
		XrtClientScript.MAX_RECEIVE_BUFFER_SIZE
			>= XrtProtocolScript.FRAME_OVERHEAD_SIZE + XrtProtocolScript.MAX_PAYLOAD_SIZE,
		"the receive cap still admits the largest legal frame",
	)
	var desynced := PackedByteArray()
	desynced.resize(XrtProtocolScript.FRAME_OVERHEAD_SIZE)
	desynced[0] = XrtProtocolScript.RECEIVE_PACKET_HEAD
	desynced.encode_s32(2, XrtProtocolScript.MAX_PAYLOAD_SIZE)
	var stalled_frame: Dictionary = XrtProtocolScript.unpack_server_frame(desynced)
	t.eq(stalled_frame.get("status"), XrtProtocolScript.UNPACK_INCOMPLETE,
		"a desynced length field under the payload limit never completes a frame")
	t.eq(stalled_frame.get("consumed"), 0,
		"nothing is consumed while the oversized frame is awaited")

	var stalled := desynced.duplicate()
	stalled.resize(XrtClientScript.MAX_RECEIVE_BUFFER_SIZE)
	client._receive_buffer = stalled

	peer.put_data(PackedByteArray([0x00]))
	_pump_until(client, peer, func() -> bool: return not disconnects.is_empty())
	t.eq(disconnects.size(), 1, "a receive buffer at the cap drops the connection")
	if not disconnects.is_empty():
		t.is_true(str(disconnects[0]).contains("overflow"),
			"the drop reason names the receive buffer overflow")
	t.is_true(client._receive_buffer.is_empty(),
		"the overflowing buffer is released instead of growing further")
	t.is_false(client.is_connected_to_server(),
		"an overflowed connection is no longer reported as connected")

	client.disconnect_from_server()
	peer.disconnect_from_host()
	server.stop()
	client.free()


func _wait_for_connection(server: TCPServer, client: Variant) -> StreamPeerTCP:
	var peer: StreamPeerTCP = null
	for _index in range(1000):
		client._process(0.01)
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		if peer != null:
			peer.poll()
		if peer != null and client.is_connected_to_server():
			return peer
		OS.delay_msec(1)
	return null


func _pump(client: Variant, peer: StreamPeerTCP, iterations: int) -> void:
	for _index in range(iterations):
		client._process(0.01)
		if peer != null:
			peer.poll()
		OS.delay_msec(1)


func _pump_until(client: Variant, peer: StreamPeerTCP, condition: Callable) -> bool:
	for _index in range(1000):
		client._process(0.01)
		if peer != null:
			peer.poll()
		if condition.call():
			return true
		OS.delay_msec(1)
	return false


func _server_frame(command: int, payload_text: String, timestamp_ms: int) -> PackedByteArray:
	var payload := payload_text.to_utf8_buffer()
	var frame := PackedByteArray()
	frame.resize(XrtProtocolScript.FRAME_OVERHEAD_SIZE + payload.size())
	frame[0] = XrtProtocolScript.RECEIVE_PACKET_HEAD
	frame[1] = command
	frame.encode_s32(2, payload.size())
	for index in payload.size():
		frame[6 + index] = payload[index]
	frame.encode_s64(6 + payload.size(), timestamp_ms)
	frame[frame.size() - 1] = XrtProtocolScript.PACKET_TAIL
	return frame


func _read_client_frame(peer: StreamPeerTCP) -> Dictionary:
	var bytes := PackedByteArray()
	for _index in range(1000):
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			var result := peer.get_data(available)
			if int(result[0]) != OK:
				return {}
			bytes.append_array(result[1])
		if bytes.size() >= XrtProtocolScript.FRAME_OVERHEAD_SIZE:
			var payload_size := bytes.decode_s32(2)
			var frame_size := XrtProtocolScript.FRAME_OVERHEAD_SIZE + payload_size
			if payload_size >= 0 and bytes.size() >= frame_size:
				return {
					"head": int(bytes[0]),
					"command": int(bytes[1]),
					"payload": bytes.slice(6, 6 + payload_size).get_string_from_utf8(),
				}
		OS.delay_msec(1)
	return {}
