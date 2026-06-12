class_name H2Overlay
extends Node3D

## In-headset rest-state overlay of the H2 robot for visual debugging.
## It loads the baked GLB, tints it translucent, and world-locks it one
## metre in front of the operator's current view.

const GLB_PATH := "res://assets/robots/h2_with_sharpa.glb"

## Optional override — pass a Node3D you want to mount the robot under.
## Defaults to ``self`` (the overlay node itself).
@export var attach_under: NodePath

## Place the whole H2 overlay one metre in front of the HMD once, then
## keep it world-locked.
@export var debug_place_in_front_of_view: bool = true
@export var debug_front_distance_m: float = 1.0
@export var debug_front_vertical_offset_m: float = -0.15

## Render the meshes with a semi-transparent material so the overlay
## doesn't fully occlude passthrough.
@export var overlay_alpha: float = 0.55
@export var overlay_tint: Color = Color(0.65, 0.78, 1.0, 1.0)

# --- Loaded GLB nodes -----------------------------------------------------

# link_name -> Node3D mounted in the scene tree. Populated by walking the
# GLB's children at _ready().
var _link_nodes: Dictionary = {}
# Override-applied materials. Stored so future tint changes do not need
# to walk the tree again.
var _overlay_materials: Array = []  # Array[StandardMaterial3D]

# --- Anchoring ------------------------------------------------------------

var _pelvis_node: Node3D = null
var _pelvis_rest_transform: Transform3D = Transform3D.IDENTITY
var _head_camera: Node3D = null
var _debug_front_locked: bool = false


func _ready() -> void:
	if not ResourceLoader.exists(GLB_PATH):
		push_error("[H2Overlay] GLB not found at %s. Run tools/retargeting/scripts/build_h2_glb.py to produce it." % GLB_PATH)
		return
	_load_glb()
	if _pelvis_node == null:
		push_error("[H2Overlay] GLB did not contain a 'pelvis' node; overlay disabled.")
		return
	_apply_overlay_material()
	if debug_place_in_front_of_view:
		call_deferred("_lock_in_front_of_view")
	print("[H2Overlay] ready: %d link nodes" % _link_nodes.size())


func _process(_delta: float) -> void:
	if debug_place_in_front_of_view and not _debug_front_locked:
		_lock_in_front_of_view()


func set_head_camera(camera: Node3D) -> void:
	_head_camera = camera
	if is_inside_tree() and debug_place_in_front_of_view and not _debug_front_locked:
		call_deferred("_lock_in_front_of_view")


# --- GLB load --------------------------------------------------------------


func _load_glb() -> void:
	var packed: PackedScene = load(GLB_PATH)
	if packed == null:
		push_error("[H2Overlay] failed to load GLB: %s" % GLB_PATH)
		return
	var instance: Node = packed.instantiate()
	var parent: Node3D = self
	if not attach_under.is_empty():
		var target := get_node_or_null(attach_under)
		if target is Node3D:
			parent = target
	parent.add_child(instance)

	# The trimesh exporter wraps everything in a synthetic "world" root.
	# Walk past it to find the actual pelvis. We index every Node3D by
	# its name (which trimesh set to the URDF link name).
	_index_subtree(instance)
	_pelvis_node = _link_nodes.get("pelvis", null)


func _index_subtree(node: Node) -> void:
	if node is Node3D:
		var name := node.name
		if name != "" and not _link_nodes.has(name):
			var n3 := node as Node3D
			_link_nodes[name] = n3
			if name == "pelvis":
				_pelvis_rest_transform = n3.transform
	for child in node.get_children():
		_index_subtree(child)


# --- Material ------------------------------------------------------------


func _apply_overlay_material() -> void:
	# Build one StandardMaterial3D and share it across every mesh
	# instance. They're all set to the same translucent tint so the
	# operator sees "the robot" rather than "20 disconnected shells".
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = overlay_tint
	mat.albedo_color.a = overlay_alpha
	mat.metallic = 0.05
	mat.roughness = 0.55
	# Slight emission keeps the overlay legible against the operator's
	# real environment when seen through Quest / Pico passthrough.
	mat.emission_enabled = true
	mat.emission = overlay_tint
	mat.emission_energy_multiplier = 0.2
	for link_name in _link_nodes:
		_apply_material_to_meshes(_link_nodes[link_name], mat)
	_overlay_materials = [mat]


func _apply_material_to_meshes(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var n := mi.get_surface_override_material_count()
		for i in range(n):
			mi.set_surface_override_material(i, mat)
		# If the GLB came in with surface count = 0 (single-surface
		# mesh, no override yet), fall back to setting the material on
		# the mesh's first surface via surface_override_material(0).
		if n == 0 and mi.mesh != null:
			mi.set_surface_override_material(0, mat)
	for child in node.get_children():
		_apply_material_to_meshes(child, mat)


func _lock_in_front_of_view() -> bool:
	if _debug_front_locked:
		return true
	if _head_camera == null or _pelvis_node == null:
		return false
	var camera_xf := _head_camera.global_transform
	var basis := camera_xf.basis.orthonormalized()
	var forward := -basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var yaw := atan2(-forward.x, -forward.z)
	var anchor := camera_xf.origin + forward * debug_front_distance_m
	anchor.y += debug_front_vertical_offset_m
	var operator_xform := Transform3D(Basis(Vector3.UP, yaw), anchor)
	_pelvis_node.global_transform = operator_xform * _pelvis_rest_transform
	_debug_front_locked = true
	return true
