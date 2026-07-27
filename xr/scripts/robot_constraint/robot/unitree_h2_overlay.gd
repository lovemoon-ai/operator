class_name UnitreeH2Overlay
extends Node3D

signal qpos_updated(qpos: PackedFloat64Array)

## In-headset H2 embodiment. It can run the bundled GMR library natively or
## accept full MuJoCo qpos frames from retargeting-service.

const GLB_PATH := "res://assets/robots/h2-plus/h2_with_sharpa.glb"
const MOCAP_XML := "res://assets/mujoco/h2_with_sharpa.xml"
const IK_CONFIG := "res://assets/retargeting/quest3_upper_to_g1.json"
const LOCKED_QPOS_PREFIX := 19
const HUMAN_HEIGHT := 1.75
const PELVIS_HEIGHT := 0.88
const SMOOTH_ALPHA := 0.25
const CLAMP_JOINT_NAMES := [
	"waist_roll_joint",
	"waist_pitch_joint",
	"left_wrist_roll_joint",
	"left_wrist_pitch_joint",
	"left_wrist_yaw_joint",
	"right_wrist_roll_joint",
	"right_wrist_pitch_joint",
	"right_wrist_yaw_joint",
]
const JOINT_MAP := {
	"Hips": ["hips"],
	"Chest": ["upper_chest", "chest", "lower_chest", "spine"],
	"LeftShoulder": ["left_upper_arm", "left_shoulder"],
	"LeftArmLower": ["left_lower_arm"],
	"LeftWrist": ["left_wrist", "left_hand"],
	"RightShoulder": ["right_upper_arm", "right_shoulder"],
	"RightArmLower": ["right_lower_arm"],
	"RightWrist": ["right_wrist", "right_hand"],
}

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
@export var native_retargeting_enabled := true

# --- Loaded GLB nodes -----------------------------------------------------

# link_name -> Node3D mounted in the scene tree. Populated by walking the
# GLB's children at _ready().
var _link_nodes: Dictionary = {}
var _rest_local: Dictionary = {}
# Override-applied materials. Stored so future tint changes do not need
# to walk the tree again.
var _overlay_materials: Array = []  # Array[StandardMaterial3D]

# --- Anchoring ------------------------------------------------------------

var _pelvis_node: Node3D = null
var _pelvis_rest_transform: Transform3D = Transform3D.IDENTITY
var _head_camera: Node3D = null
var _debug_front_locked: bool = false
var _provider: Node
var _retargeter: Object
var _retarget_active := false
var _qpos_joints: Array[Dictionary] = []
var _clamp_indices := PackedInt32Array()
var _smooth_position: Dictionary = {}
var _smooth_quaternion: Dictionary = {}
var _heading_yaw := 0.0
var _heading_ready := false


func _ready() -> void:
	if not ResourceLoader.exists(GLB_PATH):
		# The `%` bound to the second literal alone, which has no placeholder:
		# a constant-folding parse error that made this whole script unloadable,
		# so H2 silently never rendered.
		push_error(
			(
				"[UnitreeH2Overlay] GLB not found at %s. "
				+ "Run scripts/make-robot/make_unitree_h2_sharpa.sh to produce it."
			)
			% GLB_PATH
		)
		return
	_load_glb()
	if _pelvis_node == null:
		push_error("[UnitreeH2Overlay] GLB did not contain a 'pelvis' node; overlay disabled.")
		return
	_apply_overlay_material()
	_parse_mocap_joints()
	if native_retargeting_enabled:
		_setup_retargeter()
	if debug_place_in_front_of_view:
		call_deferred("_lock_in_front_of_view")
	print(
		(
			"[UnitreeH2Overlay] ready: %d link nodes, %d joints, retarget=%s"
			% [_link_nodes.size(), _qpos_joints.size(), str(_retarget_active)]
		)
	)


func _process(_delta: float) -> void:
	if debug_place_in_front_of_view and not _debug_front_locked:
		_lock_in_front_of_view()


func set_head_camera(camera: Node3D) -> void:
	_head_camera = camera
	if is_inside_tree() and debug_place_in_front_of_view and not _debug_front_locked:
		call_deferred("_lock_in_front_of_view")


func set_body_pose_provider(provider: Node) -> void:
	_disconnect_provider()
	_provider = provider
	if provider != null and provider.has_signal("canonical_frame_ready"):
		provider.canonical_frame_ready.connect(_on_canonical_frame_ready)


func is_native_retargeting_ready() -> bool:
	return _retarget_active and _retargeter != null


func get_native_retargeting_error() -> String:
	if is_native_retargeting_ready():
		return ""
	if not ClassDB.class_exists("GMRRetargeter"):
		return "GMRRetargeter extension is unavailable for Unitree H2"
	return "Unitree H2 native retargeting failed to initialize"


func _exit_tree() -> void:
	_disconnect_provider()
	_retargeter = null
	_retarget_active = false


func _disconnect_provider() -> void:
	if (
		_provider != null
		and is_instance_valid(_provider)
		and _provider.has_signal("canonical_frame_ready")
		and _provider.canonical_frame_ready.is_connected(_on_canonical_frame_ready)
	):
		_provider.canonical_frame_ready.disconnect(_on_canonical_frame_ready)
	_provider = null


# --- GLB load --------------------------------------------------------------


func _load_glb() -> void:
	var packed: PackedScene = load(GLB_PATH)
	if packed == null:
		push_error("[UnitreeH2Overlay] failed to load GLB: %s" % GLB_PATH)
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
			_rest_local[name] = n3.transform
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


func _parse_mocap_joints() -> void:
	var bytes := FileAccess.get_file_as_bytes(MOCAP_XML)
	if bytes.is_empty():
		push_warning("[UnitreeH2Overlay] could not read %s" % MOCAP_XML)
		return
	var parser := XMLParser.new()
	if parser.open_buffer(bytes) != OK:
		return
	var body_stack: Array[String] = []
	while parser.read() == OK:
		var node_type := parser.get_node_type()
		if node_type == XMLParser.NODE_ELEMENT:
			var element := parser.get_node_name()
			if element == "body" and not parser.is_empty():
				body_stack.push_back(_attr(parser, "name", ""))
			elif element == "joint" and not body_stack.is_empty():
				var joint_type := _attr(parser, "type", "hinge")
				if joint_type != "free" and joint_type != "ball":
					var joint_name := _attr(parser, "name", "")
					var qpos_index := 7 + _qpos_joints.size()
					(
						_qpos_joints
						. append(
							{
								"name": joint_name,
								"body": body_stack.back(),
								"axis": _parse_vec3(_attr(parser, "axis", "0 0 1")),
							}
						)
					)
					if joint_name in CLAMP_JOINT_NAMES:
						_clamp_indices.push_back(qpos_index)
		elif (
			node_type == XMLParser.NODE_ELEMENT_END
			and parser.get_node_name() == "body"
			and not body_stack.is_empty()
		):
			body_stack.pop_back()


func _setup_retargeter() -> void:
	if not ClassDB.class_exists("GMRRetargeter"):
		push_warning("[UnitreeH2Overlay] GMRRetargeter is unavailable")
		return
	var robot_path := _extract_to_user(MOCAP_XML)
	var config_path := _extract_to_user(IK_CONFIG)
	if robot_path.is_empty() or config_path.is_empty():
		return
	var retargeter := ClassDB.instantiate("GMRRetargeter")
	if retargeter == null:
		return
	var configured := bool(
		retargeter.call(
			"configure",
			"upper_body",
			robot_path,
			config_path,
			HUMAN_HEIGHT,
			LOCKED_QPOS_PREFIX,
			false,
			_clamp_indices
		)
	)
	if not configured:
		push_warning(
			"[UnitreeH2Overlay] configure failed: %s" % str(retargeter.call("get_last_error"))
		)
		return
	_retargeter = retargeter
	_retarget_active = true


func _extract_to_user(resource_path: String) -> String:
	var target := "user://".path_join(resource_path.get_file())
	var data := FileAccess.get_file_as_bytes(resource_path)
	if data.is_empty():
		return ""
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_buffer(data)
	file.close()
	return ProjectSettings.globalize_path(target)


func _on_canonical_frame_ready(frame: Dictionary) -> void:
	if not _retarget_active or _retargeter == null:
		return
	var joints_value: Variant = frame.get("joints", {})
	if typeof(joints_value) != TYPE_DICTIONARY:
		return
	var joints := joints_value as Dictionary
	var raw_position: Dictionary = {}
	var raw_quaternion: Dictionary = {}
	for target_name in JOINT_MAP:
		var pose := _canonical_pose(joints, JOINT_MAP[target_name])
		if pose.is_empty():
			return
		var position: Vector3 = pose["position"]
		raw_position[target_name] = Vector3(-position.z, -position.x, position.y)
		raw_quaternion[target_name] = pose["quaternion"]
	for target_name in raw_position:
		if _smooth_position.has(target_name):
			_smooth_position[target_name] = ((_smooth_position[target_name] as Vector3).lerp(
				raw_position[target_name], SMOOTH_ALPHA
			))
			_smooth_quaternion[target_name] = (
				(_smooth_quaternion[target_name] as Quaternion)
				. slerp(raw_quaternion[target_name], SMOOTH_ALPHA)
			)
		else:
			_smooth_position[target_name] = raw_position[target_name]
			_smooth_quaternion[target_name] = raw_quaternion[target_name]
	if not _heading_ready:
		var side := (
			(_smooth_position["LeftShoulder"] as Vector3)
			- (_smooth_position["RightShoulder"] as Vector3)
		)
		var horizontal := Vector2(side.x, side.y)
		if horizontal.length() < 0.05:
			return
		_heading_yaw = PI / 2.0 - atan2(horizontal.y, horizontal.x)
		_heading_ready = true
	var cosine := cos(_heading_yaw)
	var sine := sin(_heading_yaw)
	var hips: Vector3 = _smooth_position["Hips"]
	var heading_q := Quaternion(0.0, 0.0, sin(_heading_yaw / 2.0), cos(_heading_yaw / 2.0))
	var combined_q := _qmul(heading_q, Quaternion(0.5, -0.5, -0.5, 0.5))
	_retargeter.call("clear_frame")
	for target_name in _smooth_position:
		var relative := (_smooth_position[target_name] as Vector3) - hips
		var target_position := Vector3(
			relative.x * cosine - relative.y * sine,
			relative.x * sine + relative.y * cosine,
			relative.z + PELVIS_HEIGHT
		)
		var target_quaternion := _qmul(combined_q, _smooth_quaternion[target_name])
		_retargeter.call("set_pose_pq", target_name, target_position, target_quaternion)
	var qpos: PackedFloat64Array = _retargeter.call("step")
	_apply_qpos(qpos)


func _canonical_pose(joints: Dictionary, candidates: Array) -> Dictionary:
	for candidate in candidates:
		var record_value: Variant = joints.get(candidate, null)
		if typeof(record_value) != TYPE_DICTIONARY:
			continue
		var record := record_value as Dictionary
		if not bool(record.get("valid", false)):
			continue
		var pose_value: Variant = record.get("pose", null)
		if typeof(pose_value) != TYPE_DICTIONARY:
			continue
		var pose := pose_value as Dictionary
		var position_values: Array = pose.get("p", [])
		if position_values.size() < 3:
			continue
		var position := Vector3(
			float(position_values[0]), float(position_values[1]), float(position_values[2])
		)
		if not (is_finite(position.x) and is_finite(position.y) and is_finite(position.z)):
			continue
		var quaternion := Quaternion.IDENTITY
		var quaternion_values: Array = pose.get("q", [])
		if quaternion_values.size() >= 4:
			var value := Quaternion(
				float(quaternion_values[0]),
				float(quaternion_values[1]),
				float(quaternion_values[2]),
				float(quaternion_values[3])
			)
			if value.length_squared() > 0.000001:
				quaternion = value.normalized()
		return {"position": position, "quaternion": quaternion}
	return {}


func _apply_qpos(qpos: PackedFloat64Array) -> void:
	for value in qpos:
		if not is_finite(value):
			return
	for index in range(_qpos_joints.size()):
		var qpos_index := 7 + index
		if qpos_index >= qpos.size():
			break
		var spec := _qpos_joints[index]
		var node: Node3D = _link_nodes.get(spec["body"], null)
		if node == null:
			continue
		var axis: Vector3 = spec["axis"]
		if axis.length_squared() < 0.000001:
			continue
		var godot_axis := Vector3(-axis.y, axis.z, -axis.x).normalized()
		var rest: Transform3D = _rest_local.get(spec["body"], node.transform)
		node.transform = (
			rest * Transform3D(Basis(godot_axis, float(qpos[qpos_index])), Vector3.ZERO)
		)
	qpos_updated.emit(qpos)


func apply_remote_qpos(qpos: PackedFloat64Array) -> void:
	_apply_qpos(qpos)


func _qmul(a: Quaternion, b: Quaternion) -> Quaternion:
	return Quaternion(
		a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
		a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
	)


func _attr(parser: XMLParser, key: String, fallback: String) -> String:
	for index in range(parser.get_attribute_count()):
		if parser.get_attribute_name(index) == key:
			return parser.get_attribute_value(index)
	return fallback


func _parse_vec3(value: String) -> Vector3:
	var parts := value.split(" ", false)
	if parts.size() < 3:
		return Vector3(0, 0, 1)
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


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
