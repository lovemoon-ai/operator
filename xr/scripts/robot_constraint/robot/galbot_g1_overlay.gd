class_name GalbotG1Overlay
extends Node3D

signal qpos_updated(qpos: PackedFloat64Array)

## Galbot G1 in-headset overlay driven by retargeting v0.1.3's
## "dual_arm_eepose" algorithm.
##
## Runtime contract:
##   canonical VR pose (head + wrists)
##   -> frame-delta left/right TCP targets in Galbot robot-world coordinates
##   -> GMRRetargeter.configure_algorithm(..., "dual_arm_eepose", ...)
##   -> robot pose {joint_names, joint_q, qpos}
##   -> FK on the baked GLB arm links.
##
## The native algorithm solves the two 7-DoF arms. The overlay also updates the
## locked head/leg qpos from the operator's head pose before each solve.

const GLB_PATH := "res://assets/robots/galbot-g1/galbot_g1.glb"
const ROBOT_XML := "res://assets/mujoco/galbot_g1.xml"
const EE_CONFIG := "res://assets/retargeting/dual_arm_eepose_galbot_g1.json"

const ALGORITHM := "dual_arm_eepose"
const SCENARIO := "upper_body"
const HUMAN_HEIGHT := 1.75
## Full Galbot model qpos: free base (7) + leg/lift (5) + head (2).
const LOCKED_QPOS_PREFIX := 14

const ARM_JOINT_NAMES := [
	"left_arm_joint1",
	"left_arm_joint2",
	"left_arm_joint3",
	"left_arm_joint4",
	"left_arm_joint5",
	"left_arm_joint6",
	"left_arm_joint7",
	"right_arm_joint1",
	"right_arm_joint2",
	"right_arm_joint3",
	"right_arm_joint4",
	"right_arm_joint5",
	"right_arm_joint6",
	"right_arm_joint7",
]

const LEG_JOINT_NAMES := [
	"leg_joint1",
	"leg_joint2",
	"leg_joint3",
	"leg_joint4",
	"leg_joint5",
]

const HEAD_JOINT_NAMES := [
	"head_joint1",
	"head_joint2",
]

const LOCKED_CONTROL_JOINT_NAMES := [
	"leg_joint1",
	"leg_joint2",
	"leg_joint3",
	"leg_joint4",
	"leg_joint5",
	"head_joint1",
	"head_joint2",
]

const JOINT_MAP := {
	"Head": ["head"],
	"LeftShoulder": ["left_upper_arm", "left_shoulder"],
	"LeftArmLower": ["left_lower_arm"],
	"LeftWrist": ["left_wrist", "left_hand"],
	"RightShoulder": ["right_upper_arm", "right_shoulder"],
	"RightArmLower": ["right_lower_arm"],
	"RightWrist": ["right_wrist", "right_hand"],
}

const REQUIRED_RETARGET_SLOTS := [
	"Head",
	"LeftShoulder",
	"LeftArmLower",
	"LeftWrist",
	"RightShoulder",
	"RightArmLower",
	"RightWrist",
]

const UPPER_BODY_BONE_LINKS: Array[Array] = [
	["hips", "spine"],
	["spine", "chest"],
	["chest", "upper_chest"],
	["upper_chest", "neck"],
	["neck", "head"],
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

const DIRECT_HAND_JOINT_SUFFIXES := [
	"palm",
	"wrist",
	"thumb_metacarpal",
	"thumb_phalanx_proximal",
	"thumb_phalanx_distal",
	"thumb_tip",
	"index_finger_metacarpal",
	"index_finger_phalanx_proximal",
	"index_finger_phalanx_intermediate",
	"index_finger_phalanx_distal",
	"index_finger_tip",
	"middle_finger_metacarpal",
	"middle_finger_phalanx_proximal",
	"middle_finger_phalanx_intermediate",
	"middle_finger_phalanx_distal",
	"middle_finger_tip",
	"ring_finger_metacarpal",
	"ring_finger_phalanx_proximal",
	"ring_finger_phalanx_intermediate",
	"ring_finger_phalanx_distal",
	"ring_finger_tip",
	"pinky_finger_metacarpal",
	"pinky_finger_phalanx_proximal",
	"pinky_finger_phalanx_intermediate",
	"pinky_finger_phalanx_distal",
	"pinky_finger_tip",
]

## MuJoCo/GMR robot-world rest geometry for xr/assets/mujoco/galbot_g1.xml with
## dual_arm_eepose_galbot_g1.json posture_reference applied. Values are generated
## from retargeting v0.1.3's Galbot example and kept here so the headset path does
## not need a second MuJoCo FK pass just to build targets.
const ROBOT_BASE_POS := Vector3(0.0, 0.0, 1.05)
const HEAD_DEBUG_REST_POS := Vector3(0.1069451212, 0.0, 1.9807747465)
const LEFT_ARM_BASE_POS := Vector3(0.1069436144, 0.20843, 1.7756647465)
const RIGHT_ARM_BASE_POS := Vector3(0.1069436144, -0.20843, 1.7756647465)
const LEFT_TCP_REST_POS := Vector3(0.8784882946, 0.1968955031, 1.4575651633)
const RIGHT_TCP_REST_POS := Vector3(0.8856794341, -0.1706169504, 1.4934492034)
const LEFT_TCP_REST_QUAT := Quaternion(0.9566957582, 0.0423257323, -0.2765955712, -0.0802287270)
const RIGHT_TCP_REST_QUAT := Quaternion(0.9697348749, -0.0127471843, -0.2418809203, 0.0307473911)
const LEFT_ARM_REACH := 0.96572
const RIGHT_ARM_REACH := 0.96572
const REST_ARM_JOINT_Q := [
	0.286632,
	-1.279879,
	0.080134,
	-1.193535,
	-0.739451,
	0.735398,
	-0.566032,
	-0.319888,
	1.357153,
	0.065231,
	1.237595,
	0.624194,
	-0.735398,
	0.461851,
]
const REST_LEG_JOINT_Q := [0.0, 0.0, 0.0, 0.0, 0.0]
const REST_HEAD_JOINT_Q := [0.0, 0.0]
const BODY_YAW_LEG_JOINT_INDEX := 4
const BODY_YAW_JOINT_NAME := "leg_joint5"
const LEG_HEIGHT_UP_JOINT_Q := [0.42, 1.10, 0.95, -0.32, 0.0]
const LEG_HEIGHT_DOWN_JOINT_Q := [0.16, 0.42, 0.36, 0.28, 0.0]

@export var attach_under: NodePath
@export var debug_place_in_front_of_view: bool = true
@export var debug_front_distance_m: float = 1.0
@export var debug_front_vertical_offset_m: float = 0.0
@export var overlay_alpha: float = 0.55
@export var overlay_tint: Color = Color(0.7, 0.85, 0.95, 1.0)
@export var native_retargeting_enabled := true

## Scale VR wrist deltas before applying them to the robot TCP targets.
@export var workspace_scale: float = 1.0
## Target reach clamp relative to each Galbot arm's straight reach.
@export var arm_reach_scale: float = 0.82
## Follow wrist orientation deltas so the gripper rotates with the operator hand.
@export var use_relative_wrist_orientation: bool = true
@export_enum("relative_wrist_roll", "relative_wrist", "neutral")
var retarget_orientation_mode: String = "relative_wrist_roll"
## Map HMD yaw/pitch to Galbot head joints, relative to the first valid VR pose.
@export var head_control_enabled: bool = true
@export var head_yaw_scale: float = 1.0
@export var head_yaw_sign: float = 1.0
@export var head_pitch_scale: float = 1.0
@export var head_pitch_sign: float = -1.0
@export var head_control_tau_s: float = 0.08
## Map body heading to the top Galbot leg joint; height uses the lower leg joints.
@export var body_yaw_control_enabled: bool = true
@export var body_yaw_scale: float = 1.0
@export var body_yaw_sign: float = 1.0
## Map HMD height delta to Galbot leg/lift joints below the body-yaw joint.
@export var head_height_control_enabled: bool = true
@export var head_height_deadzone_m: float = 0.015
@export var head_height_up_range_m: float = 0.25
@export var head_height_down_range_m: float = 0.18
@export var leg_height_tau_s: float = 0.18

@export var input_smoothing_alpha: float = 0.35
@export var output_filter_enabled: bool = false
@export var output_filter_tau_s: float = 0.09
@export var output_filter_vmax: float = 2.0

@export_enum("shoulder_delta", "frame_delta", "se3_delta", "shoulder_absolute", "robot_world_absolute")
var retarget_source_mode: String = "shoulder_delta"
@export var retarget_source_fps: float = 60.0
@export var retarget_source_filter_min_cutoff: float = 0.6
@export var retarget_source_filter_beta: float = 0.03
@export var retarget_source_filter_d_cutoff: float = 1.0

@export var rest_return_enabled: bool = true
@export var rest_return_timeout_s: float = 0.20
@export var rest_pose_detection_enabled: bool = true
@export var rest_pose_min_body_span_m: float = 0.08
@export var rest_pose_origin_epsilon_m: float = 0.03
@export var rest_pose_min_confidence: float = 0.05
@export var rest_pose_source_detection_enabled: bool = true
@export var rest_pose_source_pos_epsilon_m: float = 0.075
@export var rest_pose_source_hold_s: float = 0.12
@export var rest_pose_return_joint_error_rad: float = 0.03
@export var rest_return_tau_s: float = 0.45
@export var rest_return_vmax: float = 1.8
@export var rest_return_epsilon_rad: float = 0.004

@export var debug_show_vr_pose: bool = true
@export var debug_vr_pose_offset: Vector3 = Vector3(0.6, 0.0, 0.0)

# --- GLB nodes ------------------------------------------------------------
var _link_nodes: Dictionary = {}       # link_name -> Node3D
var _rest_local: Dictionary = {}       # link_name -> Transform3D
var _joint_specs: Dictionary = {}      # joint_name -> {body, axis, qpos}
var _overlay_materials: Array = []
var _glb_instance: Node3D = null
var _glb_instance_rest: Transform3D = Transform3D.IDENTITY
var _head_camera: Node3D = null
var _debug_front_locked: bool = false

# --- Retargeting ----------------------------------------------------------
var _retargeter: Object = null
var _provider: Node = null
var _retarget_active: bool = false
var _arm_joint_names_packed := PackedStringArray()
var _arm_qpos_indices := PackedInt32Array()
var _locked_control_joint_names_packed := PackedStringArray()
var _locked_control_qpos_indices := PackedInt32Array()
var _dbg_frames: int = 0

# --- VR target state ------------------------------------------------------
var _target_initialized: bool = false
var _heading_yaw: float = 0.0
var _prev_left_pos: Vector3 = Vector3.ZERO
var _prev_right_pos: Vector3 = Vector3.ZERO
var _prev_head_pos: Vector3 = Vector3.ZERO
var _prev_left_quat: Quaternion = Quaternion.IDENTITY
var _prev_right_quat: Quaternion = Quaternion.IDENTITY
var _left_target_pos: Vector3 = LEFT_TCP_REST_POS
var _right_target_pos: Vector3 = RIGHT_TCP_REST_POS
var _head_debug_pos: Vector3 = HEAD_DEBUG_REST_POS
var _left_target_quat: Quaternion = LEFT_TCP_REST_QUAT
var _right_target_quat: Quaternion = RIGHT_TCP_REST_QUAT
var _smooth_pos: Dictionary = {}
var _smooth_quat: Dictionary = {}

# --- Output filter state --------------------------------------------------
var _filtered_qpos: PackedFloat64Array = PackedFloat64Array()
var _filter_last_us: int = 0
var _current_qpos: PackedFloat64Array = PackedFloat64Array()
var _display_joint_q: PackedFloat64Array = PackedFloat64Array()
var _leg_joint_q: PackedFloat64Array = PackedFloat64Array()
var _head_joint_q: PackedFloat64Array = PackedFloat64Array()
var _head_control_initialized: bool = false
var _head_control_ref_basis: Basis = Basis.IDENTITY
var _head_control_ref_quat: Quaternion = Quaternion.IDENTITY
var _head_control_ref_height: float = 0.0
var _head_control_ref_body_yaw: float = 0.0
var _head_control_ref_head_body_yaw: float = 0.0
var _head_control_ref_head_pitch: float = 0.0
var _last_head_leg_control_usec: int = 0
var _last_pose_valid_usec: int = 0
var _rest_return_active: bool = false
var _last_rest_step_usec: int = 0
var _last_rest_reason: String = ""
var _retarget_reset_pending: bool = false
var _source_rest_signature: Dictionary = {}
var _had_non_rest_source_pose: bool = false
var _source_rest_seen_usec: int = 0

# --- VR-pose debug skeleton -----------------------------------------------
var _vr_pose_root: Node3D = null
var _vr_pose_spheres: Dictionary = {}
var _vr_pose_last_local: Dictionary = {}
var _vr_bone_mesh: ImmediateMesh = null
var _vr_body_mat: StandardMaterial3D = null
var _vr_left_hand_mat: StandardMaterial3D = null
var _vr_right_hand_mat: StandardMaterial3D = null


func _ready() -> void:
	if not ResourceLoader.exists(GLB_PATH):
		push_error("[GalbotG1Overlay] GLB not found at %s. Run scripts/make-robot/make_galbot_g1.sh." % GLB_PATH)
		return
	_load_glb()
	_apply_overlay_material()
	_parse_robot_joints()
	_setup_arm_qpos_indices()
	_setup_locked_control_qpos_indices()
	if native_retargeting_enabled:
		_setup_retargeter()
	if debug_place_in_front_of_view:
		call_deferred("_lock_in_front_of_view")
	print("[GalbotG1Overlay] ready: %d links, %d robot joints, retarget=%s" % [
		_link_nodes.size(), _joint_specs.size(), str(_retarget_active)])


func _process(delta: float) -> void:
	if debug_place_in_front_of_view and not _debug_front_locked:
		_lock_in_front_of_view()
	if not rest_return_enabled:
		return
	if _last_pose_valid_usec > 0:
		var age_s := float(Time.get_ticks_usec() - _last_pose_valid_usec) / 1_000_000.0
		if age_s > maxf(rest_return_timeout_s, 0.0):
			_begin_rest_return("vr_pose_timeout")
	if _rest_return_active:
		_advance_rest_return(delta)


func set_head_camera(camera: Node3D) -> void:
	_head_camera = camera
	if is_inside_tree() and debug_place_in_front_of_view and not _debug_front_locked:
		call_deferred("_lock_in_front_of_view")


func set_body_pose_provider(provider: Node) -> void:
	if _provider == provider:
		return
	_disconnect_body_pose_provider()
	_provider = provider
	if provider != null and provider.has_signal("canonical_frame_ready"):
		var cb := Callable(self, "_on_canonical_frame_ready")
		if not provider.is_connected("canonical_frame_ready", cb):
			provider.connect("canonical_frame_ready", cb)


func is_native_retargeting_ready() -> bool:
	return _retarget_active and _retargeter != null


func get_native_retargeting_error() -> String:
	if is_native_retargeting_ready():
		return ""
	if not ClassDB.class_exists("GMRRetargeter"):
		return "GMRRetargeter extension is unavailable for Galbot G1"
	return "Galbot G1 native retargeting failed to initialize"


func _exit_tree() -> void:
	_disconnect_body_pose_provider()
	_retargeter = null
	_retarget_active = false


func _disconnect_body_pose_provider() -> void:
	if _provider == null or not _provider.has_signal("canonical_frame_ready"):
		return
	var cb := Callable(self, "_on_canonical_frame_ready")
	if _provider.is_connected("canonical_frame_ready", cb):
		_provider.disconnect("canonical_frame_ready", cb)


# --- GLB load --------------------------------------------------------------


func _load_glb() -> void:
	var packed: PackedScene = load(GLB_PATH)
	if packed == null:
		push_error("[GalbotG1Overlay] failed to load GLB: %s" % GLB_PATH)
		return
	var instance: Node = packed.instantiate()
	var parent: Node3D = self
	if not attach_under.is_empty():
		var target := get_node_or_null(attach_under)
		if target is Node3D:
			parent = target
	parent.add_child(instance)
	_index_subtree(instance)
	if instance is Node3D:
		_glb_instance = instance as Node3D
		_glb_instance_rest = _glb_instance.transform


func _index_subtree(node: Node) -> void:
	if node is Node3D:
		var nm := node.name
		if nm != "" and not _link_nodes.has(nm):
			var n3 := node as Node3D
			_link_nodes[nm] = n3
			_rest_local[nm] = n3.transform
	for child in node.get_children():
		_index_subtree(child)


# --- Material --------------------------------------------------------------


func _apply_overlay_material() -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = overlay_tint
	mat.albedo_color.a = overlay_alpha
	mat.metallic = 0.05
	mat.roughness = 0.55
	mat.emission_enabled = true
	mat.emission = overlay_tint
	mat.emission_energy_multiplier = 0.2
	for link_name in _link_nodes:
		_apply_material_to_meshes(_link_nodes[link_name], mat)
	_overlay_materials = [mat]


func _apply_material_to_meshes(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var n := mi.get_surface_override_material_count()
		for i in range(n):
			mi.set_surface_override_material(i, mat)
		if n == 0 and mi.mesh != null:
			mi.set_surface_override_material(0, mat)
	for child in node.get_children():
		_apply_material_to_meshes(child, mat)


# --- MuJoCo joint metadata -------------------------------------------------


func _parse_robot_joints() -> void:
	var bytes := FileAccess.get_file_as_bytes(ROBOT_XML)
	if bytes.is_empty():
		push_warning("[GalbotG1Overlay] could not read robot MJCF %s" % ROBOT_XML)
		return
	var parser := XMLParser.new()
	if parser.open_buffer(bytes) != OK:
		return

	var body_stack: Array = []
	var qpos_cursor := 0
	while parser.read() == OK:
		var t := parser.get_node_type()
		if t == XMLParser.NODE_ELEMENT:
			var el_name := parser.get_node_name()
			var empty := parser.is_empty()
			if el_name == "body":
				var bn := _attr(parser, "name", "")
				if not empty:
					body_stack.push_back(bn)
			elif el_name == "freejoint" and not body_stack.is_empty():
				var jname := _attr(parser, "name", "")
				if jname != "":
					_joint_specs[jname] = {
						"body": String(body_stack[body_stack.size() - 1]),
						"axis": Vector3.ZERO,
						"qpos": qpos_cursor,
						"limited": false,
						"range_min": -INF,
						"range_max": INF,
					}
				qpos_cursor += 7
			elif el_name == "joint" and not body_stack.is_empty():
				var jtype := _attr(parser, "type", "hinge")
				var width := _qpos_width(jtype)
				var jname := _attr(parser, "name", "")
				if jname != "" and width > 0:
					var limited := _parse_bool(_attr(parser, "limited", "false"))
					var joint_range := _parse_joint_range(_attr(parser, "range", ""), limited)
					_joint_specs[jname] = {
						"body": String(body_stack[body_stack.size() - 1]),
						"axis": _parse_vec3(_attr(parser, "axis", "0 0 1")),
						"qpos": qpos_cursor,
						"limited": limited,
						"range_min": joint_range.x,
						"range_max": joint_range.y,
					}
				qpos_cursor += width
		elif t == XMLParser.NODE_ELEMENT_END:
			if parser.get_node_name() == "body" and not body_stack.is_empty():
				body_stack.pop_back()


func _qpos_width(jtype: String) -> int:
	match jtype:
		"free":
			return 7
		"ball":
			return 4
		"hinge", "slide":
			return 1
		_:
			return 1


func _setup_arm_qpos_indices() -> void:
	_arm_joint_names_packed = PackedStringArray(ARM_JOINT_NAMES)
	_arm_qpos_indices = PackedInt32Array()
	for joint_name in ARM_JOINT_NAMES:
		var spec_v: Variant = _joint_specs.get(joint_name, null)
		if typeof(spec_v) != TYPE_DICTIONARY:
			push_warning("[GalbotG1Overlay] missing MJCF joint spec for %s" % joint_name)
			continue
		var spec := spec_v as Dictionary
		_arm_qpos_indices.push_back(int(spec["qpos"]))
	if _arm_qpos_indices.size() != ARM_JOINT_NAMES.size():
		push_warning("[GalbotG1Overlay] arm qpos index table incomplete: %d/%d" % [
			_arm_qpos_indices.size(), ARM_JOINT_NAMES.size()])


func _setup_locked_control_qpos_indices() -> void:
	_locked_control_joint_names_packed = PackedStringArray(LOCKED_CONTROL_JOINT_NAMES)
	_locked_control_qpos_indices = PackedInt32Array()
	for joint_name in LOCKED_CONTROL_JOINT_NAMES:
		var spec_v: Variant = _joint_specs.get(joint_name, null)
		if typeof(spec_v) != TYPE_DICTIONARY:
			push_warning("[GalbotG1Overlay] missing MJCF locked-control joint spec for %s" % joint_name)
			continue
		var spec := spec_v as Dictionary
		_locked_control_qpos_indices.push_back(int(spec["qpos"]))
	if _locked_control_qpos_indices.size() != LOCKED_CONTROL_JOINT_NAMES.size():
		push_warning("[GalbotG1Overlay] locked-control qpos index table incomplete: %d/%d" % [
			_locked_control_qpos_indices.size(), LOCKED_CONTROL_JOINT_NAMES.size()])


func _attr(parser: XMLParser, key: String, fallback: String) -> String:
	for i in range(parser.get_attribute_count()):
		if parser.get_attribute_name(i) == key:
			return parser.get_attribute_value(i)
	return fallback


func _parse_bool(s: String) -> bool:
	var lower := s.strip_edges().to_lower()
	return lower == "true" or lower == "1" or lower == "yes"


func _parse_vec3(s: String) -> Vector3:
	var parts := s.split(" ", false)
	if parts.size() < 3:
		return Vector3(0, 0, 1)
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


func _parse_joint_range(s: String, limited: bool) -> Vector2:
	if not limited:
		return Vector2(-INF, INF)
	var parts := s.split(" ", false)
	if parts.size() < 2:
		return Vector2(-INF, INF)
	return Vector2(float(parts[0]), float(parts[1]))


# --- Retargeter setup ------------------------------------------------------


func _setup_retargeter() -> void:
	if not ClassDB.class_exists("GMRRetargeter"):
		print("[GalbotG1Overlay] GMRRetargeter extension not present; static overlay only.")
		return
	if _arm_qpos_indices.size() != ARM_JOINT_NAMES.size():
		return
	var robot := _extract_to_user(ROBOT_XML)
	var ik := _extract_to_user(EE_CONFIG)
	if robot == "" or ik == "":
		return
	var rt: Object = ClassDB.instantiate("GMRRetargeter")
	if rt == null:
		return
	var ok: bool
	if rt.has_method("configure_algorithm_options"):
		ok = rt.call(
			"configure_algorithm_options",
			SCENARIO,
			robot,
			ik,
			ALGORITHM,
			HUMAN_HEIGHT,
			LOCKED_QPOS_PREFIX,
			true,
			PackedInt32Array(),
			_retarget_options())
	else:
		ok = rt.call(
			"configure_algorithm",
			SCENARIO,
			robot,
			ik,
			ALGORITHM,
			HUMAN_HEIGHT,
			LOCKED_QPOS_PREFIX,
			true,
			PackedInt32Array())
	if not ok:
		push_warning("[GalbotG1Overlay] retargeter configure failed: %s" % str(rt.call("get_last_error")))
		return
	_retargeter = rt
	_retarget_active = true
	print("[GalbotG1Overlay] retargeter ready: algorithm=%s nq=%d" % [
		str(rt.call("get_algorithm_name")), int(rt.call("get_nq"))])


func _retarget_options() -> Dictionary:
	var orientation := "neutral"
	if use_relative_wrist_orientation:
		orientation = retarget_orientation_mode
	return {
		"source_mode": retarget_source_mode,
		"orientation_mode": orientation,
		"workspace_scale": str(maxf(workspace_scale, 0.0)),
		"arm_reach_scale": str(maxf(arm_reach_scale, 0.0)),
		"source_fps": str(maxf(retarget_source_fps, 1.0)),
		"source_filter_min_cutoff": str(maxf(retarget_source_filter_min_cutoff, 0.0)),
		"source_filter_beta": str(maxf(retarget_source_filter_beta, 0.0)),
		"source_filter_d_cutoff": str(maxf(retarget_source_filter_d_cutoff, 0.001)),
	}


func _extract_to_user(res_path: String) -> String:
	var dst := "user://".path_join(res_path.get_file())
	var data := FileAccess.get_file_as_bytes(res_path)
	if data.is_empty():
		push_warning("[GalbotG1Overlay] could not read %s" % res_path)
		return ""
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(data)
	f.close()
	return ProjectSettings.globalize_path(dst)


# --- Per-frame retargeting -------------------------------------------------


func _on_canonical_frame_ready(frame: Dictionary) -> void:
	var joints_v: Variant = frame.get("joints", {})
	if typeof(joints_v) != TYPE_DICTIONARY:
		return
	var joints := joints_v as Dictionary

	var raw := _read_vr_pose(joints)
	_append_direct_hand_poses(raw)
	_dbg_frames += 1
	var dbg := (_dbg_frames % 60) == 1
	if not _has_retarget_slots(raw):
		if dbg:
			print("[GalbotG1Overlay] frame slots resolved=%d/%d (%s)" % [
				_retarget_slot_count(raw), REQUIRED_RETARGET_SLOTS.size(), str(raw.keys())])
		_handle_unusable_vr_pose("missing_retarget_slots")
		return
	var unusable_reason := _vr_pose_unusable_reason(raw)
	if unusable_reason != "":
		if dbg:
			print("[GalbotG1Overlay] vr pose unusable: %s" % unusable_reason)
		_handle_unusable_vr_pose(unusable_reason)
		return

	_mark_vr_pose_valid()
	var aligned := _smooth_and_align(raw)
	_update_head_leg_control(aligned)
	if debug_show_vr_pose:
		_update_vr_pose(_build_debug_pose_points(aligned))

	if not _retarget_active or _retargeter == null:
		return
	_sync_head_leg_to_current_qpos(true)
	var solver_frame := _solver_frame_from_aligned(aligned)
	if not _has_retarget_slots(solver_frame):
		return

	var robot_pose: Dictionary = _retargeter.call(
		"step_frame_robot_pose",
		solver_frame,
		_arm_joint_names_packed,
		_arm_qpos_indices)
	if robot_pose.is_empty():
		if dbg:
			print("[GalbotG1Overlay] step_robot_pose returned empty: %s" % str(_retargeter.call("get_last_error")))
		return

	var qpos: PackedFloat64Array = robot_pose.get("qpos", PackedFloat64Array())
	if output_filter_enabled and not qpos.is_empty():
		qpos = _filter_arm_qpos(qpos)
		_retargeter.call("set_configuration", qpos)
		robot_pose = _robot_pose_from_qpos(qpos)

	_apply_robot_pose(robot_pose)
	_remember_robot_pose(robot_pose)
	_sync_head_leg_to_current_qpos(true)
	_apply_locked_control_pose()

	if dbg:
		var qs: PackedFloat64Array = robot_pose.get("joint_q", PackedFloat64Array())
		var shown := []
		for i in range(mini(qs.size(), 14)):
			shown.append(snappedf(qs[i], 0.01))
		print("[GalbotG1Overlay] robot pose ok algorithm=%s joints=%s head=%s leg=%s" % [
			str(robot_pose.get("algorithm", "")),
			str(shown),
			str(_debug_joint_q(_ensure_head_joint_q())),
			str(_debug_joint_q(_ensure_leg_joint_q()))])


func _read_vr_pose(joints: Dictionary) -> Dictionary:
	var out := {}
	for joint_name_v in joints.keys():
		var joint_name := String(joint_name_v)
		var pose := _canonical_pose(joints, [joint_name])
		if pose.is_empty():
			continue
		var p: Vector3 = pose["position"]
		out[joint_name] = {
			"pos": _openxr_to_gmr(p),
			"quat": pose["quat"],
			"tracked": bool(pose.get("tracked", false)),
			"inferred": bool(pose.get("inferred", false)),
			"confidence": float(pose.get("confidence", 0.0)),
			"source": String(pose.get("source", "")),
			"matched": String(pose.get("matched", joint_name)),
			"quality_meta": bool(pose.get("quality_meta", false)),
		}
	for slot in JOINT_MAP:
		var pose := _canonical_pose(joints, JOINT_MAP[slot])
		if pose.is_empty():
			continue
		var p: Vector3 = pose["position"]
		out[slot] = {
			"pos": _openxr_to_gmr(p),
			"quat": pose["quat"],
			"tracked": bool(pose.get("tracked", false)),
			"inferred": bool(pose.get("inferred", false)),
			"confidence": float(pose.get("confidence", 0.0)),
			"source": String(pose.get("source", "")),
			"matched": String(pose.get("matched", slot)),
			"quality_meta": bool(pose.get("quality_meta", false)),
		}
	return out


func _has_retarget_slots(raw: Dictionary) -> bool:
	for slot in REQUIRED_RETARGET_SLOTS:
		if not raw.has(slot):
			return false
	return true


func _retarget_slot_count(raw: Dictionary) -> int:
	var count := 0
	for slot in REQUIRED_RETARGET_SLOTS:
		if raw.has(slot):
			count += 1
	return count


func _vr_pose_unusable_reason(raw: Dictionary) -> String:
	if not rest_pose_detection_enabled:
		return ""
	var head: Dictionary = raw["Head"]
	var left: Dictionary = raw["LeftWrist"]
	var right: Dictionary = raw["RightWrist"]
	if not (_pose_record_has_finite_position(head)
			and _pose_record_has_finite_position(left)
			and _pose_record_has_finite_position(right)):
		return "non_finite_required_slot"
	var head_pos: Vector3 = head["pos"]
	var left_pos: Vector3 = left["pos"]
	var right_pos: Vector3 = right["pos"]
	var body_span := maxf(
		maxf(head_pos.distance_to(left_pos), head_pos.distance_to(right_pos)),
		left_pos.distance_to(right_pos))
	if body_span < maxf(rest_pose_min_body_span_m, 0.0):
		return "collapsed_required_slots"
	var origin_eps := maxf(rest_pose_origin_epsilon_m, 0.0)
	if origin_eps > 0.0 \
			and head_pos.length() < origin_eps \
			and left_pos.length() < origin_eps \
			and right_pos.length() < origin_eps:
		return "origin_rest_pose"

	var has_quality_meta := false
	var has_live_slot := false
	var all_required_inferred := true
	for slot in REQUIRED_RETARGET_SLOTS:
		var rec: Dictionary = raw[slot]
		has_quality_meta = has_quality_meta or bool(rec.get("quality_meta", false))
		has_live_slot = has_live_slot \
				or bool(rec.get("tracked", false)) \
				or float(rec.get("confidence", 0.0)) >= maxf(rest_pose_min_confidence, 0.0)
		all_required_inferred = all_required_inferred and bool(rec.get("inferred", false))
	if has_quality_meta:
		if all_required_inferred:
			return "all_required_slots_inferred"
		if not has_live_slot:
			return "no_tracked_or_confident_required_slot"
	var source_rest_reason := _source_rest_pose_reason(raw)
	if source_rest_reason != "":
		return source_rest_reason
	return ""


func _pose_record_has_finite_position(rec: Dictionary) -> bool:
	if not rec.has("pos"):
		return false
	var pos: Vector3 = rec["pos"]
	return is_finite(pos.x) and is_finite(pos.y) and is_finite(pos.z)


func _source_rest_pose_reason(raw: Dictionary) -> String:
	if not rest_pose_source_detection_enabled:
		return ""
	var signature := _body_relative_wrist_signature(raw)
	if signature.is_empty():
		return ""
	if _source_rest_signature.is_empty():
		_source_rest_signature = signature
		return ""
	var pos_error := _source_signature_position_error(signature, _source_rest_signature)
	if pos_error > rest_pose_source_pos_epsilon_m:
		_had_non_rest_source_pose = true
		_source_rest_seen_usec = 0
		return ""
	if not _had_non_rest_source_pose \
			and _robot_joint_error_to_rest() <= maxf(rest_pose_return_joint_error_rad, 0.0):
		return ""
	var now := Time.get_ticks_usec()
	if _source_rest_seen_usec == 0:
		_source_rest_seen_usec = now
		return ""
	var hold_s := float(now - _source_rest_seen_usec) / 1_000_000.0
	if hold_s < maxf(rest_pose_source_hold_s, 0.0):
		return ""
	return "source_rest_pose"


func _body_relative_wrist_signature(raw: Dictionary) -> Dictionary:
	for slot in ["LeftShoulder", "RightShoulder", "LeftWrist", "RightWrist"]:
		if not raw.has(slot):
			return {}
		var rec: Dictionary = raw[slot]
		if not _pose_record_has_finite_position(rec):
			return {}
	var left_shoulder: Vector3 = raw["LeftShoulder"]["pos"]
	var right_shoulder: Vector3 = raw["RightShoulder"]["pos"]
	var y_axis := left_shoulder - right_shoulder
	y_axis.z = 0.0
	if y_axis.length_squared() < 0.000001:
		return {}
	y_axis = y_axis.normalized()
	var z_axis := Vector3(0.0, 0.0, 1.0)
	var x_axis := y_axis.cross(z_axis)
	if x_axis.length_squared() < 0.000001:
		return {}
	x_axis = x_axis.normalized()
	y_axis = z_axis.cross(x_axis).normalized()
	return {
		"LeftWrist": _project_to_body_frame(raw["LeftWrist"]["pos"] - left_shoulder, x_axis, y_axis, z_axis),
		"RightWrist": _project_to_body_frame(raw["RightWrist"]["pos"] - right_shoulder, x_axis, y_axis, z_axis),
	}


func _project_to_body_frame(v: Vector3, x_axis: Vector3, y_axis: Vector3, z_axis: Vector3) -> Vector3:
	return Vector3(v.dot(x_axis), v.dot(y_axis), v.dot(z_axis))


func _source_signature_position_error(a: Dictionary, b: Dictionary) -> float:
	var err := 0.0
	for slot in ["LeftWrist", "RightWrist"]:
		if not a.has(slot) or not b.has(slot):
			return INF
		var av: Vector3 = a[slot]
		var bv: Vector3 = b[slot]
		err = maxf(err, av.distance_to(bv))
	return err


func _append_direct_hand_poses(raw: Dictionary) -> void:
	var tracking_provider: Object = null
	if _provider != null:
		var tp: Variant = _provider.get("tracking_provider")
		if tp != null:
			tracking_provider = tp
	if tracking_provider == null or not tracking_provider.has_method("get_hand_joints"):
		return
	for side in [["left", 0], ["right", 1]]:
		var prefix := String(side[0])
		var hand_index := int(side[1])
		var joints_v: Variant = tracking_provider.call("get_hand_joints", hand_index)
		if typeof(joints_v) != TYPE_ARRAY:
			continue
		var hand_joints := joints_v as Array
		for i in range(mini(hand_joints.size(), DIRECT_HAND_JOINT_SUFFIXES.size())):
			var rec_v: Variant = hand_joints[i]
			if typeof(rec_v) != TYPE_DICTIONARY:
				continue
			var rec := rec_v as Dictionary
			if not bool(rec.get("tracked", false)):
				continue
			var p: Vector3 = rec.get("position", Vector3.ZERO)
			var q: Quaternion = rec.get("rotation", Quaternion.IDENTITY)
			var world_p := _xr_local_to_world_position(p)
			var world_q := _xr_local_to_world_quat(q)
			var suffix := String(DIRECT_HAND_JOINT_SUFFIXES[i])
			var pose_rec := {
				"pos": _openxr_to_gmr(world_p),
				"quat": world_q,
				"tracked": true,
				"inferred": false,
				"confidence": 1.0,
				"source": "direct_hand",
				"matched": "%s_hand_%d" % [prefix, i],
				"quality_meta": true,
			}
			raw["%s_%s" % [prefix, suffix]] = pose_rec
			if suffix == "wrist":
				raw["LeftWrist" if prefix == "left" else "RightWrist"] = pose_rec.duplicate()


func _smooth_and_align(raw: Dictionary) -> Dictionary:
	var a := clampf(input_smoothing_alpha, 0.0, 1.0)
	for stale_slot_v in _smooth_pos.keys():
		var stale_slot := String(stale_slot_v)
		if not raw.has(stale_slot):
			_smooth_pos.erase(stale_slot)
			_smooth_quat.erase(stale_slot)
	for slot in raw:
		var rec: Dictionary = raw[slot]
		var p: Vector3 = rec["pos"]
		var q: Quaternion = rec["quat"]
		if _smooth_pos.has(slot):
			_smooth_pos[slot] = (_smooth_pos[slot] as Vector3).lerp(p, a)
			_smooth_quat[slot] = (_smooth_quat[slot] as Quaternion).slerp(q, a)
		else:
			_smooth_pos[slot] = p
			_smooth_quat[slot] = q

	if not _target_initialized:
		_heading_yaw = _compute_heading_yaw()
		_target_initialized = true

	var out := {}
	var cz := cos(-_heading_yaw)
	var sz := sin(-_heading_yaw)
	var rz_q := Quaternion(0.0, 0.0, sin(-_heading_yaw / 2.0), cos(-_heading_yaw / 2.0))
	var openxr_to_gmr_q := Quaternion(0.5, -0.5, -0.5, 0.5)
	var combined_q := _qmul(rz_q, openxr_to_gmr_q)
	for slot in _smooth_pos:
		var p: Vector3 = _smooth_pos[slot]
		var q: Quaternion = _smooth_quat[slot]
		out[slot] = {
			"pos": Vector3(p.x * cz - p.y * sz, p.x * sz + p.y * cz, p.z),
			"quat": _qmul(combined_q, q).normalized(),
		}
	return out


func _solver_frame_from_aligned(aligned: Dictionary) -> Dictionary:
	var out := {}
	for name_v in aligned.keys():
		var rec: Dictionary = aligned[name_v]
		if not rec.has("pos") or not rec.has("quat"):
			continue
		var pos: Vector3 = rec["pos"]
		var quat: Quaternion = rec["quat"]
		out[String(name_v)] = Transform3D(Basis(quat), pos)
	return out


func _update_eepose_targets(aligned: Dictionary) -> bool:
	if not (aligned.has("Head") and aligned.has("LeftWrist") and aligned.has("RightWrist")):
		return false
	var head: Dictionary = aligned["Head"]
	var left: Dictionary = aligned["LeftWrist"]
	var right: Dictionary = aligned["RightWrist"]
	var head_pos: Vector3 = head["pos"]
	var left_pos: Vector3 = left["pos"]
	var right_pos: Vector3 = right["pos"]
	var left_quat: Quaternion = left["quat"]
	var right_quat: Quaternion = right["quat"]

	if not _target_initialized:
		_target_initialized = true
		_prev_head_pos = head_pos
		_prev_left_pos = left_pos
		_prev_right_pos = right_pos
		_prev_left_quat = left_quat
		_prev_right_quat = right_quat
		_left_target_pos = LEFT_TCP_REST_POS
		_right_target_pos = RIGHT_TCP_REST_POS
		_head_debug_pos = HEAD_DEBUG_REST_POS
		_left_target_quat = LEFT_TCP_REST_QUAT
		_right_target_quat = RIGHT_TCP_REST_QUAT
		return true

	var scale := maxf(workspace_scale, 0.0)
	_left_target_pos += scale * (left_pos - _prev_left_pos)
	_right_target_pos += scale * (right_pos - _prev_right_pos)
	_head_debug_pos += scale * (head_pos - _prev_head_pos)

	if use_relative_wrist_orientation:
		var left_delta := _qmul(_qconj(_prev_left_quat), left_quat).normalized()
		var right_delta := _qmul(_qconj(_prev_right_quat), right_quat).normalized()
		_left_target_quat = _qmul(_left_target_quat, left_delta).normalized()
		_right_target_quat = _qmul(_right_target_quat, right_delta).normalized()
	else:
		_left_target_quat = LEFT_TCP_REST_QUAT
		_right_target_quat = RIGHT_TCP_REST_QUAT

	_prev_head_pos = head_pos
	_prev_left_pos = left_pos
	_prev_right_pos = right_pos
	_prev_left_quat = left_quat
	_prev_right_quat = right_quat

	_left_target_pos = _clamp_reach(LEFT_ARM_BASE_POS, _left_target_pos, LEFT_ARM_REACH * arm_reach_scale)
	_right_target_pos = _clamp_reach(RIGHT_ARM_BASE_POS, _right_target_pos, RIGHT_ARM_REACH * arm_reach_scale)
	return true


func _canonical_pose(joints: Dictionary, candidates: Array) -> Dictionary:
	for cand in candidates:
		var rec_v: Variant = joints.get(cand, null)
		if typeof(rec_v) != TYPE_DICTIONARY:
			continue
		var rec := rec_v as Dictionary
		if not bool(rec.get("valid", false)):
			continue
		var pose_v: Variant = rec.get("pose", null)
		if typeof(pose_v) != TYPE_DICTIONARY:
			continue
		var pose := pose_v as Dictionary
		var p_v: Variant = pose.get("p", [])
		if typeof(p_v) != TYPE_ARRAY or (p_v as Array).size() < 3:
			continue
		var pa := p_v as Array
		var position := Vector3(float(pa[0]), float(pa[1]), float(pa[2]))
		if not (is_finite(position.x) and is_finite(position.y) and is_finite(position.z)):
			continue
		var quat := Quaternion.IDENTITY
		var q_v: Variant = pose.get("q", [])
		if typeof(q_v) == TYPE_ARRAY and (q_v as Array).size() >= 4:
			var qa := q_v as Array
			var cand_q := Quaternion(float(qa[0]), float(qa[1]), float(qa[2]), float(qa[3]))
			if cand_q.length_squared() > 0.000001:
				quat = cand_q.normalized()
		return {
			"position": position,
			"quat": quat,
			"tracked": bool(rec.get("tracked", false)),
			"inferred": bool(rec.get("inferred", false)),
			"confidence": float(rec.get("confidence", 0.0)),
			"source": String(rec.get("source", "")),
			"matched": String(cand),
			"quality_meta": rec.has("tracked") or rec.has("inferred") or rec.has("confidence"),
		}
	return {}


func _openxr_to_gmr(p: Vector3) -> Vector3:
	return Vector3(-p.z, -p.x, p.y)


func _xr_local_to_world_position(local_position: Vector3) -> Vector3:
	if _head_camera != null:
		var p := _head_camera.get_parent()
		if p is XROrigin3D:
			return (p as XROrigin3D).global_transform * local_position
	return local_position


func _xr_local_to_world_quat(local_quat: Quaternion) -> Quaternion:
	if _head_camera != null:
		var p := _head_camera.get_parent()
		if p is XROrigin3D:
			var origin_q := (p as XROrigin3D).global_transform.basis.get_rotation_quaternion()
			return _qmul(origin_q, local_quat).normalized()
	return local_quat


func _build_debug_pose_points(aligned: Dictionary) -> Dictionary:
	var head_key := "head" if aligned.has("head") else "Head"
	if not aligned.has(head_key):
		return {
			"head": _head_debug_pos,
			"left_wrist": _left_target_pos,
			"right_wrist": _right_target_pos,
		}
	var head: Dictionary = aligned[head_key]
	var head_pos: Vector3 = head["pos"]
	var scale := maxf(workspace_scale, 0.0)
	var points := {}
	for name_v in aligned.keys():
		var joint_name := String(name_v)
		if not _is_debug_joint_name(joint_name):
			continue
		var rec: Dictionary = aligned[joint_name]
		var p: Vector3 = rec["pos"]
		points[joint_name] = _head_debug_pos + (p - head_pos) * scale
	if not points.has("head"):
		points["head"] = _head_debug_pos
	if not points.has("left_wrist"):
		points["left_wrist"] = _left_target_pos
	if not points.has("right_wrist"):
		points["right_wrist"] = _right_target_pos
	return points


func _is_debug_joint_name(joint_name: String) -> bool:
	if joint_name == "Head" or joint_name == "LeftWrist" or joint_name == "RightWrist":
		return false
	if joint_name in [
		"hips",
		"spine",
		"chest",
		"upper_chest",
		"neck",
		"head",
		"left_scapula",
		"left_shoulder",
		"left_upper_arm",
		"left_lower_arm",
		"right_scapula",
		"right_shoulder",
		"right_upper_arm",
		"right_lower_arm",
	]:
		return true
	return _is_hand_debug_joint(joint_name)


func _is_hand_debug_joint(joint_name: String) -> bool:
	var is_left := joint_name.begins_with("left_")
	var is_right := joint_name.begins_with("right_")
	if not is_left and not is_right:
		return false
	return joint_name.contains("hand") \
			or joint_name.contains("palm") \
			or joint_name.contains("wrist") \
			or joint_name.contains("thumb") \
			or joint_name.contains("finger")


func _compute_heading_yaw() -> float:
	if _head_camera == null:
		return 0.0
	var basis := _head_camera.global_transform.basis.orthonormalized()
	var forward := -basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return 0.0
	forward = forward.normalized()
	var fwd_gmr := _openxr_to_gmr(forward)
	return atan2(fwd_gmr.y, fwd_gmr.x)


func _clamp_reach(base: Vector3, target: Vector3, max_reach: float) -> Vector3:
	var v := target - base
	var n := v.length()
	if max_reach <= 0.0 or n <= max_reach:
		return target
	return base + v * (max_reach / n)


func _qmul(a: Quaternion, b: Quaternion) -> Quaternion:
	return Quaternion(
		a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
		a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)


func _qconj(q: Quaternion) -> Quaternion:
	return Quaternion(-q.x, -q.y, -q.z, q.w)


# --- Head/leg locked-qpos control -----------------------------------------


func _update_head_leg_control(aligned: Dictionary) -> void:
	if not head_control_enabled and not head_height_control_enabled and not body_yaw_control_enabled:
		return
	var dt := _next_head_leg_control_dt()
	if not _head_control_initialized:
		_capture_head_control_reference(aligned)
	var target_head := _rest_head_joint_q()
	if head_control_enabled:
		var yaw_pitch := _head_control_yaw_pitch(aligned)
		target_head[0] = _clamp_joint_q(
			HEAD_JOINT_NAMES[0],
			yaw_pitch.x * head_yaw_scale * head_yaw_sign)
		target_head[1] = _clamp_joint_q(
			HEAD_JOINT_NAMES[1],
			yaw_pitch.y * head_pitch_scale * head_pitch_sign)

	var target_leg := _rest_leg_joint_q()
	if head_height_control_enabled:
		target_leg = _leg_joint_q_from_height_delta(_head_height_delta(aligned))
	if body_yaw_control_enabled:
		target_leg[BODY_YAW_LEG_JOINT_INDEX] = _clamp_joint_q(
			BODY_YAW_JOINT_NAME,
			float(REST_LEG_JOINT_Q[BODY_YAW_LEG_JOINT_INDEX])
					+ _body_yaw_delta(aligned) * body_yaw_scale * body_yaw_sign)

	_head_joint_q = _approach_named_joint_q(
		_ensure_head_joint_q(),
		target_head,
		HEAD_JOINT_NAMES,
		dt,
		maxf(head_control_tau_s, 0.001))
	_leg_joint_q = _approach_named_joint_q(
		_ensure_leg_joint_q(),
		target_leg,
		LEG_JOINT_NAMES,
		dt,
		maxf(leg_height_tau_s, 0.001))
	_sync_head_leg_to_current_qpos(true)
	_apply_locked_control_pose()


func _next_head_leg_control_dt() -> float:
	var now := Time.get_ticks_usec()
	var dt := 0.016
	if _last_head_leg_control_usec > 0:
		dt = float(now - _last_head_leg_control_usec) / 1_000_000.0
	_last_head_leg_control_usec = now
	return clampf(dt, 0.001, 0.1)


func _capture_head_control_reference(aligned: Dictionary) -> void:
	if _head_camera != null:
		_head_control_ref_basis = _head_camera.global_transform.basis.orthonormalized()
		_head_control_ref_height = _head_camera.global_transform.origin.y
	else:
		var head_v: Variant = aligned.get("Head", null)
		if typeof(head_v) == TYPE_DICTIONARY:
			var head := head_v as Dictionary
			var q: Quaternion = head.get("quat", Quaternion.IDENTITY)
			_head_control_ref_quat = q.normalized()
			_head_control_ref_basis = Basis(_head_control_ref_quat).orthonormalized()
			var p: Vector3 = head.get("pos", HEAD_DEBUG_REST_POS)
			_head_control_ref_height = p.z
		else:
			_head_control_ref_quat = Quaternion.IDENTITY
			_head_control_ref_basis = Basis.IDENTITY
			_head_control_ref_height = 0.0
	_head_control_ref_body_yaw = _body_yaw_from_pose(aligned)
	var head_yaw_pitch := _head_world_yaw_pitch(aligned)
	_head_control_ref_head_body_yaw = _wrap_angle(head_yaw_pitch.x - _head_control_ref_body_yaw)
	_head_control_ref_head_pitch = head_yaw_pitch.y
	_head_control_initialized = true


func _head_control_yaw_pitch(aligned: Dictionary) -> Vector2:
	var body_yaw := _body_yaw_from_pose(aligned)
	var head_yaw_pitch := _head_world_yaw_pitch(aligned)
	var head_body_yaw := _wrap_angle(head_yaw_pitch.x - body_yaw)
	return Vector2(
		_wrap_angle(head_body_yaw - _head_control_ref_head_body_yaw),
		head_yaw_pitch.y - _head_control_ref_head_pitch)


func _head_world_yaw_pitch(aligned: Dictionary) -> Vector2:
	if _head_camera != null:
		var basis := _head_camera.global_transform.basis.orthonormalized()
		var forward := _heading_aligned_gmr_vector(_openxr_to_gmr(-basis.z))
		if forward.length_squared() >= 0.000001:
			forward = forward.normalized()
			var flat := sqrt(forward.x * forward.x + forward.y * forward.y)
			return Vector2(atan2(forward.y, forward.x), atan2(forward.z, flat))
	var head_v: Variant = aligned.get("Head", null)
	if typeof(head_v) != TYPE_DICTIONARY:
		return Vector2.ZERO
	var head := head_v as Dictionary
	var q: Quaternion = head.get("quat", Quaternion.IDENTITY)
	if q.length_squared() < 0.000001:
		return Vector2.ZERO
	var fallback_basis := Basis(q.normalized()).orthonormalized()
	var fallback_forward := fallback_basis.x
	if fallback_forward.length_squared() < 0.000001:
		return Vector2.ZERO
	fallback_forward = fallback_forward.normalized()
	var flat := sqrt(
		fallback_forward.x * fallback_forward.x
		+ fallback_forward.y * fallback_forward.y)
	return Vector2(
		atan2(fallback_forward.y, fallback_forward.x),
		atan2(fallback_forward.z, flat))


func _heading_aligned_gmr_vector(v: Vector3) -> Vector3:
	var cz := cos(-_heading_yaw)
	var sz := sin(-_heading_yaw)
	return Vector3(v.x * cz - v.y * sz, v.x * sz + v.y * cz, v.z)


func _body_yaw_delta(aligned: Dictionary) -> float:
	return _wrap_angle(_body_yaw_from_pose(aligned) - _head_control_ref_body_yaw)


func _body_yaw_from_pose(aligned: Dictionary) -> float:
	if not (aligned.has("LeftShoulder") and aligned.has("RightShoulder")):
		return _head_control_ref_body_yaw
	var left: Dictionary = aligned["LeftShoulder"]
	var right: Dictionary = aligned["RightShoulder"]
	var left_pos: Vector3 = left.get("pos", Vector3.ZERO)
	var right_pos: Vector3 = right.get("pos", Vector3.ZERO)
	var y_axis := left_pos - right_pos
	y_axis.z = 0.0
	if y_axis.length_squared() < 0.000001:
		return _head_control_ref_body_yaw
	y_axis = y_axis.normalized()
	var x_axis := y_axis.cross(Vector3(0.0, 0.0, 1.0))
	if x_axis.length_squared() < 0.000001:
		return _head_control_ref_body_yaw
	x_axis = x_axis.normalized()
	return atan2(x_axis.y, x_axis.x)


func _wrap_angle(angle: float) -> float:
	return wrapf(angle + PI, 0.0, TAU) - PI


func _head_height_delta(aligned: Dictionary) -> float:
	if _head_camera != null:
		return _head_camera.global_transform.origin.y - _head_control_ref_height
	var head_v: Variant = aligned.get("Head", null)
	if typeof(head_v) != TYPE_DICTIONARY:
		return 0.0
	var head := head_v as Dictionary
	var p: Vector3 = head.get("pos", HEAD_DEBUG_REST_POS)
	return p.z - _head_control_ref_height


func _leg_joint_q_from_height_delta(delta_m: float) -> PackedFloat64Array:
	var rest := _rest_leg_joint_q()
	var target := rest.duplicate()
	var deadzone := maxf(head_height_deadzone_m, 0.0)
	var adjusted := 0.0
	var profile: Array = LEG_HEIGHT_UP_JOINT_Q
	var range_m := maxf(head_height_up_range_m, 0.001)
	if delta_m > deadzone:
		adjusted = delta_m - deadzone
		profile = LEG_HEIGHT_UP_JOINT_Q
		range_m = maxf(head_height_up_range_m, 0.001)
	elif delta_m < -deadzone:
		adjusted = -delta_m - deadzone
		profile = LEG_HEIGHT_DOWN_JOINT_Q
		range_m = maxf(head_height_down_range_m, 0.001)
	else:
		return target
	var t := clampf(adjusted / range_m, 0.0, 1.0)
	for i in range(mini(target.size(), profile.size())):
		if i == BODY_YAW_LEG_JOINT_INDEX:
			continue
		var q := rest[i] + (float(profile[i]) - rest[i]) * t
		target[i] = _clamp_joint_q(LEG_JOINT_NAMES[i], q)
	return target


func _approach_named_joint_q(
		current: PackedFloat64Array,
		target: PackedFloat64Array,
		joint_names: Array,
		dt: float,
		tau_s: float) -> PackedFloat64Array:
	var out := current.duplicate()
	if out.size() != target.size():
		out = target.duplicate()
		return out
	var alpha := 1.0 - exp(-dt / maxf(tau_s, 0.001))
	for i in range(out.size()):
		var joint_name := String(joint_names[i])
		out[i] = _clamp_joint_q(joint_name, out[i] + (target[i] - out[i]) * alpha)
	return out


func _ensure_leg_joint_q() -> PackedFloat64Array:
	if _leg_joint_q.size() == LEG_JOINT_NAMES.size():
		return _leg_joint_q.duplicate()
	var out := _rest_leg_joint_q()
	for i in range(LEG_JOINT_NAMES.size()):
		out[i] = _joint_q_from_current(String(LEG_JOINT_NAMES[i]), out[i])
	_leg_joint_q = out.duplicate()
	return out


func _ensure_head_joint_q() -> PackedFloat64Array:
	if _head_joint_q.size() == HEAD_JOINT_NAMES.size():
		return _head_joint_q.duplicate()
	var out := _rest_head_joint_q()
	for i in range(HEAD_JOINT_NAMES.size()):
		out[i] = _joint_q_from_current(String(HEAD_JOINT_NAMES[i]), out[i])
	_head_joint_q = out.duplicate()
	return out


func _rest_leg_joint_q() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(REST_LEG_JOINT_Q.size())
	for i in range(out.size()):
		out[i] = _clamp_joint_q(LEG_JOINT_NAMES[i], float(REST_LEG_JOINT_Q[i]))
	return out


func _rest_head_joint_q() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(REST_HEAD_JOINT_Q.size())
	for i in range(out.size()):
		out[i] = _clamp_joint_q(HEAD_JOINT_NAMES[i], float(REST_HEAD_JOINT_Q[i]))
	return out


func _joint_q_from_current(joint_name: String, fallback: float) -> float:
	if _current_qpos.is_empty():
		return fallback
	var spec_v: Variant = _joint_specs.get(joint_name, null)
	if typeof(spec_v) != TYPE_DICTIONARY:
		return fallback
	var spec := spec_v as Dictionary
	var qi := int(spec["qpos"])
	if qi < 0 or qi >= _current_qpos.size():
		return fallback
	return float(_current_qpos[qi])


func _clamp_joint_q(joint_name: String, q: float) -> float:
	var spec_v: Variant = _joint_specs.get(joint_name, null)
	if typeof(spec_v) != TYPE_DICTIONARY:
		return q
	var spec := spec_v as Dictionary
	if not bool(spec.get("limited", false)):
		return q
	return clampf(q, float(spec.get("range_min", -INF)), float(spec.get("range_max", INF)))


func _locked_control_joint_q() -> PackedFloat64Array:
	var leg := _ensure_leg_joint_q()
	var head := _ensure_head_joint_q()
	var out := PackedFloat64Array()
	out.resize(LOCKED_CONTROL_JOINT_NAMES.size())
	for i in range(LEG_JOINT_NAMES.size()):
		out[i] = leg[i] if i < leg.size() else 0.0
	for i in range(HEAD_JOINT_NAMES.size()):
		var out_i := LEG_JOINT_NAMES.size() + i
		out[out_i] = head[i] if i < head.size() else 0.0
	return out


func _robot_pose_from_locked_control_q() -> Dictionary:
	return {
		"joint_names": _locked_control_joint_names_packed,
		"joint_q": _locked_control_joint_q(),
		"scenario": SCENARIO,
		"algorithm": ALGORITHM,
		"mode": "head_leg_control",
	}


func _apply_locked_control_pose() -> void:
	_apply_robot_pose(_robot_pose_from_locked_control_q())


func _sync_head_leg_to_current_qpos(push_to_retargeter: bool) -> void:
	if _current_qpos.is_empty():
		return
	var q := _locked_control_joint_q()
	for i in range(mini(q.size(), _locked_control_qpos_indices.size())):
		var qi := _locked_control_qpos_indices[i]
		if qi >= 0 and qi < _current_qpos.size():
			_current_qpos[qi] = q[i]
			if _filtered_qpos.size() == _current_qpos.size():
				_filtered_qpos[qi] = q[i]
	if push_to_retargeter and _retargeter != null:
		_retargeter.call("set_configuration", _current_qpos)


func _debug_joint_q(qs: PackedFloat64Array) -> Array:
	var out := []
	for i in range(qs.size()):
		out.append(snappedf(qs[i], 0.001))
	return out


# --- Rest-pose return ------------------------------------------------------


func _handle_unusable_vr_pose(reason: String) -> void:
	_reset_vr_target_state()
	if rest_return_enabled:
		_begin_rest_return(reason)


func _mark_vr_pose_valid() -> void:
	_last_pose_valid_usec = Time.get_ticks_usec()
	if _rest_return_active:
		_rest_return_active = false
		_last_rest_reason = ""
		_reset_vr_target_state()
	if _retarget_reset_pending:
		_reset_retargeter_with_current_qpos()
		_retarget_reset_pending = false


func _begin_rest_return(reason: String) -> void:
	if _rest_return_active and _last_rest_reason == reason:
		return
	_rest_return_active = true
	_last_rest_reason = reason
	_last_rest_step_usec = Time.get_ticks_usec()
	_retarget_reset_pending = true
	_reset_vr_target_state()


func _reset_vr_target_state() -> void:
	_target_initialized = false
	_head_control_initialized = false
	_head_control_ref_body_yaw = 0.0
	_head_control_ref_head_body_yaw = 0.0
	_head_control_ref_head_pitch = 0.0
	_last_head_leg_control_usec = 0
	_smooth_pos.clear()
	_smooth_quat.clear()
	_prev_head_pos = Vector3.ZERO
	_prev_left_pos = Vector3.ZERO
	_prev_right_pos = Vector3.ZERO
	_prev_left_quat = Quaternion.IDENTITY
	_prev_right_quat = Quaternion.IDENTITY
	_left_target_pos = LEFT_TCP_REST_POS
	_right_target_pos = RIGHT_TCP_REST_POS
	_head_debug_pos = HEAD_DEBUG_REST_POS
	_left_target_quat = LEFT_TCP_REST_QUAT
	_right_target_quat = RIGHT_TCP_REST_QUAT


func _advance_rest_return(delta: float) -> void:
	var current := _ensure_display_joint_q()
	if current.size() != REST_ARM_JOINT_Q.size():
		return
	var dt := delta
	var now := Time.get_ticks_usec()
	if dt <= 0.0:
		if _last_rest_step_usec > 0:
			dt = float(now - _last_rest_step_usec) / 1_000_000.0
		else:
			dt = 0.016
	_last_rest_step_usec = now
	dt = clampf(dt, 0.001, 0.1)
	var alpha := 1.0 - exp(-dt / maxf(rest_return_tau_s, 0.001))
	var cap := maxf(rest_return_vmax, 0.0) * dt
	var max_error := 0.0
	for i in range(current.size()):
		var target := float(REST_ARM_JOINT_Q[i])
		var error := target - current[i]
		max_error = maxf(max_error, absf(error))
		var step := alpha * error
		if cap > 0.0:
			step = clampf(step, -cap, cap)
		current[i] += step
	if max_error <= maxf(rest_return_epsilon_rad, 0.0):
		current = _rest_joint_q()
	_display_joint_q = current.duplicate()
	_apply_joint_q_to_current_qpos(current)
	_apply_robot_pose(_robot_pose_from_joint_q(current))
	_head_joint_q = _approach_named_joint_q(
		_ensure_head_joint_q(),
		_rest_head_joint_q(),
		HEAD_JOINT_NAMES,
		dt,
		maxf(rest_return_tau_s, 0.001))
	_leg_joint_q = _approach_named_joint_q(
		_ensure_leg_joint_q(),
		_rest_leg_joint_q(),
		LEG_JOINT_NAMES,
		dt,
		maxf(rest_return_tau_s, 0.001))
	_sync_head_leg_to_current_qpos(true)
	_apply_locked_control_pose()


func _ensure_display_joint_q() -> PackedFloat64Array:
	if _display_joint_q.size() == REST_ARM_JOINT_Q.size():
		return _display_joint_q.duplicate()
	var out := PackedFloat64Array()
	out.resize(REST_ARM_JOINT_Q.size())
	for i in range(out.size()):
		var qi := _arm_qpos_indices[i] if i < _arm_qpos_indices.size() else -1
		if _current_qpos.size() > 0 and qi >= 0 and qi < _current_qpos.size():
			out[i] = _current_qpos[qi]
		else:
			out[i] = float(REST_ARM_JOINT_Q[i])
	_display_joint_q = out.duplicate()
	return out


func _rest_joint_q() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(REST_ARM_JOINT_Q.size())
	for i in range(out.size()):
		out[i] = float(REST_ARM_JOINT_Q[i])
	return out


func _robot_joint_error_to_rest() -> float:
	var qs := _ensure_display_joint_q()
	if qs.size() != REST_ARM_JOINT_Q.size():
		return 0.0
	var err := 0.0
	for i in range(qs.size()):
		err = maxf(err, absf(qs[i] - float(REST_ARM_JOINT_Q[i])))
	var leg_q := _ensure_leg_joint_q()
	for i in range(mini(leg_q.size(), REST_LEG_JOINT_Q.size())):
		err = maxf(err, absf(leg_q[i] - float(REST_LEG_JOINT_Q[i])))
	var head_q := _ensure_head_joint_q()
	for i in range(mini(head_q.size(), REST_HEAD_JOINT_Q.size())):
		err = maxf(err, absf(head_q[i] - float(REST_HEAD_JOINT_Q[i])))
	return err


func _apply_joint_q_to_current_qpos(joint_q: PackedFloat64Array) -> void:
	if _current_qpos.is_empty():
		return
	for i in range(mini(joint_q.size(), _arm_qpos_indices.size())):
		var qi := _arm_qpos_indices[i]
		if qi >= 0 and qi < _current_qpos.size():
			_current_qpos[qi] = joint_q[i]
	if _retargeter != null:
		_retargeter.call("set_configuration", _current_qpos)
	_filtered_qpos = _current_qpos.duplicate()
	_filter_last_us = Time.get_ticks_usec()


func _reset_retargeter_with_current_qpos() -> void:
	var qpos := _current_qpos.duplicate()
	_retargeter = null
	_retarget_active = false
	_setup_retargeter()
	if _retarget_active and _retargeter != null and not qpos.is_empty():
		_retargeter.call("set_configuration", qpos)
		_current_qpos = qpos.duplicate()


# --- Robot pose output -----------------------------------------------------


func _filter_arm_qpos(qpos: PackedFloat64Array) -> PackedFloat64Array:
	var now := Time.get_ticks_usec()
	if _filtered_qpos.size() != qpos.size() or _filter_last_us == 0:
		_filtered_qpos = qpos.duplicate()
		_filter_last_us = now
		return qpos
	var out := qpos.duplicate()
	var dt := clampf(float(now - _filter_last_us) / 1_000_000.0, 0.001, 0.1)
	_filter_last_us = now
	var a := 1.0 - exp(-dt / maxf(output_filter_tau_s, 0.001))
	var cap := output_filter_vmax * dt
	for qi in _arm_qpos_indices:
		if qi < 0 or qi >= qpos.size():
			continue
		var prev: float = _filtered_qpos[qi]
		var step: float = clampf(a * (qpos[qi] - prev), -cap, cap)
		out[qi] = prev + step
	_filtered_qpos = out.duplicate()
	return out


func _robot_pose_from_qpos(qpos: PackedFloat64Array) -> Dictionary:
	var joint_q := PackedFloat64Array()
	joint_q.resize(_arm_qpos_indices.size())
	for i in range(_arm_qpos_indices.size()):
		var qi := _arm_qpos_indices[i]
		joint_q[i] = qpos[qi] if qi >= 0 and qi < qpos.size() else 0.0
	return {
		"joint_names": _arm_joint_names_packed,
		"joint_q": joint_q,
		"qpos": qpos,
		"scenario": SCENARIO,
		"algorithm": ALGORITHM,
	}


func _robot_pose_from_joint_q(joint_q: PackedFloat64Array) -> Dictionary:
	return {
		"joint_names": _arm_joint_names_packed,
		"joint_q": joint_q,
		"scenario": SCENARIO,
		"algorithm": ALGORITHM,
		"mode": "rest_return",
	}


func _remember_robot_pose(robot_pose: Dictionary) -> void:
	var qpos: PackedFloat64Array = robot_pose.get("qpos", PackedFloat64Array())
	if not qpos.is_empty():
		_current_qpos = qpos.duplicate()
	var qs: PackedFloat64Array = robot_pose.get("joint_q", PackedFloat64Array())
	if qs.size() == REST_ARM_JOINT_Q.size():
		_display_joint_q = qs.duplicate()
	elif not _current_qpos.is_empty():
		var stored_pose := _robot_pose_from_qpos(_current_qpos)
		var stored_qs: PackedFloat64Array = stored_pose.get("joint_q", PackedFloat64Array())
		_display_joint_q = stored_qs.duplicate()


func _apply_robot_pose(robot_pose: Dictionary) -> void:
	var names: PackedStringArray = robot_pose.get("joint_names", PackedStringArray())
	var qs: PackedFloat64Array = robot_pose.get("joint_q", PackedFloat64Array())
	if names.size() != qs.size():
		return
	for i in range(names.size()):
		var joint_name := String(names[i])
		var spec_v: Variant = _joint_specs.get(joint_name, null)
		if typeof(spec_v) != TYPE_DICTIONARY:
			continue
		var spec := spec_v as Dictionary
		var body_name: String = spec["body"]
		var node: Node3D = _link_nodes.get(body_name, null)
		if node == null:
			continue
		var rest: Transform3D = _rest_local.get(body_name, node.transform)
		var axis: Vector3 = spec["axis"]
		if axis.length_squared() < 0.000001:
			continue
		var godot_axis := Vector3(-axis.y, axis.z, -axis.x).normalized()
		node.transform = rest * Transform3D(Basis(godot_axis, float(qs[i])), Vector3.ZERO)
	var qpos: PackedFloat64Array = robot_pose.get("qpos", PackedFloat64Array())
	if not qpos.is_empty():
		qpos_updated.emit(qpos)


func apply_remote_qpos(qpos: PackedFloat64Array) -> void:
	for value in qpos:
		if not is_finite(value):
			return
	var shown := _filter_arm_qpos(qpos) if output_filter_enabled else qpos
	var robot_pose := _robot_pose_from_qpos(shown)
	_apply_robot_pose(robot_pose)
	_remember_robot_pose(robot_pose)


# --- VR-pose debug skeleton ------------------------------------------------


func _ensure_vr_pose_nodes() -> void:
	if _vr_pose_root != null or _glb_instance == null:
		return
	_vr_pose_root = Node3D.new()
	_vr_pose_root.name = "GalbotEePoseDebug"
	_glb_instance.add_child(_vr_pose_root)

	_vr_body_mat = _make_debug_material(Color(0.2, 0.7, 1.0))
	_vr_left_hand_mat = _make_debug_material(Color(0.35, 0.95, 1.0))
	_vr_right_hand_mat = _make_debug_material(Color(1.0, 0.72, 0.25))

	var bones := MeshInstance3D.new()
	bones.name = "GalbotEePoseDebugBones"
	_vr_bone_mesh = ImmediateMesh.new()
	bones.mesh = _vr_bone_mesh
	bones.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vr_pose_root.add_child(bones)


func _make_debug_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.92)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.8
	mat.no_depth_test = true
	mat.render_priority = 5
	return mat


func _ensure_debug_marker(joint_name: String) -> MeshInstance3D:
	if _vr_pose_spheres.has(joint_name):
		return _vr_pose_spheres[joint_name] as MeshInstance3D
	var sphere := SphereMesh.new()
	var radius := 0.018 if _is_hand_debug_joint(joint_name) else 0.03
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	var mi := MeshInstance3D.new()
	mi.name = "VRPose_%s" % joint_name
	mi.mesh = sphere
	mi.material_override = _debug_material_for_joint(joint_name)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vr_pose_root.add_child(mi)
	_vr_pose_spheres[joint_name] = mi
	return mi


func _debug_material_for_joint(joint_name: String) -> StandardMaterial3D:
	if joint_name.begins_with("left_"):
		return _vr_left_hand_mat if _is_hand_debug_joint(joint_name) else _vr_body_mat
	if joint_name.begins_with("right_"):
		return _vr_right_hand_mat if _is_hand_debug_joint(joint_name) else _vr_body_mat
	return _vr_body_mat


func _clear_vr_pose() -> void:
	if _vr_pose_root == null:
		return
	_vr_pose_last_local.clear()
	for marker_v in _vr_pose_spheres.values():
		(marker_v as MeshInstance3D).visible = false
	if _vr_bone_mesh != null:
		_vr_bone_mesh.clear_surfaces()


func _update_vr_pose(points: Dictionary) -> void:
	_ensure_vr_pose_nodes()
	if _vr_pose_root == null:
		return
	for joint_name_v in points.keys():
		var joint_name := String(joint_name_v)
		var g: Vector3 = points[joint_name] - ROBOT_BASE_POS
		var p := Vector3(-g.y, g.z, -g.x) + debug_vr_pose_offset
		_vr_pose_last_local[joint_name] = p
	for joint_name_v in _vr_pose_last_local.keys():
		var joint_name := String(joint_name_v)
		var marker := _ensure_debug_marker(joint_name)
		var p: Vector3 = _vr_pose_last_local[joint_name]
		marker.position = p
		marker.visible = true
	_vr_bone_mesh.clear_surfaces()
	_draw_debug_links(_vr_pose_last_local, UPPER_BODY_BONE_LINKS, _vr_body_mat)
	for side in ["left", "right"]:
		var mat := _vr_left_hand_mat if side == "left" else _vr_right_hand_mat
		_draw_debug_links(_vr_pose_last_local, _hand_debug_links(side), mat)


func _hand_debug_links(side: String) -> Array:
	var links: Array = []
	for chain_v in HAND_FINGER_CHAINS:
		var chain := chain_v as Array
		for i in range(chain.size() - 1):
			links.append([String(chain[i]) % side, String(chain[i + 1]) % side])
	for link_v in HAND_ROOT_FALLBACK_LINKS:
		var link := link_v as Array
		var blockers: Array = []
		for blocker_v in (link[2] as Array):
			blockers.append(String(blocker_v) % side)
		links.append([String(link[0]) % side, String(link[1]) % side, blockers])
	return links


func _draw_debug_links(local: Dictionary, links: Array, material: Material) -> void:
	var vertices: Array = []
	for link_v in links:
		var link := link_v as Array
		var a := String(link[0])
		var b := String(link[1])
		if not local.has(a) or not local.has(b):
			continue
		if link.size() >= 3:
			var blocked := false
			for blocker_v in (link[2] as Array):
				if local.has(String(blocker_v)):
					blocked = true
					break
			if blocked:
				continue
		var pa: Vector3 = local[a]
		var pb: Vector3 = local[b]
		if pa.distance_to(pb) > _max_debug_bone_length(a, b):
			continue
		vertices.append(pa)
		vertices.append(pb)
	if vertices.is_empty():
		return
	_vr_bone_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for vertex_v in vertices:
		_vr_bone_mesh.surface_add_vertex(vertex_v as Vector3)
	_vr_bone_mesh.surface_end()


func _max_debug_bone_length(a: String, b: String) -> float:
	if _is_hand_debug_joint(a) and _is_hand_debug_joint(b):
		return 0.18
	if (a.ends_with("_lower_arm") and b.ends_with("_wrist")) \
			or (b.ends_with("_lower_arm") and a.ends_with("_wrist")):
		return 0.55
	return 0.80


# --- Anchoring -------------------------------------------------------------


func _lock_in_front_of_view() -> bool:
	if _debug_front_locked:
		return true
	if _head_camera == null or _glb_instance == null:
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
	anchor.y = _xr_floor_y() + debug_front_vertical_offset_m
	_glb_instance.global_transform = Transform3D(Basis(Vector3.UP, yaw), anchor) * _glb_instance_rest
	_debug_front_locked = true
	return true


func _xr_floor_y() -> float:
	if _head_camera != null:
		var p := _head_camera.get_parent()
		if p is XROrigin3D:
			return (p as XROrigin3D).global_transform.origin.y
	return 0.0
