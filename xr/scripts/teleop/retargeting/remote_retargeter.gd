class_name RemoteRetargeter
extends Node
## Latest-only WebSocket client for retargeting-service protocol v1.

signal service_ready(profile: Dictionary)
signal result_received(result: Dictionary)
signal state_changed(state: String, detail: String)
signal faulted(code: String, message: String)

const PROTOCOL_VERSION := 1
const RESULT_TIMEOUT_MSEC := 2000

var _peer: WebSocketPeer
var _state := "idle"
var _url := ""
var _profile: Dictionary = {}
var _hello_sent := false
var _pending: Dictionary = {}
var _inflight := false
var _inflight_frame_id := 0
var _next_frame_id := 1
var _last_send_msec := 0
var _reported_timeout := false


func start(config: Dictionary) -> Error:
	stop()
	var host := str(config.get("host", "")).strip_edges()
	var port := int(config.get("port", 0))
	_profile = config.get("profile", {}).duplicate(true)
	if host.is_empty() or port <= 0 or port > 65535 or _profile.is_empty():
		_emit_fault("invalid_config", "Remote retargeting host, port, and profile are required")
		return ERR_INVALID_PARAMETER
	var scheme := "wss" if bool(config.get("tls", false)) else "ws"
	_url = "%s://%s:%d/v1/retarget" % [scheme, host, port]
	_peer = WebSocketPeer.new()
	var err := _peer.connect_to_url(_url)
	if err != OK:
		_emit_fault("connect_failed", "WebSocket connect failed: %d" % err)
		_peer = null
		return err
	_set_state("connecting", _url)
	set_process(true)
	return OK


func stop() -> void:
	set_process(false)
	if _peer != null:
		_peer.close(1000, "client stop")
	_peer = null
	_hello_sent = false
	_pending.clear()
	_inflight = false
	_inflight_frame_id = 0
	_reported_timeout = false
	_set_state("idle", "")


func is_ready() -> bool:
	return _state == "ready"


func submit_payload(payload: Dictionary, timestamp_ns: int) -> void:
	_pending = {
		"type": "frame",
		"frame_id": _next_frame_id,
		"timestamp_ns": timestamp_ns,
		"payload": payload.duplicate(true),
	}
	_next_frame_id += 1


func reset() -> void:
	_pending.clear()
	_inflight = false
	_inflight_frame_id = 0
	if is_ready():
		_send_json({"type": "reset"})


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.poll()
	match _peer.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			return
		WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_send_hello()
			_drain_packets()
			if is_ready() and not _inflight and not _pending.is_empty():
				var frame := _pending
				_pending = {}
				if _send_json(frame) == OK:
					_inflight = true
					_inflight_frame_id = int(frame.get("frame_id", 0))
					_last_send_msec = Time.get_ticks_msec()
					_reported_timeout = false
			if (
				_inflight
				and not _reported_timeout
				and Time.get_ticks_msec() - _last_send_msec > RESULT_TIMEOUT_MSEC
			):
				_reported_timeout = true
				_inflight = false
				_inflight_frame_id = 0
				faulted.emit(
					"result_timeout", "No retargeting result for %d ms" % RESULT_TIMEOUT_MSEC
				)
		WebSocketPeer.STATE_CLOSING:
			return
		WebSocketPeer.STATE_CLOSED:
			var detail := (
				"WebSocket closed (%d): %s" % [_peer.get_close_code(), _peer.get_close_reason()]
			)
			_peer = null
			set_process(false)
			_emit_fault("disconnected", detail)


func _send_hello() -> void:
	_hello_sent = true
	_send_json(
		{
			"type": "hello",
			"protocol_version": PROTOCOL_VERSION,
			"profile_id": str(_profile.get("profile_id", "")),
			"input_type": str(_profile.get("input_type", "")),
			"model_hash": str(_profile.get("model_hash", "")),
		}
	)
	_set_state("handshaking", str(_profile.get("profile_id", "")))


func _drain_packets() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY:
			_emit_fault("invalid_response", "retargeting-service returned invalid JSON")
			continue
		var message := parsed as Dictionary
		match str(message.get("type", "")):
			"hello_ack":
				if not _validate_hello_ack(message):
					continue
				_set_state("ready", str(_profile.get("profile_id", "")))
				service_ready.emit(message.get("profile", {}))
			"result":
				if int(message.get("frame_id", 0)) != _inflight_frame_id:
					continue
				if not _validate_result(message):
					continue
				_inflight = false
				_inflight_frame_id = 0
				_reported_timeout = false
				result_received.emit(message)
			"reset_ack":
				pass
			"error":
				if message.has("frame_id"):
					if int(message.get("frame_id", 0)) != _inflight_frame_id:
						continue
					_inflight = false
					_inflight_frame_id = 0
					faulted.emit(
						str(message.get("code", "remote_error")), str(message.get("message", ""))
					)
				else:
					_emit_fault(
						str(message.get("code", "remote_error")), str(message.get("message", ""))
					)
			_:
				_emit_fault(
					"unknown_response", "Unknown service message: %s" % JSON.stringify(message)
				)


func _validate_hello_ack(message: Dictionary) -> bool:
	if int(message.get("protocol_version", 0)) != PROTOCOL_VERSION:
		_reject_protocol("protocol_mismatch", "retargeting-service protocol version does not match")
		return false
	var service_profile_value: Variant = message.get("profile", {})
	if typeof(service_profile_value) != TYPE_DICTIONARY:
		_reject_protocol("invalid_response", "retargeting-service profile is missing")
		return false
	var service_profile := service_profile_value as Dictionary
	for field in ["profile_id", "input_type", "output_type"]:
		var expected := str(_profile.get(field, ""))
		var actual := str(service_profile.get(field, ""))
		if expected.is_empty() or actual != expected:
			_reject_protocol(
				"profile_mismatch",
				"retargeting-service %s '%s' does not match '%s'" % [field, actual, expected]
			)
			return false
	return true


func _validate_result(message: Dictionary) -> bool:
	if str(message.get("profile_id", "")) != str(_profile.get("profile_id", "")):
		_reject_protocol("profile_mismatch", "Retargeting result has the wrong profile")
		return false
	if str(message.get("output_type", "")) != str(_profile.get("output_type", "")):
		_reject_protocol("output_type_mismatch", "Retargeting result has the wrong output type")
		return false
	var q_value: Variant = message.get("q", [])
	if typeof(q_value) != TYPE_ARRAY:
		_reject_protocol("invalid_result", "Retargeting result q must be an array")
		return false
	var q := q_value as Array
	var expected_size := int(_profile.get("expected_q_size", 0))
	if expected_size <= 0 or q.size() != expected_size:
		_reject_protocol(
			"model_mismatch",
			"Retargeting result has %d positions; expected %d" % [q.size(), expected_size]
		)
		return false
	for value in q:
		if not is_finite(float(value)):
			_reject_protocol("invalid_result", "Retargeting result contains a non-finite value")
			return false
	return true


func _reject_protocol(code: String, message: String) -> void:
	_emit_fault(code, message)
	if _peer != null:
		_peer.close(1008, code)


func _send_json(message: Dictionary) -> Error:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_CONNECTION_ERROR
	return _peer.send_text(JSON.stringify(message))


func _set_state(next: String, detail: String) -> void:
	if _state == next and detail.is_empty():
		return
	_state = next
	state_changed.emit(_state, detail)


func _emit_fault(code: String, message: String) -> void:
	_set_state("faulted", message)
	faulted.emit(code, message)
