extends RefCounted
## Regression coverage for the live-pull transport and settings reconnect path.

const CASE_ID := "live_feed.live_pull_reconnect"
const LivePullClientScript := preload("res://addons/live-pull/live_pull_client.gd")
const LivePullViewScript := preload("res://addons/live-pull/live_pull_dense_map_view.gd")
const CapturePanelScript := preload("res://scripts/ui/view_locked_capture_panel.gd")
const RecordControlScript := preload("res://scripts/ui/view_locked_record_control.gd")

const TEST_SERVER_INSTANCE_ID := "unit-test-result-server"

var _last_result_hello: Dictionary = {}
var _connected_before_welcome := false


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var server := TCPServer.new()
	t.eq(server.listen(0, "127.0.0.1"), OK, "loopback result server listens")
	var port := server.get_local_port()
	t.is_true(port > 0, "loopback result server receives an ephemeral port")

	var client = LivePullClientScript.new()
	var first := _connect(server, client, port, "secret")
	t.is_true(first != null, "first result connection reaches connected state")
	t.eq(client.get_connection_state(), "connected", "first connection is active")
	t.eq(client.auth_token, "secret", "result authentication token reaches client")
	var hello := _last_result_hello
	t.eq(int(hello.get("frame_type", -1)), 100, "client sends result_hello first")
	t.eq(str(hello.get("schema", "")), "operator.result_hello.v1", "hello schema matches")
	t.eq(str(hello.get("auth_token", "")), "secret", "hello carries the configured token")
	t.is_false(
		_connected_before_welcome,
		"TCP connect alone does not report success before result_welcome",
	)

	# Abrupt peer close used to leave StreamPeerTCP in STATUS_ERROR while the
	# logical state said DISCONNECTED. The next connect then failed forever with
	# ERR_ALREADY_IN_USE.
	if first != null:
		first.disconnect_from_host()
	t.is_true(
		_wait_for_state(client, "disconnected"),
		"peer close transitions the client to disconnected",
	)

	var second := _connect(server, client, port, "secret")
	t.is_true(second != null, "client reconnects after abrupt peer close")
	t.eq(client.get_connection_state(), "connected", "second connection is active")
	client.disconnect_result()
	t.eq(client.get_connection_state(), "disconnected", "manual disconnect resets transport")
	if second != null:
		second.disconnect_from_host()
	client.free()

	# The settings panel marks itself connecting before calling this view. If an
	# identical socket is already live, connect_to_server must re-emit success
	# instead of returning silently and leaving Save disabled.
	var view = LivePullViewScript.new()
	view._ensure_client()
	var connected := {"count": 0}
	view.connected_to_server.connect(func(_host: String, _port: int) -> void:
		connected["count"] = int(connected["count"]) + 1
	)
	view.connect_to_server("127.0.0.1", port, "secret")
	var view_peer := _wait_for_view_connection(server, view)
	t.is_true(view_peer != null, "view establishes its first result connection")
	t.eq(int(connected["count"]), 1, "first connect emits success once")
	view.connect_to_server("127.0.0.1", port, "secret")
	t.eq(int(connected["count"]), 2, "repeated Connect re-emits success")
	view.disconnect_from_server()
	if view_peer != null:
		view_peer.disconnect_from_host()
	view.free()
	server.stop()

	# Authenticated QR/default configuration must survive the settings form.
	# The token control was accidentally replaced by the stream readout, causing
	# every authenticated push session to send an empty token.
	var panel = CapturePanelScript.new(true)
	t.is_true(panel._server_token != null, "live server token control exists")
	panel.set_live_server_defaults("10.0.0.2", 64010, "qr-secret", 64012)
	var options: Dictionary = panel.get_options()
	t.eq(options.get("server_auth_token"), "qr-secret", "settings preserve auth token")
	panel.set_live_server_connectivity_status("connected", "success")
	t.is_true(panel._live_server_connected, "successful endpoint unlocks Save")
	panel._result_port.value = 64014
	t.eq(int(panel._result_port.value), 64014, "result port edit reaches the form")
	t.is_true(
		not panel._live_server_save_blocker().is_empty(),
		"editing either port invalidates the verified endpoint before Save",
	)
	t.is_false(panel._live_server_connected, "stale connected state is cleared")
	panel.free()

	# Live Feed transmits but does not create a local recording. Its active
	# indicator must therefore breathe without presenting a recording timer.
	var record_control = RecordControlScript.new()
	record_control.set_live_feed_mode(true)
	record_control.set_recording(true)
	t.is_false(record_control._timer_label.visible, "live feed hides elapsed timer")
	t.is_true(
		record_control._breathing_indicator.visible,
		"live feed shows breathing transmission indicator",
	)
	t.is_true(
		record_control._breathing_indicator._active,
		"breathing transmission indicator animates while active",
	)
	record_control.set_live_feed_mode(false)
	t.is_true(record_control._timer_label.visible, "recording mode still shows timer")
	t.is_false(
		record_control._breathing_indicator.visible,
		"recording mode hides transmission indicator",
	)
	record_control.free()


func _connect(
	server: TCPServer,
	client: Variant,
	port: int,
	token: String
) -> StreamPeerTCP:
	client.connect_result("127.0.0.1", port, token)
	var peer: StreamPeerTCP = null
	var welcomed := false
	for _index in range(1000):
		client._process(0.01)
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		if peer != null and not welcomed:
			var hello := _read_result_hello(peer)
			if not hello.is_empty():
				_last_result_hello = hello
				_connected_before_welcome = client.is_result_connected()
				_send_result_welcome(peer, TEST_SERVER_INSTANCE_ID)
				welcomed = true
		if peer != null and client.is_result_connected():
			return peer
		OS.delay_msec(1)
	return peer if client.is_result_connected() else null


func _wait_for_state(client: Variant, expected: String) -> bool:
	for _index in range(1000):
		client._process(0.01)
		if client.get_connection_state() == expected:
			return true
		OS.delay_msec(1)
	return false


func _wait_for_view_connection(server: TCPServer, view: Variant) -> StreamPeerTCP:
	var peer: StreamPeerTCP = null
	var welcomed := false
	for _index in range(1000):
		view.client._process(0.01)
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		if peer != null and not welcomed:
			var hello := _read_result_hello(peer)
			if not hello.is_empty():
				_send_result_welcome(peer, TEST_SERVER_INSTANCE_ID)
				welcomed = true
		if peer != null and view.client.is_result_connected():
			return peer
		OS.delay_msec(1)
	return null


func _read_result_hello(peer: StreamPeerTCP) -> Dictionary:
	if peer == null:
		return {}
	var bytes := PackedByteArray()
	for _index in range(1000):
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			var result := peer.get_data(available)
			if int(result[0]) != OK:
				return {}
			bytes.append_array(result[1])
		if bytes.size() >= 28:
			var payload_size := (
				(bytes[24] << 24)
				| (bytes[25] << 16)
				| (bytes[26] << 8)
				| bytes[27]
			)
			if bytes.size() >= 28 + payload_size:
				var parsed: Variant = JSON.parse_string(
					bytes.slice(28, 28 + payload_size).get_string_from_utf8()
				)
				if parsed is Dictionary:
					var hello: Dictionary = parsed
					hello["frame_type"] = int(bytes[5])
					return hello
				return {}
		OS.delay_msec(1)
	return {}


func _send_result_welcome(peer: StreamPeerTCP, server_instance_id: String) -> void:
	var payload := JSON.stringify({
		"schema": "operator.result_welcome.v1",
		"protocol": "operator.live_feed.v2",
		"server_instance_id": server_instance_id,
	}).to_utf8_buffer()
	var frame := PackedByteArray([
		79, 76, 67, 80,
		1, 102, 0, 0,
	])
	for _index in range(16):
		frame.append(0)
	_append_be_u32(frame, payload.size())
	frame.append_array(payload)
	peer.put_data(frame)


func _append_be_u32(buffer: PackedByteArray, value: int) -> void:
	buffer.append((value >> 24) & 0xff)
	buffer.append((value >> 16) & 0xff)
	buffer.append((value >> 8) & 0xff)
	buffer.append(value & 0xff)
