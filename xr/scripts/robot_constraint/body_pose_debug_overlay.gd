class_name BodyPoseDebugOverlay
extends Node3D

## Debug-only 1:1 point cloud of the Godot XRBodyTracker canonical body pose.
##
## The overlay subscribes to BodyPoseProvider.canonical_frame_ready, uses the
## Godot-defined 87-joint vocabulary, and re-projects every valid joint into a
## copy of the user's body placed one metre in front of the HMD at creation
## time. The copy is world-locked after that; it does not follow the view.
## This keeps the debug view compatible with Pico and Quest because the
## vendor-specific body sources have already been resolved into canonical
## joints by BodyPoseProvider.

const CanonicalJointsCls := preload("res://scripts/robot_constraint/canonical_joints.gd")

const HIDDEN_POINT_JOINTS := {
	"root": true,
}

# Each link is ``[from, to]``. Optional third element is a list of blocker
# joints: the link is only enabled when all blockers are missing/invalid.
const BODY_BONE_LINKS: Array[Array] = [
	["hips", "spine"],
	["spine", "chest"],
	["chest", "upper_chest"],
	["upper_chest", "neck"],
	["neck", "head"],
	["hips", "left_upper_leg"],
	["left_upper_leg", "left_lower_leg"],
	["left_lower_leg", "left_foot"],
	["left_foot", "left_toes"],
	["hips", "right_upper_leg"],
	["right_upper_leg", "right_lower_leg"],
	["right_lower_leg", "right_foot"],
	["right_foot", "right_toes"],
	["upper_chest", "left_scapula"],
	["left_scapula", "left_shoulder"],
	["upper_chest", "left_shoulder", ["left_scapula"]],
	["left_shoulder", "left_upper_arm"],
	["left_upper_arm", "left_lower_arm"],
	["left_shoulder", "left_lower_arm", ["left_upper_arm"]],
	["left_lower_arm", "left_wrist"],
	["left_wrist", "left_hand"],
	["left_lower_arm", "left_hand", ["left_wrist"]],
	["left_hand", "left_palm"],
	["upper_chest", "right_scapula"],
	["right_scapula", "right_shoulder"],
	["upper_chest", "right_shoulder", ["right_scapula"]],
	["right_shoulder", "right_upper_arm"],
	["right_upper_arm", "right_lower_arm"],
	["right_shoulder", "right_lower_arm", ["right_upper_arm"]],
	["right_lower_arm", "right_wrist"],
	["right_wrist", "right_hand"],
	["right_lower_arm", "right_hand", ["right_wrist"]],
	["right_hand", "right_palm"],
]

const HAND_FINGER_CHAINS: Array[Array] = [
	["%s_palm", "%s_thumb_metacarpal", "%s_thumb_phalanx_proximal", "%s_thumb_phalanx_distal", "%s_thumb_tip"],
	["%s_palm", "%s_index_finger_metacarpal", "%s_index_finger_phalanx_proximal", "%s_index_finger_phalanx_intermediate", "%s_index_finger_phalanx_distal", "%s_index_finger_tip"],
	["%s_palm", "%s_middle_finger_metacarpal", "%s_middle_finger_phalanx_proximal", "%s_middle_finger_phalanx_intermediate", "%s_middle_finger_phalanx_distal", "%s_middle_finger_tip"],
	["%s_palm", "%s_ring_finger_metacarpal", "%s_ring_finger_phalanx_proximal", "%s_ring_finger_phalanx_intermediate", "%s_ring_finger_phalanx_distal", "%s_ring_finger_tip"],
	["%s_palm", "%s_pinky_finger_metacarpal", "%s_pinky_finger_phalanx_proximal", "%s_pinky_finger_phalanx_intermediate", "%s_pinky_finger_phalanx_distal", "%s_pinky_finger_tip"],
]

const HAND_ROOT_FALLBACK_LINKS: Array[Array] = [
	["%s_hand", "%s_thumb_metacarpal", ["%s_palm"]],
	["%s_hand", "%s_index_finger_metacarpal", ["%s_palm"]],
	["%s_hand", "%s_middle_finger_metacarpal", ["%s_palm"]],
	["%s_hand", "%s_ring_finger_metacarpal", ["%s_palm"]],
	["%s_hand", "%s_pinky_finger_metacarpal", ["%s_palm"]],
]

@export var front_distance_m: float = 1.0
@export var front_vertical_offset_m: float = -0.65
@export var point_radius_m: float = 0.025
@export var hand_point_radius_m: float = 0.008
@export var bone_radius_m: float = 0.008
@export var hand_bone_radius_m: float = 0.004

var _head_camera: Node3D = null
var _point_nodes: Dictionary = {}
var _bone_nodes: Dictionary = {}
var _bone_links: Array[Array] = []
var _last_bone_transforms: Dictionary = {}
var _tracked_material: StandardMaterial3D
var _inferred_material: StandardMaterial3D
var _untracked_material: StandardMaterial3D
var _bone_tracked_material: StandardMaterial3D
var _bone_inferred_material: StandardMaterial3D
var _bone_untracked_material: StandardMaterial3D
var _display_root := Transform3D.IDENTITY
var _display_root_locked := false

var _diag_total_frames := 0
var _diag_last_log_usec := 0
const _DIAG_LOG_INTERVAL_USEC := 5_000_000


func _ready() -> void:
	_build_materials()
	_build_points()
	_build_bones()
	_lock_display_root_to_current_view()
	print("[BodyPoseDebugOverlay] ready: %d canonical joint points, %d bones" % [_point_nodes.size(), _bone_nodes.size()])


func configure(provider: Object) -> void:
	if provider == null:
		return
	if provider.has_signal("canonical_frame_ready"):
		provider.connect("canonical_frame_ready", Callable(self, "_on_canonical_frame_ready"))
	if provider.has_method("get_latest_frame"):
		var latest: Variant = provider.call("get_latest_frame")
		if typeof(latest) == TYPE_DICTIONARY and not (latest as Dictionary).is_empty():
			_on_canonical_frame_ready(latest as Dictionary)


func set_head_camera(camera: Node3D) -> void:
	_head_camera = camera
	if is_inside_tree() and not _display_root_locked:
		_lock_display_root_to_current_view()


func _build_materials() -> void:
	_tracked_material = _make_point_material(Color(0.18, 0.80, 1.0, 0.95))
	_inferred_material = _make_point_material(Color(1.0, 0.72, 0.18, 0.90))
	_untracked_material = _make_point_material(Color(0.72, 0.72, 0.72, 0.70))
	_bone_tracked_material = _make_point_material(Color(0.18, 0.80, 1.0, 0.72))
	_bone_inferred_material = _make_point_material(Color(1.0, 0.72, 0.18, 0.62))
	_bone_untracked_material = _make_point_material(Color(0.72, 0.72, 0.72, 0.42))


func _make_point_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 0.45
	return mat


func _build_points() -> void:
	var body_sphere := _make_sphere_mesh(point_radius_m)
	var hand_sphere := _make_sphere_mesh(hand_point_radius_m)
	for joint_name in CanonicalJointsCls.JOINT_NAMES:
		if HIDDEN_POINT_JOINTS.has(String(joint_name)):
			continue
		var marker := MeshInstance3D.new()
		marker.name = "BodyPosePoint_%s" % joint_name
		marker.mesh = hand_sphere if _is_hand_joint(String(joint_name)) else body_sphere
		marker.visible = false
		marker.set_surface_override_material(0, _tracked_material)
		add_child(marker)
		_point_nodes[String(joint_name)] = marker


func _make_sphere_mesh(radius: float) -> SphereMesh:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	return sphere


func _build_bones() -> void:
	_bone_links = BODY_BONE_LINKS.duplicate(true)
	for side_v in ["left", "right"]:
		var side := String(side_v)
		for template_v in HAND_FINGER_CHAINS:
			var template := template_v as Array
			var previous := ""
			for joint_template_v in template:
				var joint_name := String(joint_template_v) % side
				if not previous.is_empty():
					_bone_links.append([previous, joint_name])
				previous = joint_name
		for fallback_template_v in HAND_ROOT_FALLBACK_LINKS:
			_bone_links.append(_format_link_template(fallback_template_v as Array, side))
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 1.0
	cylinder.radial_segments = 8
	cylinder.rings = 1
	for link_v in _bone_links:
		var link := link_v as Array
		if link.size() < 2:
			continue
		var key := _bone_key(String(link[0]), String(link[1]))
		if _bone_nodes.has(key):
			continue
		var stick := MeshInstance3D.new()
		stick.name = "BodyPoseBone_%s" % key
		stick.mesh = cylinder
		stick.visible = false
		stick.set_surface_override_material(0, _bone_tracked_material)
		add_child(stick)
		_bone_nodes[key] = stick


func _on_canonical_frame_ready(frame: Dictionary) -> void:
	var joints_v: Variant = frame.get("joints", {})
	if typeof(joints_v) != TYPE_DICTIONARY:
		return
	var joints := joints_v as Dictionary
	var root_record := _source_root_transform(joints)
	if root_record.is_empty():
		return
	var source_root: Transform3D = root_record["transform"]
	var display_root := _display_root_transform()
	var source_root_inv := Transform3D(Basis.IDENTITY, source_root.origin).affine_inverse()
	var visible_count := 0
	var display_positions: Dictionary = {}
	var display_records: Dictionary = {}

	for joint_name_v in CanonicalJointsCls.JOINT_NAMES:
		var joint_name := String(joint_name_v)
		var marker: MeshInstance3D = _point_nodes.get(joint_name, null)
		if marker == null:
			continue
		var joint_pose := _joint_transform(joints, joint_name)
		if joint_pose.is_empty():
			marker.visible = false
			continue
		var source_position: Vector3 = joint_pose["position"]
		var local_position: Vector3 = source_root_inv * source_position
		var display_position: Vector3 = display_root * local_position
		marker.global_position = display_position
		marker.set_surface_override_material(0, _material_for_joint(joint_pose["record"]))
		marker.visible = true
		display_positions[joint_name] = display_position
		display_records[joint_name] = joint_pose["record"]
		visible_count += 1

	_update_bones(display_positions, display_records)
	_diag_total_frames += 1
	_maybe_log_diag(visible_count)


func _update_bones(display_positions: Dictionary, display_records: Dictionary) -> void:
	for link_v in _bone_links:
		var link := link_v as Array
		if link.size() < 2:
			continue
		var a := String(link[0])
		var b := String(link[1])
		var shown := false
		var key := _bone_key(a, b)
		if not _link_enabled(link, display_positions):
			_hide_bone(key)
			continue
		if display_positions.has(a) and display_positions.has(b):
			shown = _show_bone(a, b, display_positions, display_records)
		if not shown:
			_show_cached_bone_gray(key)


func _show_bone(a: String, b: String, display_positions: Dictionary, display_records: Dictionary) -> bool:
	var key := _bone_key(a, b)
	var stick: MeshInstance3D = _bone_nodes.get(key, null)
	if stick == null:
		return false
	var pa: Vector3 = display_positions[a]
	var pb: Vector3 = display_positions[b]
	var delta := pb - pa
	var length := delta.length()
	if length < 0.001 or length > _max_bone_length(a, b):
		return false
	var radius := hand_bone_radius_m if (_is_hand_joint(a) or _is_hand_joint(b)) else bone_radius_m
	var bone_transform := Transform3D(_basis_for_cylinder(delta / length, radius, length), (pa + pb) * 0.5)
	stick.global_transform = bone_transform
	stick.set_surface_override_material(0, _material_for_bone(display_records.get(a, {}), display_records.get(b, {})))
	stick.visible = true
	_last_bone_transforms[key] = bone_transform
	return true


func _show_cached_bone_gray(key: String) -> void:
	var stick: MeshInstance3D = _bone_nodes.get(key, null)
	if stick == null or not _last_bone_transforms.has(key):
		return
	stick.global_transform = _last_bone_transforms[key]
	stick.set_surface_override_material(0, _bone_untracked_material)
	stick.visible = true


func _hide_bone(key: String) -> void:
	var stick: MeshInstance3D = _bone_nodes.get(key, null)
	if stick != null:
		stick.visible = false
	_last_bone_transforms.erase(key)


func _link_enabled(link: Array, display_positions: Dictionary) -> bool:
	if link.size() < 3 or typeof(link[2]) != TYPE_ARRAY:
		return true
	for blocker_v in (link[2] as Array):
		if display_positions.has(String(blocker_v)):
			return false
	return true


func _format_link_template(link_template: Array, side: String) -> Array:
	var link: Array = [String(link_template[0]) % side, String(link_template[1]) % side]
	if link_template.size() < 3 or typeof(link_template[2]) != TYPE_ARRAY:
		return link
	var blockers: Array = []
	for blocker_v in (link_template[2] as Array):
		blockers.append(String(blocker_v) % side)
	link.append(blockers)
	return link


func _source_root_transform(joints: Dictionary) -> Dictionary:
	for candidate in ["hips", "root", "spine", "chest", "head"]:
		var joint_pose := _joint_transform(joints, candidate)
		if not joint_pose.is_empty():
			return {"transform": joint_pose["transform"]}
	var average := Vector3.ZERO
	var count := 0
	for joint_name_v in CanonicalJointsCls.JOINT_NAMES:
		var joint_pose := _joint_transform(joints, String(joint_name_v))
		if joint_pose.is_empty():
			continue
		average += joint_pose["position"]
		count += 1
	if count <= 0:
		return {}
	return {"transform": Transform3D(Basis.IDENTITY, average / float(count))}


func _joint_transform(joints: Dictionary, joint_name: String) -> Dictionary:
	var record_v: Variant = joints.get(joint_name, null)
	if typeof(record_v) != TYPE_DICTIONARY:
		return {}
	var record := record_v as Dictionary
	if not bool(record.get("valid", false)):
		return {}
	var pose_v: Variant = record.get("pose", null)
	if typeof(pose_v) != TYPE_DICTIONARY:
		return {}
	var pose := pose_v as Dictionary
	var p_v: Variant = pose.get("p", [])
	if typeof(p_v) != TYPE_ARRAY:
		return {}
	var p_arr := p_v as Array
	if p_arr.size() < 3:
		return {}
	var position := Vector3(float(p_arr[0]), float(p_arr[1]), float(p_arr[2]))

	var basis := Basis.IDENTITY
	var q_v: Variant = pose.get("q", [])
	if typeof(q_v) == TYPE_ARRAY:
		var q_arr := q_v as Array
		if q_arr.size() >= 4:
			var quat := Quaternion(float(q_arr[0]), float(q_arr[1]), float(q_arr[2]), float(q_arr[3]))
			var len_sq := quat.x * quat.x + quat.y * quat.y + quat.z * quat.z + quat.w * quat.w
			if len_sq > 0.000001:
				basis = Basis(quat.normalized())
	return {
		"position": position,
		"transform": Transform3D(basis, position),
		"record": record,
	}


func _display_root_transform() -> Transform3D:
	if not _display_root_locked:
		_lock_display_root_to_current_view()
	return _display_root


func _lock_display_root_to_current_view() -> bool:
	if _head_camera == null:
		return false
	var camera_xf := _head_camera.global_transform
	var basis := camera_xf.basis.orthonormalized()
	var forward := -basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var anchor := camera_xf.origin + forward * front_distance_m
	anchor.y += front_vertical_offset_m
	_display_root = Transform3D(Basis.IDENTITY, anchor)
	_display_root_locked = true
	return true


func _material_for_joint(record: Dictionary) -> StandardMaterial3D:
	if bool(record.get("tracked", false)):
		return _tracked_material
	if bool(record.get("inferred", false)):
		return _inferred_material
	return _untracked_material


func _material_for_bone(a_record: Dictionary, b_record: Dictionary) -> StandardMaterial3D:
	if bool(a_record.get("tracked", false)) and bool(b_record.get("tracked", false)):
		return _bone_tracked_material
	if bool(a_record.get("inferred", false)) or bool(b_record.get("inferred", false)):
		return _bone_inferred_material
	return _bone_untracked_material


func _basis_for_cylinder(y_axis: Vector3, radius: float, length: float) -> Basis:
	var helper := Vector3.UP
	if absf(y_axis.dot(helper)) > 0.95:
		helper = Vector3.RIGHT
	var x_axis := helper.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	return Basis(x_axis * radius, y_axis * length, z_axis * radius)


func _is_hand_joint(joint_name: String) -> bool:
	var is_left := joint_name.begins_with("left_")
	var is_right := joint_name.begins_with("right_")
	if not is_left and not is_right:
		return false
	return joint_name.contains("hand") \
			or joint_name.contains("palm") \
			or joint_name.contains("wrist") \
			or joint_name.contains("thumb") \
			or joint_name.contains("finger")


func _max_bone_length(a: String, b: String) -> float:
	if _is_forearm_to_wrist_bone(a, b):
		return 0.55
	if _is_hand_joint(a) and _is_hand_joint(b):
		return 0.18
	if a.contains("_leg") or b.contains("_leg") or a.contains("_foot") or b.contains("_foot") or a.contains("_toes") or b.contains("_toes"):
		return 0.95
	return 0.70


func _is_forearm_to_wrist_bone(a: String, b: String) -> bool:
	return (a.ends_with("_lower_arm") and b.ends_with("_wrist")) \
			or (b.ends_with("_lower_arm") and a.ends_with("_wrist"))


func _bone_key(a: String, b: String) -> String:
	return "%s__%s" % [a, b]


func _maybe_log_diag(visible_count: int) -> void:
	var now := Time.get_ticks_usec()
	if now - _diag_last_log_usec < _DIAG_LOG_INTERVAL_USEC:
		return
	_diag_last_log_usec = now
	print("[BodyPoseDebugOverlay] %d canonical frames applied; visible_points=%d/%d" % [
		_diag_total_frames,
		visible_count,
		_point_nodes.size(),
	])
