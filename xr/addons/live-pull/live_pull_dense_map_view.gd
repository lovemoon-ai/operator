class_name LivePullDenseMapView
extends Node3D

signal chunk_rendered(chunk_id: String, point_count: int)
signal connected_to_server(host: String, port: int)
signal disconnected_from_server(host: String, port: int)
signal connection_failed(host: String, port: int, reason: String)
signal connection_status_changed(status: String, detail: String)

const LivePullClientScript := preload("res://addons/live-pull/live_pull_client.gd")

@export var result_host := "127.0.0.1"
@export var result_port := 63912
@export var connect_on_ready := false
@export var max_points_per_chunk := 120000
@export var max_rendered_chunks := 64
@export var max_rendered_points := 1200000
@export var auto_create_client := true
@export var reconnect_enabled := true
@export var reconnect_delay_s := 1.0

@export_group("Display")
## When true, ignore the server's T_openxr_map (which puts the cloud at real
## 1:1 world scale where it was captured) and render the dense map as a
## scaled-down view-anchored "minimap" in front of the user instead. Useful
## for previewing a live VGGT-SLAM reconstruction without standing inside it.
##
## When the minimap is on:
##   * scale     = display_scale (uniform)
##   * position  = HMD position + horizontal heading * display_distance,
##                 with Y = HMD.y - display_height_below_head
##   * rotation  = the latest T_openxr_map basis (world-aligned; does NOT
##                 follow head rotation, so the cloud's heading stays stable
##                 even when the user turns)
@export var display_as_minimap := true
## Uniform scale applied in minimap mode. 1.0 means real-world size; 0.2
## means a 5m room renders as a 1m model (5:1 shrink — the default).
@export var display_scale := 0.2
## Horizontal distance, in meters, from the HMD to the minimap centre along
## the user's current yaw (head forward projected onto the XZ plane).
@export var display_distance := 1.0
## Vertical drop, in meters, of the minimap centre relative to the HMD
## position. 0.3 puts it ~30cm below eye level so it sits in the natural
## reading zone without occluding straight-ahead view.
@export var display_height_below_head := 0.3
## Scene path to the XRCamera3D used as the view anchor. May also be
## assigned at runtime via the `head_lock_target` property.
@export var head_lock_target_path: NodePath

var client: LivePullClient
var head_lock_target: Node3D
var _chunks: Dictionary = {}
var _chunk_point_counts: Dictionary = {}
var _chunk_order: Array[String] = []
var _rendered_point_count := 0
var _material: StandardMaterial3D
var _unsupported_encodings: Dictionary = {}
var _want_connection := false
var _retry_pending := false
var _retry_after_s := 0.0
# Latest world-aligned rotation reported by the server via T_openxr_map. We
# only keep the basis (rotation) because position/scale are overridden by the
# view-anchored placement computed each frame in `_process`.
var _map_basis: Basis = Basis.IDENTITY
# Cached horizontal forward used when the user looks straight up/down and the
# instantaneous head forward has no usable XZ component.
var _last_horizontal_forward: Vector3 = Vector3(0.0, 0.0, -1.0)


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.no_depth_test = false
	_ensure_client()
	if head_lock_target == null and head_lock_target_path != NodePath():
		head_lock_target = get_node_or_null(head_lock_target_path) as Node3D
	if display_as_minimap and head_lock_target != null:
		# Lay down a first transform so the cloud doesn't briefly appear at
		# the XR origin before the first `_process` tick.
		_refresh_view_anchored_transform()
	if connect_on_ready:
		connect_to_server(result_host, result_port)


func _process(delta: float) -> void:
	# Re-anchor the minimap to the user's view every frame: horizontal position
	# follows head yaw, vertical position drops by display_height_below_head,
	# rotation stays aligned with T_openxr_map (so the captured world doesn't
	# spin when the user turns).
	if display_as_minimap and head_lock_target != null:
		_refresh_view_anchored_transform()
	if not _want_connection or client == null or not reconnect_enabled:
		return
	if client.is_result_active():
		return
	if not _retry_pending:
		_schedule_reconnect("disconnected")
		return
	_retry_after_s -= delta
	if _retry_after_s <= 0.0:
		_retry_pending = false
		_connect_client("retry")


func connect_to_server(host: String = result_host, port: int = result_port) -> void:
	result_host = host
	result_port = port
	_ensure_client()
	_want_connection = true
	_retry_pending = false
	if client.is_result_active() and client.host == result_host and client.port == result_port:
		print("Live-pull already %s: %s:%d" % [client.get_connection_state(), result_host, result_port])
		return
	_connect_client("start")


func disconnect_from_server() -> void:
	_want_connection = false
	_retry_pending = false
	if client != null:
		client.disconnect_result()


func _ensure_client() -> void:
	if client != null or not auto_create_client:
		return
	client = LivePullClientScript.new()
	client.name = "LivePullClient"
	add_child(client)
	client.connected_to_server.connect(_on_connected_to_server)
	client.disconnected_from_server.connect(_on_disconnected_from_server)
	client.connection_failed.connect(_on_connection_failed)
	client.status_received.connect(_on_status_received)
	client.manifest_received.connect(_on_manifest_received)
	client.dense_chunk_ready.connect(_on_dense_chunk_ready)
	client.dense_commit_received.connect(_on_dense_commit_received)
	client.trajectory_received.connect(_on_trajectory_received)
	client.map_reset_received.connect(_on_map_reset)
	client.map_transform_received.connect(_on_map_transform)


func _on_connected_to_server() -> void:
	_retry_pending = false
	print("Live-pull connected: %s:%d" % [result_host, result_port])
	connected_to_server.emit(result_host, result_port)
	connection_status_changed.emit("connected", "%s:%d" % [result_host, result_port])


func _on_disconnected_from_server() -> void:
	print("Live-pull disconnected: %s:%d" % [result_host, result_port])
	disconnected_from_server.emit(result_host, result_port)
	connection_status_changed.emit("disconnected", "%s:%d" % [result_host, result_port])
	if _want_connection:
		_schedule_reconnect("socket disconnected")


func _on_connection_failed(reason: String) -> void:
	push_warning("Live-pull connection failed %s:%d: %s" % [result_host, result_port, reason])
	connection_failed.emit(result_host, result_port, reason)
	connection_status_changed.emit("failed", reason)
	if _want_connection:
		_schedule_reconnect(reason)


func _on_status_received(status: Dictionary) -> void:
	print("Live-pull status: %s" % JSON.stringify(status))


func _on_manifest_received(manifest: Dictionary) -> void:
	print("Live-pull manifest map_version=%d chunks=%d" % [
		int(manifest.get("map_version", -1)),
		_array_size(manifest.get("chunks", []))
	])


func _on_dense_commit_received(commit: Dictionary) -> void:
	print("Live-pull commit map_version=%d chunks=%d" % [
		int(commit.get("map_version", -1)),
		_array_size(commit.get("committed_chunks", []))
	])


func _on_trajectory_received(trajectory: Dictionary) -> void:
	print("Live-pull trajectory poses=%d" % [
		_array_size(trajectory.get("poses", []))
	])


func _on_map_reset(_reset: Dictionary) -> void:
	print("Live-pull map reset")
	for child in _chunks.values():
		if child is Node:
			(child as Node).queue_free()
	_chunks.clear()
	_chunk_point_counts.clear()
	_chunk_order.clear()
	_rendered_point_count = 0


func _on_map_transform(message: Dictionary) -> void:
	if message.has("T_openxr_map"):
		_apply_map_pose(message["T_openxr_map"])
	print("Live-pull map transform received")


func _on_dense_chunk_ready(metadata: Dictionary, payload: PackedByteArray) -> void:
	if metadata.has("T_openxr_map"):
		_apply_map_pose(metadata["T_openxr_map"])
	var operation := str(metadata.get("operation", "upsert"))
	var chunk_id := str(metadata.get("chunk_id", "chunk_%d" % _chunks.size()))
	if operation == "delete":
		_delete_chunk(chunk_id)
		return
	var decoded := _decode_points(metadata, payload)
	var vertices: PackedVector3Array = decoded["vertices"]
	var colors: PackedColorArray = decoded["colors"]
	if vertices.is_empty():
		print("Live-pull dense chunk skipped: %s bytes=%d encoding=%s" % [
			chunk_id,
			payload.size(),
			str(metadata.get("encoding", metadata.get("point_format", "")))
		])
		return
	_upsert_chunk(chunk_id, vertices, colors)
	print("Live-pull rendered chunk: %s points=%d bytes=%d" % [chunk_id, vertices.size(), payload.size()])
	chunk_rendered.emit(chunk_id, vertices.size())


func _upsert_chunk(chunk_id: String, vertices: PackedVector3Array, colors: PackedColorArray) -> void:
	_delete_chunk(chunk_id)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var instance := MeshInstance3D.new()
	instance.name = chunk_id
	instance.mesh = mesh
	instance.material_override = _material
	add_child(instance)
	_chunks[chunk_id] = instance
	_chunk_point_counts[chunk_id] = vertices.size()
	_chunk_order.append(chunk_id)
	_rendered_point_count += vertices.size()
	_enforce_render_budget()


func _delete_chunk(chunk_id: String) -> void:
	if not _chunks.has(chunk_id):
		return
	var node: Node = _chunks[chunk_id]
	_chunks.erase(chunk_id)
	_rendered_point_count = maxi(0, _rendered_point_count - int(_chunk_point_counts.get(chunk_id, 0)))
	_chunk_point_counts.erase(chunk_id)
	_chunk_order.erase(chunk_id)
	if node != null:
		node.queue_free()


func _enforce_render_budget() -> void:
	while max_rendered_chunks > 0 and _chunks.size() > max_rendered_chunks and not _chunk_order.is_empty():
		_delete_chunk(_chunk_order[0])
	while max_rendered_points > 0 and _rendered_point_count > max_rendered_points and not _chunk_order.is_empty():
		_delete_chunk(_chunk_order[0])


func _decode_points(metadata: Dictionary, payload: PackedByteArray) -> Dictionary:
	var point_format := str(metadata.get("point_format", ""))
	var encoding := str(metadata.get("encoding", point_format))
	if point_format == "f32xyz_u8rgba_f32conf" or encoding == "f32xyz_u8rgba_f32conf":
		return _decode_f32_points(metadata, payload)
	if encoding.begins_with("quantized_u16xyz_rgba8_conf8"):
		if encoding.ends_with("_zstd") or str(metadata.get("payload_encoding", "")) == "zstd":
			_warn_unsupported_once(encoding)
			return _empty_points()
		return _decode_quantized_points(metadata, payload)
	_warn_unsupported_once(encoding)
	return _empty_points()


func _decode_f32_points(metadata: Dictionary, payload: PackedByteArray) -> Dictionary:
	var stride := int(metadata.get("point_stride_bytes", 20))
	var available_count := int(payload.size() / maxi(1, stride))
	var declared_count := int(metadata.get("point_count", available_count))
	var count := mini(mini(declared_count, available_count), max_points_per_chunk)
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(count)
	colors.resize(count)
	for i in range(count):
		var offset := i * stride
		vertices[i] = Vector3(
			payload.decode_float(offset),
			payload.decode_float(offset + 4),
			payload.decode_float(offset + 8)
		)
		colors[i] = Color8(
			payload[offset + 12],
			payload[offset + 13],
			payload[offset + 14],
			payload[offset + 15]
		)
	return {"vertices": vertices, "colors": colors}


func _decode_quantized_points(metadata: Dictionary, payload: PackedByteArray) -> Dictionary:
	var stride := int(metadata.get("point_stride_bytes", 11))
	var available_count := int(payload.size() / maxi(1, stride))
	var declared_count := int(metadata.get("point_count", available_count))
	var count := mini(mini(declared_count, available_count), max_points_per_chunk)
	var aabb_min := _vector_from_array(metadata.get("aabb_min", [0.0, 0.0, 0.0]))
	var aabb_max := _vector_from_array(metadata.get("aabb_max", [1.0, 1.0, 1.0]))
	var extent := aabb_max - aabb_min
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(count)
	colors.resize(count)
	for i in range(count):
		var offset := i * stride
		var qx := _le_u16(payload, offset)
		var qy := _le_u16(payload, offset + 2)
		var qz := _le_u16(payload, offset + 4)
		vertices[i] = aabb_min + Vector3(
			float(qx) / 65535.0 * extent.x,
			float(qy) / 65535.0 * extent.y,
			float(qz) / 65535.0 * extent.z
		)
		colors[i] = Color8(
			payload[offset + 6],
			payload[offset + 7],
			payload[offset + 8],
			payload[offset + 9]
		)
	return {"vertices": vertices, "colors": colors}


## Switch between view-anchored minimap rendering and world-aligned
## (T_openxr_map) rendering at runtime, and optionally retune the minimap
## parameters. Pass NAN to keep the current value of a given field.
func set_minimap_display(
	enabled: bool,
	scale_override: float = NAN,
	distance_override: float = NAN,
	height_below_head_override: float = NAN
) -> void:
	display_as_minimap = enabled
	if not is_nan(scale_override):
		display_scale = scale_override
	if not is_nan(distance_override):
		display_distance = distance_override
	if not is_nan(height_below_head_override):
		display_height_below_head = height_below_head_override
	if display_as_minimap and head_lock_target != null:
		_refresh_view_anchored_transform()


func _apply_map_pose(matrix: Variant) -> void:
	var server_xform := _matrix_to_transform(matrix)
	if display_as_minimap:
		# In view-anchored mode the world-locked pose is ignored for position
		# and scale — but we keep its rotation so the cloud's heading still
		# matches the captured world (north stays north when the user turns).
		_map_basis = server_xform.basis
		if head_lock_target != null:
			_refresh_view_anchored_transform()
	else:
		transform = server_xform


## Re-compute and apply the view-anchored transform from the current HMD
## pose. Safe to call multiple times per frame; cheap (no allocations).
func _refresh_view_anchored_transform() -> void:
	if head_lock_target == null:
		return
	var head: Transform3D = head_lock_target.transform
	# OpenXR cameras look down -Z. Project onto XZ for yaw-only forward.
	var forward := -head.basis.z
	var horiz := Vector3(forward.x, 0.0, forward.z)
	if horiz.length_squared() < 0.000001:
		# User is staring almost straight up or down; reuse the last good yaw
		# so the minimap doesn't snap to the origin.
		horiz = _last_horizontal_forward
	else:
		horiz = horiz.normalized()
		_last_horizontal_forward = horiz
	var anchor_pos := Vector3(
		head.origin.x + horiz.x * display_distance,
		head.origin.y - display_height_below_head,
		head.origin.z + horiz.z * display_distance
	)
	var basis := _map_basis.scaled(Vector3.ONE * maxf(display_scale, 0.0001))
	transform = Transform3D(basis, anchor_pos)


func _matrix_to_transform(value: Variant) -> Transform3D:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() < 4:
		return Transform3D.IDENTITY
	var rows: Array = value
	var basis := Basis(
		Vector3(float(rows[0][0]), float(rows[1][0]), float(rows[2][0])),
		Vector3(float(rows[0][1]), float(rows[1][1]), float(rows[2][1])),
		Vector3(float(rows[0][2]), float(rows[1][2]), float(rows[2][2]))
	)
	var origin := Vector3(float(rows[0][3]), float(rows[1][3]), float(rows[2][3]))
	return Transform3D(basis, origin)


func _vector_from_array(value: Variant) -> Vector3:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() < 3:
		return Vector3.ZERO
	var items: Array = value
	return Vector3(float(items[0]), float(items[1]), float(items[2]))


func _array_size(value: Variant) -> int:
	if typeof(value) != TYPE_ARRAY:
		return 0
	return (value as Array).size()


func _connect_client(reason: String) -> void:
	if client == null:
		return
	print("Live-pull connecting to %s:%d (%s)" % [result_host, result_port, reason])
	connection_status_changed.emit("connecting", "%s:%d" % [result_host, result_port])
	client.connect_result(result_host, result_port)


func _schedule_reconnect(reason: String) -> void:
	if not reconnect_enabled:
		return
	_retry_pending = true
	_retry_after_s = maxf(reconnect_delay_s, 0.05)
	print("Live-pull reconnect scheduled in %.2fs: %s" % [_retry_after_s, reason])
	connection_status_changed.emit("retrying", reason)


func _le_u16(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8)


func _warn_unsupported_once(encoding: String) -> void:
	if _unsupported_encodings.has(encoding):
		return
	_unsupported_encodings[encoding] = true
	push_warning("live-pull cannot render dense map encoding yet: %s" % encoding)


func _empty_points() -> Dictionary:
	return {
		"vertices": PackedVector3Array(),
		"colors": PackedColorArray()
	}
