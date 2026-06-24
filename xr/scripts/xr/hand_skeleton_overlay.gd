class_name HandSkeletonOverlay
extends Node3D

## Runtime-only XR hand skeleton overlay.
##
## This node renders XRHandTracker joints directly into the OpenXR scene so the
## operator can visually inspect hand-keypoint alignment in passthrough/VST.
## It does not feed the RGB capture path and is intentionally not part of the
## saved SpatialMP4 data.

const LEFT_HAND_TRACKER := &"/user/hand_tracker/left"
const RIGHT_HAND_TRACKER := &"/user/hand_tracker/right"
const POSITION_VALID_FLAG := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID

const HAND_JOINT_PALM := 0
const HAND_JOINT_WRIST := 1
const HAND_JOINT_THUMB_METACARPAL := 2
const HAND_JOINT_THUMB_PROXIMAL := 3
const HAND_JOINT_THUMB_DISTAL := 4
const HAND_JOINT_THUMB_TIP := 5
const HAND_JOINT_INDEX_METACARPAL := 6
const HAND_JOINT_INDEX_PROXIMAL := 7
const HAND_JOINT_INDEX_INTERMEDIATE := 8
const HAND_JOINT_INDEX_DISTAL := 9
const HAND_JOINT_INDEX_TIP := 10
const HAND_JOINT_MIDDLE_METACARPAL := 11
const HAND_JOINT_MIDDLE_PROXIMAL := 12
const HAND_JOINT_MIDDLE_INTERMEDIATE := 13
const HAND_JOINT_MIDDLE_DISTAL := 14
const HAND_JOINT_MIDDLE_TIP := 15
const HAND_JOINT_RING_METACARPAL := 16
const HAND_JOINT_RING_PROXIMAL := 17
const HAND_JOINT_RING_INTERMEDIATE := 18
const HAND_JOINT_RING_DISTAL := 19
const HAND_JOINT_RING_TIP := 20
const HAND_JOINT_LITTLE_METACARPAL := 21
const HAND_JOINT_LITTLE_PROXIMAL := 22
const HAND_JOINT_LITTLE_INTERMEDIATE := 23
const HAND_JOINT_LITTLE_DISTAL := 24
const HAND_JOINT_LITTLE_TIP := 25

const HAND_BONES: Array[Array] = [
	[HAND_JOINT_WRIST, HAND_JOINT_PALM],
	[HAND_JOINT_PALM, HAND_JOINT_THUMB_METACARPAL],
	[HAND_JOINT_THUMB_METACARPAL, HAND_JOINT_THUMB_PROXIMAL],
	[HAND_JOINT_THUMB_PROXIMAL, HAND_JOINT_THUMB_DISTAL],
	[HAND_JOINT_THUMB_DISTAL, HAND_JOINT_THUMB_TIP],
	[HAND_JOINT_PALM, HAND_JOINT_INDEX_METACARPAL],
	[HAND_JOINT_INDEX_METACARPAL, HAND_JOINT_INDEX_PROXIMAL],
	[HAND_JOINT_INDEX_PROXIMAL, HAND_JOINT_INDEX_INTERMEDIATE],
	[HAND_JOINT_INDEX_INTERMEDIATE, HAND_JOINT_INDEX_DISTAL],
	[HAND_JOINT_INDEX_DISTAL, HAND_JOINT_INDEX_TIP],
	[HAND_JOINT_PALM, HAND_JOINT_MIDDLE_METACARPAL],
	[HAND_JOINT_MIDDLE_METACARPAL, HAND_JOINT_MIDDLE_PROXIMAL],
	[HAND_JOINT_MIDDLE_PROXIMAL, HAND_JOINT_MIDDLE_INTERMEDIATE],
	[HAND_JOINT_MIDDLE_INTERMEDIATE, HAND_JOINT_MIDDLE_DISTAL],
	[HAND_JOINT_MIDDLE_DISTAL, HAND_JOINT_MIDDLE_TIP],
	[HAND_JOINT_PALM, HAND_JOINT_RING_METACARPAL],
	[HAND_JOINT_RING_METACARPAL, HAND_JOINT_RING_PROXIMAL],
	[HAND_JOINT_RING_PROXIMAL, HAND_JOINT_RING_INTERMEDIATE],
	[HAND_JOINT_RING_INTERMEDIATE, HAND_JOINT_RING_DISTAL],
	[HAND_JOINT_RING_DISTAL, HAND_JOINT_RING_TIP],
	[HAND_JOINT_PALM, HAND_JOINT_LITTLE_METACARPAL],
	[HAND_JOINT_LITTLE_METACARPAL, HAND_JOINT_LITTLE_PROXIMAL],
	[HAND_JOINT_LITTLE_PROXIMAL, HAND_JOINT_LITTLE_INTERMEDIATE],
	[HAND_JOINT_LITTLE_INTERMEDIATE, HAND_JOINT_LITTLE_DISTAL],
	[HAND_JOINT_LITTLE_DISTAL, HAND_JOINT_LITTLE_TIP],
]

@export var joint_radius_m := 0.009

var _enabled := false
var _xr_origin: XROrigin3D = null
var _line_mesh: ImmediateMesh
var _line_instance: MeshInstance3D
var _left_positions: Array = []
var _right_positions: Array = []
var _left_valid: Array = []
var _right_valid: Array = []
var _left_joint_nodes: Array = []
var _right_joint_nodes: Array = []
var _left_line_material: StandardMaterial3D
var _right_line_material: StandardMaterial3D
var _left_point_material: StandardMaterial3D
var _right_point_material: StandardMaterial3D


func _ready() -> void:
	_build_materials()
	_build_line_mesh()
	_build_joint_markers()
	_reset_joint_arrays()
	set_enabled(false)


func set_xr_origin(xr_origin: XROrigin3D) -> void:
	_xr_origin = xr_origin


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value
	set_process(value)
	if not value:
		_clear_render()


func _process(_delta: float) -> void:
	if not _enabled:
		return
	_redraw()


func _build_materials() -> void:
	_left_line_material = _make_material(Color(0.10, 0.78, 1.00, 0.92))
	_right_line_material = _make_material(Color(1.00, 0.62, 0.10, 0.92))
	_left_point_material = _make_material(Color(0.35, 0.92, 1.00, 0.96))
	_right_point_material = _make_material(Color(1.00, 0.78, 0.30, 0.96))


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 0.85
	mat.no_depth_test = true
	mat.render_priority = 5
	return mat


func _build_line_mesh() -> void:
	_line_mesh = ImmediateMesh.new()
	_line_instance = MeshInstance3D.new()
	_line_instance.name = "HandSkeletonLines"
	_line_instance.mesh = _line_mesh
	_line_instance.extra_cull_margin = 2.0
	add_child(_line_instance)


func _build_joint_markers() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = joint_radius_m
	sphere.height = joint_radius_m * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		_left_joint_nodes.append(_make_joint_marker("LeftHandJoint_%02d" % joint, sphere, _left_point_material))
		_right_joint_nodes.append(_make_joint_marker("RightHandJoint_%02d" % joint, sphere, _right_point_material))


func _make_joint_marker(node_name: String, mesh: Mesh, material: Material) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	marker.name = node_name
	marker.mesh = mesh
	marker.visible = false
	marker.extra_cull_margin = 0.2
	marker.set_surface_override_material(0, material)
	add_child(marker)
	return marker


func _reset_joint_arrays() -> void:
	_left_positions.resize(XRHandTracker.HAND_JOINT_MAX)
	_right_positions.resize(XRHandTracker.HAND_JOINT_MAX)
	_left_valid.resize(XRHandTracker.HAND_JOINT_MAX)
	_right_valid.resize(XRHandTracker.HAND_JOINT_MAX)
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		_left_positions[joint] = Vector3.ZERO
		_right_positions[joint] = Vector3.ZERO
		_left_valid[joint] = false
		_right_valid[joint] = false


func _redraw() -> void:
	var left_active := _sample_hand(LEFT_HAND_TRACKER, _left_positions, _left_valid, _left_joint_nodes)
	var right_active := _sample_hand(RIGHT_HAND_TRACKER, _right_positions, _right_valid, _right_joint_nodes)
	_line_mesh.clear_surfaces()
	if left_active:
		_draw_hand_lines(_left_positions, _left_valid, _left_line_material)
	if right_active:
		_draw_hand_lines(_right_positions, _right_valid, _right_line_material)


func _sample_hand(
	tracker_name: StringName,
	positions: Array,
	valid: Array,
	joint_nodes: Array
) -> bool:
	var tracker := XRServer.get_tracker(tracker_name)
	var active := false
	if tracker is XRHandTracker:
		var hand_tracker := tracker as XRHandTracker
		active = hand_tracker.has_tracking_data \
				and hand_tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
		if active:
			for joint in range(XRHandTracker.HAND_JOINT_MAX):
				var local_transform := hand_tracker.get_hand_joint_transform(joint)
				var flags := int(hand_tracker.get_hand_joint_flags(joint))
				var position := _to_overlay_local(local_transform.origin)
				var joint_valid := _joint_has_valid_position(flags, local_transform.origin)
				positions[joint] = position
				valid[joint] = joint_valid
				var marker: MeshInstance3D = joint_nodes[joint]
				marker.position = position
				marker.visible = joint_valid
			return true

	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		valid[joint] = false
		var marker: MeshInstance3D = joint_nodes[joint]
		marker.visible = false
	return false


func _to_overlay_local(xr_local_position: Vector3) -> Vector3:
	if _xr_origin != null and get_parent() != _xr_origin:
		var world_position := _xr_origin.global_transform * xr_local_position
		return global_transform.affine_inverse() * world_position
	return xr_local_position


func _joint_has_valid_position(flags: int, local_position: Vector3) -> bool:
	if (flags & POSITION_VALID_FLAG) != 0:
		return true
	# Pico has historically returned real optical hand positions with zero
	# flags. Keep that compatibility path, but do not accept orientation-only
	# or velocity-only flags as valid positions.
	return flags == 0 and local_position.length_squared() > 0.000001


func _draw_hand_lines(positions: Array, valid: Array, material: Material) -> void:
	var vertices: Array = []
	for link_v in HAND_BONES:
		var link := link_v as Array
		var a := int(link[0])
		var b := int(link[1])
		if a >= valid.size() or b >= valid.size() or not bool(valid[a]) or not bool(valid[b]):
			continue
		var pa: Vector3 = positions[a]
		var pb: Vector3 = positions[b]
		if pa.distance_to(pb) > 0.18:
			continue
		vertices.append(pa)
		vertices.append(pb)
	if vertices.is_empty():
		return
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for vertex_v in vertices:
		_line_mesh.surface_add_vertex(vertex_v as Vector3)
	_line_mesh.surface_end()


func _clear_render() -> void:
	if _line_mesh != null:
		_line_mesh.clear_surfaces()
	for marker_v in _left_joint_nodes:
		var marker := marker_v as MeshInstance3D
		marker.visible = false
	for marker_v in _right_joint_nodes:
		var marker := marker_v as MeshInstance3D
		marker.visible = false
