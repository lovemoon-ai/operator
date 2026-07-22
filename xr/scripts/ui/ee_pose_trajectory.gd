class_name EEPoseTrajectory
extends Node3D
## World-space trail for the end-effector poses actually sent to the robot.
##
## Device descriptors may name their pose targets freely, so this node derives
## the targets from input_mapping instead of assuming `end_effector`.  A pose
## sourced from `active_controller_pose` follows ControlMode's driving hand;
## explicit left/right sources keep independent trails for dual-arm robots.

const HAND_LEFT := 0
const HAND_RIGHT := 1
const ACTIVE_HAND := -1

const LEFT_COLOR := Color(0.10, 0.78, 1.00, 0.92)
const RIGHT_COLOR := Color(1.00, 0.62, 0.10, 0.92)
const MARKER_RADIUS_M := 0.009

@export_range(0.002, 0.1, 0.001) var min_point_distance_m := 0.01
@export_range(16, 2048, 1) var max_points_per_hand := 600
@export_range(1, 16, 1) var max_segments_per_hand := 2

var _enabled := false
var _target_hands: Dictionary = {}  # DeviceCommand pose target -> hand / ACTIVE_HAND
var _points := {HAND_LEFT: [], HAND_RIGHT: []}
var _connect_to_previous := {HAND_LEFT: [], HAND_RIGHT: []}
var _segment_open := {HAND_LEFT: false, HAND_RIGHT: false}
var _line_meshes: Dictionary = {}
var _line_materials: Dictionary = {}
var _markers: Dictionary = {}


func _ready() -> void:
	_build_hand_render(HAND_LEFT, LEFT_COLOR)
	_build_hand_render(HAND_RIGHT, RIGHT_COLOR)
	visible = _enabled
	_redraw_all()


func configure_for_device(descriptor: Dictionary) -> void:
	_target_hands.clear()
	var mappings: Array = descriptor.get("input_mapping", [])
	for mapping_v in mappings:
		if not (mapping_v is Dictionary):
			continue
		var mapping := mapping_v as Dictionary
		var source := String(mapping.get("source", ""))
		var hand := ACTIVE_HAND
		match source:
			"left_controller_pose":
				hand = HAND_LEFT
			"right_controller_pose":
				hand = HAND_RIGHT
			"active_controller_pose":
				hand = ACTIVE_HAND
			_:
				continue
		var target := String(mapping.get("target", ""))
		if not target.is_empty():
			_target_hands[target] = hand
	clear()


func set_enabled(value: bool) -> void:
	if _enabled == value:
		visible = value
		return
	_enabled = value
	clear()
	visible = value


func is_enabled() -> bool:
	return _enabled


## Consume one successfully queued DeviceCommand. `active_hands` must use the
## same per-hand deadman state as ControlMode so a released hand terminates its
## current polyline immediately and the next squeeze starts a new segment.
func record_command(command: Dictionary, driving_hand: int, active_hands: Dictionary) -> void:
	if not _enabled:
		return
	if _is_home_reset_command(command):
		# Reset moves the robot back to a new pose reference. Drop both trails and
		# ignore any controller poses carried by the same command frame.
		clear()
		return
	var poses_v: Variant = command.get("poses", {})
	if not (poses_v is Dictionary):
		break_all()
		return
	var poses := poses_v as Dictionary
	var sampled := {HAND_LEFT: false, HAND_RIGHT: false}

	for target_v in _target_hands.keys():
		var target := String(target_v)
		if not poses.has(target):
			continue
		var hand := int(_target_hands[target])
		if hand == ACTIVE_HAND:
			hand = driving_hand
		if hand != HAND_LEFT and hand != HAND_RIGHT:
			continue
		if not bool(active_hands.get(hand, false)):
			continue
		var pose_v: Variant = poses[target]
		if not (pose_v is Dictionary):
			continue
		var position_v: Variant = _position_from_pose(pose_v as Dictionary)
		if not (position_v is Vector3):
			continue
		_append_point(hand, position_v as Vector3)
		sampled[hand] = true

	for hand in [HAND_LEFT, HAND_RIGHT]:
		if not bool(sampled[hand]):
			break_trajectory(hand)


func break_trajectory(hand: int) -> void:
	if not _segment_open.has(hand):
		return
	_segment_open[hand] = false
	var marker := _markers.get(hand) as MeshInstance3D
	if marker != null:
		marker.visible = false


func break_all() -> void:
	break_trajectory(HAND_LEFT)
	break_trajectory(HAND_RIGHT)


func clear() -> void:
	for hand in [HAND_LEFT, HAND_RIGHT]:
		(_points[hand] as Array).clear()
		(_connect_to_previous[hand] as Array).clear()
		_segment_open[hand] = false
		var marker := _markers.get(hand) as MeshInstance3D
		if marker != null:
			marker.visible = false
	_redraw_all()


func point_count(hand: int) -> int:
	var points := _points.get(hand) as Array
	return points.size() if points != null else 0


func line_segment_count(hand: int) -> int:
	var links := _connect_to_previous.get(hand) as Array
	if links == null:
		return 0
	var count := 0
	for connected_v in links:
		if bool(connected_v):
			count += 1
	return count


func trajectory_segment_count(hand: int) -> int:
	var links := _connect_to_previous.get(hand) as Array
	return _trajectory_segment_count_from_links(links) if links != null else 0


func _is_home_reset_command(command: Dictionary) -> bool:
	var buttons_v: Variant = command.get("buttons", {})
	if not (buttons_v is Dictionary):
		return false
	return bool((buttons_v as Dictionary).get("reset", false))


func _position_from_pose(pose: Dictionary) -> Variant:
	var position_v: Variant = pose.get("position", null)
	if position_v is Vector3:
		var position := position_v as Vector3
		return position if _is_finite_vector(position) else null
	if not (position_v is Array):
		return null
	var values := position_v as Array
	if values.size() < 3:
		return null
	var position := Vector3(float(values[0]), float(values[1]), float(values[2]))
	return position if _is_finite_vector(position) else null


func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _append_point(hand: int, world_position: Vector3) -> void:
	var local_position := to_local(world_position) if is_inside_tree() else world_position
	var points := _points[hand] as Array
	var links := _connect_to_previous[hand] as Array
	var connects := bool(_segment_open[hand]) and not points.is_empty()

	_set_marker_position(hand, local_position)
	if connects and (points.back() as Vector3).distance_to(local_position) < min_point_distance_m:
		return
	if not connects:
		_trim_old_segments_for_new_segment(points, links)

	points.append(local_position)
	links.append(connects)
	_segment_open[hand] = true
	var max_points := maxi(2, max_points_per_hand)
	while points.size() > max_points:
		points.remove_at(0)
		links.remove_at(0)
	if not links.is_empty():
		links[0] = false
	_redraw_hand(hand)


func _trim_old_segments_for_new_segment(points: Array, links: Array) -> void:
	var max_segments := maxi(1, max_segments_per_hand)
	while _trajectory_segment_count_from_links(links) >= max_segments:
		var next_segment_start := -1
		for index in range(1, links.size()):
			if not bool(links[index]):
				next_segment_start = index
				break
		if next_segment_start < 0:
			points.clear()
			links.clear()
			return
		var retained_points := points.slice(next_segment_start)
		var retained_links := links.slice(next_segment_start)
		points.clear()
		links.clear()
		points.append_array(retained_points)
		links.append_array(retained_links)
		links[0] = false


func _trajectory_segment_count_from_links(links: Array) -> int:
	var count := 0
	for connected_v in links:
		if not bool(connected_v):
			count += 1
	return count


func _set_marker_position(hand: int, local_position: Vector3) -> void:
	var marker := _markers.get(hand) as MeshInstance3D
	if marker == null:
		return
	marker.position = local_position
	marker.visible = true


func _build_hand_render(hand: int, color: Color) -> void:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = 0.8
	material.no_depth_test = true
	material.render_priority = 6
	_line_materials[hand] = material

	var line_mesh := ImmediateMesh.new()
	_line_meshes[hand] = line_mesh
	var line_instance := MeshInstance3D.new()
	line_instance.name = "LeftEEPoseTrail" if hand == HAND_LEFT else "RightEEPoseTrail"
	line_instance.mesh = line_mesh
	line_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	line_instance.extra_cull_margin = 4.0
	add_child(line_instance)

	var sphere := SphereMesh.new()
	sphere.radius = MARKER_RADIUS_M
	sphere.height = MARKER_RADIUS_M * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	var marker := MeshInstance3D.new()
	marker.name = "LeftEEPoseMarker" if hand == HAND_LEFT else "RightEEPoseMarker"
	marker.mesh = sphere
	marker.material_override = material
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.visible = false
	add_child(marker)
	_markers[hand] = marker


func _redraw_all() -> void:
	_redraw_hand(HAND_LEFT)
	_redraw_hand(HAND_RIGHT)


func _redraw_hand(hand: int) -> void:
	var line_mesh := _line_meshes.get(hand) as ImmediateMesh
	if line_mesh == null:
		return
	line_mesh.clear_surfaces()
	var points := _points[hand] as Array
	var links := _connect_to_previous[hand] as Array
	if points.size() < 2:
		return
	var has_segment := false
	for connected_v in links:
		if bool(connected_v):
			has_segment = true
			break
	if not has_segment:
		return
	line_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _line_materials[hand] as Material)
	for index in range(1, points.size()):
		if not bool(links[index]):
			continue
		line_mesh.surface_add_vertex(points[index - 1] as Vector3)
		line_mesh.surface_add_vertex(points[index] as Vector3)
	line_mesh.surface_end()
