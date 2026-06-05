class_name LivePullDenseMapView
extends Node3D

signal chunk_rendered(chunk_id: String, point_count: int)

const LivePullClientScript := preload("res://addons/live-pull/live_pull_client.gd")

@export var result_host := "127.0.0.1"
@export var result_port := 63912
@export var connect_on_ready := false
@export var max_points_per_chunk := 120000
@export var auto_create_client := true

var client: LivePullClient
var _chunks: Dictionary = {}
var _material: StandardMaterial3D
var _unsupported_encodings: Dictionary = {}


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.no_depth_test = false
	_ensure_client()
	if connect_on_ready:
		connect_to_server(result_host, result_port)


func connect_to_server(host: String = result_host, port: int = result_port) -> void:
	result_host = host
	result_port = port
	_ensure_client()
	client.connect_result(result_host, result_port)


func disconnect_from_server() -> void:
	if client != null:
		client.disconnect_result()


func _ensure_client() -> void:
	if client != null or not auto_create_client:
		return
	client = LivePullClientScript.new()
	client.name = "LivePullClient"
	add_child(client)
	client.dense_chunk_ready.connect(_on_dense_chunk_ready)
	client.map_reset_received.connect(_on_map_reset)
	client.map_transform_received.connect(_on_map_transform)


func _on_map_reset(_reset: Dictionary) -> void:
	for child in _chunks.values():
		if child is Node:
			(child as Node).queue_free()
	_chunks.clear()


func _on_map_transform(message: Dictionary) -> void:
	if message.has("T_openxr_map"):
		transform = _matrix_to_transform(message["T_openxr_map"])


func _on_dense_chunk_ready(metadata: Dictionary, payload: PackedByteArray) -> void:
	if metadata.has("T_openxr_map"):
		transform = _matrix_to_transform(metadata["T_openxr_map"])
	var operation := str(metadata.get("operation", "upsert"))
	var chunk_id := str(metadata.get("chunk_id", "chunk_%d" % _chunks.size()))
	if operation == "delete":
		_delete_chunk(chunk_id)
		return
	var decoded := _decode_points(metadata, payload)
	var vertices: PackedVector3Array = decoded["vertices"]
	var colors: PackedColorArray = decoded["colors"]
	if vertices.is_empty():
		return
	_upsert_chunk(chunk_id, vertices, colors)
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


func _delete_chunk(chunk_id: String) -> void:
	if not _chunks.has(chunk_id):
		return
	var node: Node = _chunks[chunk_id]
	_chunks.erase(chunk_id)
	if node != null:
		node.queue_free()


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
