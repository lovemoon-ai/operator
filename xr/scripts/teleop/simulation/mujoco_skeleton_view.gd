class_name MujocoSkeletonView
extends Node3D
## Lightweight in-headset visualization driven by MuJoCo body transforms. It is
## deliberately model-agnostic and remains useful when mesh assets are absent.

var simulation: Node
var head_camera: Node3D
var _body_nodes: Dictionary = {}
var _line_mesh: ImmediateMesh
var _locked := false


func configure(value: Node, camera: Node3D) -> void:
	simulation = value
	head_camera = camera
	call_deferred("_build")


func _build() -> void:
	if simulation == null or simulation.model == null:
		call_deferred("_build")
		return
	for body_name in simulation.model.body_names:
		var sphere := MeshInstance3D.new()
		sphere.name = "Body_%s" % str(body_name)
		var mesh := SphereMesh.new()
		mesh.radius = 0.018
		mesh.height = 0.036
		sphere.mesh = mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.25, 0.78, 1.0, 0.85)
		material.emission_enabled = true
		material.emission = Color(0.05, 0.28, 0.5)
		sphere.material_override = material
		add_child(sphere)
		_body_nodes[str(body_name)] = sphere
	_line_mesh = ImmediateMesh.new()
	var lines := MeshInstance3D.new()
	lines.name = "Links"
	lines.mesh = _line_mesh
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.albedo_color = Color(0.2, 0.7, 1.0, 0.75)
	lines.material_override = line_material
	add_child(lines)
	_lock_in_front()


func _process(_delta: float) -> void:
	if simulation == null or simulation.model == null or _body_nodes.is_empty():
		return
	if not _locked:
		_lock_in_front()
	var points: Array[Vector3] = []
	for body_name in simulation.model.body_names:
		var body_transform: Transform3D = simulation.call("get_body_transform", str(body_name))
		var point: Vector3 = body_transform.origin
		points.append(point)
		var node: Node3D = _body_nodes.get(str(body_name), null)
		if node != null:
			node.position = point
	if _line_mesh == null:
		return
	_line_mesh.clear_surfaces()
	if points.size() < 2:
		return
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var parent_names: PackedStringArray = simulation.model.metadata.get(
		"body_parent_names", PackedStringArray()
	)
	for i in range(1, points.size()):
		var parent_index := i - 1
		if i < parent_names.size():
			parent_index = simulation.model.body_names.find(parent_names[i])
		if parent_index < 0 or parent_index >= points.size():
			continue
		_line_mesh.surface_add_vertex(points[parent_index])
		_line_mesh.surface_add_vertex(points[i])
	_line_mesh.surface_end()


func _lock_in_front() -> void:
	if head_camera == null:
		return
	var camera_xf := head_camera.global_transform
	var forward := -camera_xf.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var yaw := atan2(-forward.x, -forward.z)
	global_transform = Transform3D(
		Basis(Vector3.UP, yaw), camera_xf.origin + forward * 0.9 + Vector3(0.0, -0.35, 0.0)
	)
	_locked = true
