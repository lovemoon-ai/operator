class_name LivePullClient
extends Node

signal connected_to_server()
signal disconnected_from_server()
signal connection_failed(reason: String)
signal status_received(status: Dictionary)
signal map_reset_received(reset: Dictionary)
signal manifest_received(manifest: Dictionary)
signal dense_chunk_ready(metadata: Dictionary, payload: PackedByteArray)
signal dense_commit_received(commit: Dictionary)
signal trajectory_received(trajectory: Dictionary)
signal map_transform_received(transform: Dictionary)

const MAGIC_0 := 79
const MAGIC_1 := 76
const MAGIC_2 := 67
const MAGIC_3 := 80
const PROTOCOL_VERSION := 1
const HEADER_SIZE := 28
const READ_CHUNK_SIZE := 65536
const MAX_DRAIN_PER_TICK := 32
const DEFAULT_MAX_RECV_BUFFER := 64 * 1024 * 1024

const FLAG_COMPOSITE_JSON := 2

const TYPE_ALGORITHM_STATUS := 110
const TYPE_MAP_RESET := 111
const TYPE_DENSE_MAP_MANIFEST := 112
const TYPE_DENSE_MAP_FRAGMENT := 113
const TYPE_DENSE_MAP_COMMIT := 114
const TYPE_CAMERA_TRAJECTORY := 115
const TYPE_MAP_TRANSFORM := 116

enum State {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
}

@export var host := "127.0.0.1"
@export var port := 63912
@export var connect_timeout_s := 5.0
@export var max_recv_buffer := DEFAULT_MAX_RECV_BUFFER

var _tcp := StreamPeerTCP.new()
var _state: State = State.DISCONNECTED
var _recv_buffer := PackedByteArray()
var _connect_elapsed := 0.0
var _bad_status_ticks := 0
var _latest_map_version := -1
var _manifests: Dictionary = {}
var _fragment_sets: Dictionary = {}
var _complete_chunks: Dictionary = {}


func connect_result(result_host: String = host, result_port: int = port) -> void:
	disconnect_result()
	host = result_host.strip_edges()
	if host.is_empty():
		host = "127.0.0.1"
	port = clampi(result_port, 1, 65535)
	_recv_buffer.clear()
	_fragment_sets.clear()
	_complete_chunks.clear()
	_connect_elapsed = 0.0
	var err := _tcp.connect_to_host(host, port)
	if err != OK:
		_state = State.DISCONNECTED
		connection_failed.emit("connect_to_host failed: %d" % err)
		return
	_state = State.CONNECTING


func disconnect_result() -> void:
	if _state != State.DISCONNECTED:
		_tcp.disconnect_from_host()
	_state = State.DISCONNECTED
	_recv_buffer.clear()


func is_result_connected() -> bool:
	return _state == State.CONNECTED


func is_result_active() -> bool:
	return _state == State.CONNECTING or _state == State.CONNECTED


func get_connection_state() -> String:
	match _state:
		State.CONNECTING:
			return "connecting"
		State.CONNECTED:
			return "connected"
	return "disconnected"


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
	if status == StreamPeerTCP.STATUS_CONNECTED:
		_state = State.CONNECTED
		_tcp.set_no_delay(true)
		connected_to_server.emit()
	elif status == StreamPeerTCP.STATUS_CONNECTING:
		_connect_elapsed += delta
		if _connect_elapsed >= connect_timeout_s:
			_tcp.disconnect_from_host()
			_state = State.DISCONNECTED
			connection_failed.emit("connection timed out")
	elif status == StreamPeerTCP.STATUS_ERROR:
		_state = State.DISCONNECTED
		connection_failed.emit("connection error")
	elif status == StreamPeerTCP.STATUS_NONE:
		_state = State.DISCONNECTED
		connection_failed.emit("connection reset")


func _process_connected() -> void:
	_tcp.poll()
	var status := _tcp.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_bad_status_ticks += 1
		if _bad_status_ticks <= 5:
			return
		_state = State.DISCONNECTED
		_bad_status_ticks = 0
		_recv_buffer.clear()
		disconnected_from_server.emit()
		return
	_bad_status_ticks = 0

	var drained := 0
	while drained < MAX_DRAIN_PER_TICK:
		drained += 1
		var available := _tcp.get_available_bytes()
		if available <= 0:
			break
		var result := _tcp.get_data(mini(available, READ_CHUNK_SIZE))
		var err: int = result[0]
		var data: PackedByteArray = result[1]
		if err != OK:
			_state = State.DISCONNECTED
			_recv_buffer.clear()
			disconnected_from_server.emit()
			return
		_recv_buffer.append_array(data)
		if _recv_buffer.size() > max_recv_buffer:
			_state = State.DISCONNECTED
			_recv_buffer.clear()
			connection_failed.emit("receive buffer overflow")
			return
	_parse_frames()


func _parse_frames() -> void:
	var safety := 0
	while _recv_buffer.size() >= HEADER_SIZE and safety < 128:
		safety += 1
		if _recv_buffer[0] != MAGIC_0 or _recv_buffer[1] != MAGIC_1 or _recv_buffer[2] != MAGIC_2 or _recv_buffer[3] != MAGIC_3:
			_recv_buffer.clear()
			connection_failed.emit("invalid OLCP magic")
			return
		var version := _recv_buffer[4]
		if version != PROTOCOL_VERSION:
			_recv_buffer.clear()
			connection_failed.emit("unsupported OLCP version: %d" % version)
			return
		var frame_type := _recv_buffer[5]
		var flags := _be_u16(_recv_buffer, 6)
		var pts_ns := _be_u64(_recv_buffer, 8)
		var duration_ns := _be_u64(_recv_buffer, 16)
		var payload_size := _be_u32(_recv_buffer, 24)
		var frame_size := HEADER_SIZE + payload_size
		if _recv_buffer.size() < frame_size:
			break
		var payload := _recv_buffer.slice(HEADER_SIZE, frame_size)
		_recv_buffer = _recv_buffer.slice(frame_size)
		_dispatch_frame(frame_type, flags, pts_ns, duration_ns, payload)


func _dispatch_frame(frame_type: int, flags: int, _pts_ns: int, _duration_ns: int, payload: PackedByteArray) -> void:
	match frame_type:
		TYPE_ALGORITHM_STATUS:
			status_received.emit(_json_payload(payload))
		TYPE_MAP_RESET:
			_handle_map_reset(_json_payload(payload))
		TYPE_DENSE_MAP_MANIFEST:
			if _looks_like_json(payload):
				_handle_manifest(_json_payload(payload))
			elif (flags & FLAG_COMPOSITE_JSON) != 0:
				_handle_legacy_dense_chunk(payload)
		TYPE_DENSE_MAP_FRAGMENT:
			_handle_fragment(payload)
		TYPE_DENSE_MAP_COMMIT:
			_handle_commit(_json_payload(payload))
		TYPE_CAMERA_TRAJECTORY:
			trajectory_received.emit(_json_payload(payload))
		TYPE_MAP_TRANSFORM:
			map_transform_received.emit(_json_payload(payload))
		_:
			pass


func _handle_map_reset(reset: Dictionary) -> void:
	_latest_map_version = int(reset.get("map_version", _latest_map_version))
	_manifests.clear()
	_fragment_sets.clear()
	_complete_chunks.clear()
	map_reset_received.emit(reset)


func _handle_manifest(manifest: Dictionary) -> void:
	var version := int(manifest.get("map_version", -1))
	if version >= 0 and version < _latest_map_version:
		return
	_manifests[version] = manifest
	manifest_received.emit(manifest)


func _handle_fragment(payload: PackedByteArray) -> void:
	var composite := _parse_composite(payload)
	var metadata: Dictionary = composite["metadata"]
	var binary: PackedByteArray = composite["binary"]
	var version := int(metadata.get("map_version", -1))
	if version >= 0 and version < _latest_map_version:
		return
	var chunk_id := str(metadata.get("chunk_id", ""))
	if chunk_id.is_empty():
		return
	var fragment_count := maxi(1, int(metadata.get("fragment_count", 1)))
	var fragment_index := clampi(int(metadata.get("fragment_index", 0)), 0, fragment_count - 1)
	if not _fragment_sets.has(chunk_id):
		_fragment_sets[chunk_id] = {
			"metadata": metadata,
			"fragment_count": fragment_count,
			"fragments": {}
		}
	var entry: Dictionary = _fragment_sets[chunk_id]
	var fragments: Dictionary = entry["fragments"]
	fragments[fragment_index] = binary
	if fragments.size() == fragment_count:
		var assembled := PackedByteArray()
		for i in range(fragment_count):
			if not fragments.has(i):
				return
			assembled.append_array(fragments[i])
		entry["metadata"] = metadata
		_complete_chunks[chunk_id] = {
			"metadata": metadata,
			"payload": assembled
		}
		_fragment_sets.erase(chunk_id)


func _handle_commit(commit: Dictionary) -> void:
	_latest_map_version = maxi(_latest_map_version, int(commit.get("map_version", _latest_map_version)))
	var replace_before := int(commit.get("replace_versions_before", -1))
	if replace_before >= 0:
		_drop_versions_before(replace_before)
	var committed := commit.get("committed_chunks", [])
	if typeof(committed) != TYPE_ARRAY:
		committed = []
	var missing_chunks: Array[String] = []
	for chunk_id_value in committed:
		var chunk_id := str(chunk_id_value)
		if _complete_chunks.has(chunk_id):
			var chunk: Dictionary = _complete_chunks[chunk_id]
			_complete_chunks.erase(chunk_id)
			dense_chunk_ready.emit(chunk["metadata"], chunk["payload"])
		else:
			missing_chunks.append(chunk_id)
	if not missing_chunks.is_empty():
		push_warning("Live-pull commit missing complete chunks map_version=%d chunks=%s" % [
			int(commit.get("map_version", -1)),
			",".join(missing_chunks)
		])
	dense_commit_received.emit(commit)


func _handle_legacy_dense_chunk(payload: PackedByteArray) -> void:
	var composite := _parse_composite(payload)
	var metadata: Dictionary = composite["metadata"]
	var binary: PackedByteArray = composite["binary"]
	_latest_map_version = maxi(_latest_map_version, int(metadata.get("map_version", _latest_map_version)))
	dense_chunk_ready.emit(metadata, binary)


func _drop_versions_before(version: int) -> void:
	for key in _fragment_sets.keys():
		var entry: Dictionary = _fragment_sets[key]
		var metadata: Dictionary = entry.get("metadata", {})
		if int(metadata.get("map_version", version)) < version:
			_fragment_sets.erase(key)
	for key in _complete_chunks.keys():
		var entry: Dictionary = _complete_chunks[key]
		var metadata: Dictionary = entry.get("metadata", {})
		if int(metadata.get("map_version", version)) < version:
			_complete_chunks.erase(key)


func _json_payload(payload: PackedByteArray) -> Dictionary:
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed as Dictionary
	return {}


func _parse_composite(payload: PackedByteArray) -> Dictionary:
	if payload.size() < 4:
		return {"metadata": {}, "binary": PackedByteArray()}
	var json_size := _be_u32(payload, 0)
	var json_start := 4
	var json_end := json_start + json_size
	if json_end > payload.size():
		return {"metadata": {}, "binary": PackedByteArray()}
	var metadata := _json_payload(payload.slice(json_start, json_end))
	return {
		"metadata": metadata,
		"binary": payload.slice(json_end)
	}


func _looks_like_json(payload: PackedByteArray) -> bool:
	return payload.size() > 0 and payload[0] == 123


func _be_u16(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 8) | bytes[offset + 1]


func _be_u32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]


func _be_u64(bytes: PackedByteArray, offset: int) -> int:
	var value := 0
	for i in range(8):
		value = (value << 8) | bytes[offset + i]
	return value
