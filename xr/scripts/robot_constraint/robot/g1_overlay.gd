class_name G1Overlay
extends Node3D

## In-headset overlay of the Unitree G1 robot, driven by retargeting.
##
## Loads the baked G1 GLB (which preserves the full URDF link hierarchy), tints
## it translucent, world-locks it one metre in front of the operator, and — when
## the native GMRRetargeter GDExtension is available — drives the upper body each
## frame by retargeting the operator's tracked VR body pose onto G1 joint angles
## (GMR algorithm, MuJoCo backend). If the extension or a body frame is missing
## it degrades to a static rest-pose overlay (same behaviour as H2Overlay).
##
## Pipeline per frame:
##   canonical VR body frame  -> GMR-coordinate source poses (position tasks)
##   -> GMRRetargeter.step()  -> qpos (MuJoCo convention)
##   -> forward kinematics on the GLB link nodes (joint axis * angle).

const GLB_PATH := "res://assets/robots/unitree-g1/g1_29dof.glb"
const MOCAP_XML := "res://assets/retargeting/g1_mocap_29dof_nomesh.xml"
const IK_CONFIG := "res://assets/retargeting/quest3_upper_to_g1.json"

## G1: hold the floating base (7) + 12 lower-body joints fixed (qpos[0..18]).
const LOCKED_QPOS_PREFIX := 19
const HUMAN_HEIGHT := 1.75
## Hips are pinned to this height in GMR coords each frame (Python --pelvis_height).
const PELVIS_HEIGHT := 0.88
## Exponential smoothing on the tracked joint positions (0 = frozen, 1 = none).
## Body tracking jitters a few cm per joint; because every target is computed
## relative to the (also-jittering) hips and the robot base is frozen, the IK
## amplifies that noise into flailing/drooping arms. Low-passing the input fixes
## it. Lower = smoother but laggier.
const SMOOTH_ALPHA := 0.25

## Additionally clamp these joints to rest each frame (reset before the solve +
## held after), so the arms + waist-yaw track but the torso stays upright and the
## wrists stay neutral. This matches the GMR spatialmp4_body_to_g1 pipeline
## exactly (validated to machine precision), and fixes the upper body falling
## backward when the hands were raised (the waist roll/pitch are held at 0).
const CLAMP_JOINT_NAMES := [
	"waist_roll_joint", "waist_pitch_joint",
	"left_wrist_roll_joint", "left_wrist_pitch_joint", "left_wrist_yaw_joint",
	"right_wrist_roll_joint", "right_wrist_pitch_joint", "right_wrist_yaw_joint",
]

## Canonical (Godot XRBodyTracker) joint -> GMR human-joint name. Only the
## joints the ik_config drives (position tasks) are needed; fallbacks handle
## trackers that omit a joint.
const JOINT_MAP := {
	"Hips": ["hips"],
	"Chest": ["chest", "upper_chest", "spine"],
	"LeftShoulder": ["left_shoulder", "left_upper_arm"],
	"LeftArmLower": ["left_lower_arm"],
	"LeftWrist": ["left_wrist", "left_hand"],
	"RightShoulder": ["right_shoulder", "right_upper_arm"],
	"RightArmLower": ["right_lower_arm"],
	"RightWrist": ["right_wrist", "right_hand"],
}

@export var attach_under: NodePath
@export var debug_place_in_front_of_view: bool = true
@export var debug_front_distance_m: float = 1.0
@export var debug_front_vertical_offset_m: float = -0.15
@export var overlay_alpha: float = 0.55
@export var overlay_tint: Color = Color(0.78, 0.9, 0.7, 1.0)

# --- GLB nodes ------------------------------------------------------------
var _link_nodes: Dictionary = {}            # link_name -> Node3D
var _rest_local: Dictionary = {}            # link_name -> Transform3D (rest local)
var _overlay_materials: Array = []
var _pelvis_node: Node3D = null
var _pelvis_rest_transform: Transform3D = Transform3D.IDENTITY
var _head_camera: Node3D = null
var _debug_front_locked: bool = false

# --- Retargeting ----------------------------------------------------------
var _retargeter: Object = null              # GMRRetargeter instance (native)
var _provider: Node = null                  # BodyPoseProvider
# qpos joint table, in qpos order: [{ "name": String, "body": String, "axis": Vector3 }, ...]
var _qpos_joints: Array = []
var _clamp_indices: PackedInt32Array = PackedInt32Array()
var _retarget_active: bool = false
var _heading_yaw: float = 0.0
var _heading_computed: bool = false
var _smooth: Dictionary = {}    # gmr_name -> smoothed raw Vector3 (position)
var _smooth_q: Dictionary = {}  # gmr_name -> smoothed Quaternion (orientation)


func _ready() -> void:
	if not ResourceLoader.exists(GLB_PATH):
		push_error("[G1Overlay] GLB not found at %s. Run scripts/make-robot/make_g1.sh." % GLB_PATH)
		return
	_load_glb()
	if _pelvis_node == null:
		push_error("[G1Overlay] GLB did not contain a 'pelvis' node; overlay disabled.")
		return
	_apply_overlay_material()
	_parse_mocap_joints()
	_setup_retargeter()
	if debug_place_in_front_of_view:
		call_deferred("_lock_in_front_of_view")
	print("[G1Overlay] ready: %d links, %d qpos joints, retarget=%s" % [
		_link_nodes.size(), _qpos_joints.size(), str(_retarget_active)])


func _process(_delta: float) -> void:
	if debug_place_in_front_of_view and not _debug_front_locked:
		_lock_in_front_of_view()


func set_head_camera(camera: Node3D) -> void:
	_head_camera = camera
	if is_inside_tree() and debug_place_in_front_of_view and not _debug_front_locked:
		call_deferred("_lock_in_front_of_view")


## Connect a BodyPoseProvider so the overlay is animated by live VR body pose.
func set_body_pose_provider(provider: Node) -> void:
	_provider = provider
	if provider != null and provider.has_signal("canonical_frame_ready"):
		if not provider.is_connected("canonical_frame_ready", Callable(self, "_on_canonical_frame_ready")):
			provider.connect("canonical_frame_ready", Callable(self, "_on_canonical_frame_ready"))


# --- GLB load --------------------------------------------------------------


func _load_glb() -> void:
	var packed: PackedScene = load(GLB_PATH)
	if packed == null:
		push_error("[G1Overlay] failed to load GLB: %s" % GLB_PATH)
		return
	var instance: Node = packed.instantiate()
	var parent: Node3D = self
	if not attach_under.is_empty():
		var target := get_node_or_null(attach_under)
		if target is Node3D:
			parent = target
	parent.add_child(instance)
	_index_subtree(instance)
	_pelvis_node = _link_nodes.get("pelvis", null)


func _index_subtree(node: Node) -> void:
	if node is Node3D:
		var nm := node.name
		if nm != "" and not _link_nodes.has(nm):
			var n3 := node as Node3D
			_link_nodes[nm] = n3
			_rest_local[nm] = n3.transform
			if nm == "pelvis":
				_pelvis_rest_transform = n3.transform
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
		var n := mi.get_surface_override_material_count()
		for i in range(n):
			mi.set_surface_override_material(i, mat)
		if n == 0 and mi.mesh != null:
			mi.set_surface_override_material(0, mat)
	for child in node.get_children():
		_apply_material_to_meshes(child, mat)


# --- Mocap MJCF joint table (qpos order) -----------------------------------


func _parse_mocap_joints() -> void:
	# Build the qpos hinge-joint order by depth-first walking the MJCF <body>
	# tree (MuJoCo's qpos ordering), recording each hinge joint's enclosing
	# body (the GLB link to rotate) and its local axis.
	# Read via FileAccess so it works from res:// inside the APK PCK
	# (XMLParser.open() only reads real on-disk files).
	var bytes := FileAccess.get_file_as_bytes(MOCAP_XML)
	if bytes.is_empty():
		push_warning("[G1Overlay] could not read mocap MJCF %s" % MOCAP_XML)
		return
	var parser := XMLParser.new()
	if parser.open_buffer(bytes) != OK:
		return
	var body_stack: Array = []
	while parser.read() == OK:
		var t := parser.get_node_type()
		if t == XMLParser.NODE_ELEMENT:
			var el_name := parser.get_node_name()
			var empty := parser.is_empty()
			if el_name == "body":
				var bn := _attr(parser, "name", "")
				if not empty:
					body_stack.push_back(bn)
			elif el_name == "joint":
				var jtype := _attr(parser, "type", "hinge")
				if jtype != "free" and jtype != "ball":
					var jname := _attr(parser, "name", "")
					var axis_s := _attr(parser, "axis", "0 0 1")
					var body_name := "" if body_stack.is_empty() else String(body_stack[body_stack.size() - 1])
					var qi := 7 + _qpos_joints.size()  # qpos index for this hinge joint
					_qpos_joints.append({"name": jname, "body": body_name, "axis": _parse_vec3(axis_s)})
					if jname in CLAMP_JOINT_NAMES:
						_clamp_indices.append(qi)
		elif t == XMLParser.NODE_ELEMENT_END:
			if parser.get_node_name() == "body" and not body_stack.is_empty():
				body_stack.pop_back()


func _attr(parser: XMLParser, key: String, fallback: String) -> String:
	for i in range(parser.get_attribute_count()):
		if parser.get_attribute_name(i) == key:
			return parser.get_attribute_value(i)
	return fallback


func _parse_vec3(s: String) -> Vector3:
	var parts := s.split(" ", false)
	if parts.size() < 3:
		return Vector3(0, 0, 1)
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


# Hamilton product a (x) b, computed explicitly so it matches the C++ tool's
# qmul regardless of Godot's operator convention (Quaternion is x,y,z,w).
func _qmul(a: Quaternion, b: Quaternion) -> Quaternion:
	return Quaternion(
		a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
		a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)


# --- Retargeter setup ------------------------------------------------------


func _setup_retargeter() -> void:
	if not ClassDB.class_exists("GMRRetargeter"):
		print("[G1Overlay] GMRRetargeter extension not present; static overlay only.")
		return
	var robot := _extract_to_user(MOCAP_XML)
	var ik := _extract_to_user(IK_CONFIG)
	if robot == "" or ik == "":
		return
	var rt: Object = ClassDB.instantiate("GMRRetargeter")
	if rt == null:
		return
	# locked prefix = base+legs (clamp-after); plus clamp waist roll/pitch + wrists
	# to rest so only the arms + waist-yaw track (matches the GMR Python pipeline).
	var ok: bool = rt.call("configure", "upper_body", robot, ik, HUMAN_HEIGHT, LOCKED_QPOS_PREFIX, false, _clamp_indices)
	if not ok:
		push_warning("[G1Overlay] retargeter configure failed: %s" % str(rt.call("get_last_error")))
		return
	_retargeter = rt
	_retarget_active = true
	print("[G1Overlay] retargeter ready: nq=%d" % int(rt.call("get_nq")))


# Copy a res:// asset to a real user:// path (res:// inside an APK is not a real
# filesystem path, which MuJoCo's mj_loadXML / the JSON loader need).
func _extract_to_user(res_path: String) -> String:
	var dst := "user://".path_join(res_path.get_file())
	if not FileAccess.file_exists(dst):
		var data := FileAccess.get_file_as_bytes(res_path)
		if data.is_empty():
			push_warning("[G1Overlay] could not read %s" % res_path)
			return ""
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			return ""
		f.store_buffer(data)
		f.close()
	return ProjectSettings.globalize_path(dst)


# --- Per-frame retargeting -------------------------------------------------


func _on_canonical_frame_ready(frame: Dictionary) -> void:
	if not _retarget_active or _retargeter == null:
		return
	var joints_v: Variant = frame.get("joints", {})
	if typeof(joints_v) != TYPE_DICTIONARY:
		return
	var joints := joints_v as Dictionary

	# Collect each driven joint's world pose. Positions convert to GMR with a
	# fixed handedness-preserving axis swap (Godot X=right,Y=up,Z=back ->
	# GMR X=fwd,Y=left,Z=up). Orientations are carried too: the SE3 IK error
	# couples the position tangent to the target rotation, so feeding identity
	# quats gives visibly wrong arm angles (verified offline vs the Python ref).
	var raw: Dictionary = {}       # gmr_name -> Vector3 (GMR-swapped position)
	var raw_q: Dictionary = {}     # gmr_name -> Quaternion (canonical orientation)
	for gmr_name in JOINT_MAP:
		var pose := _canonical_pose(joints, JOINT_MAP[gmr_name])
		if pose.is_empty():
			continue
		var p: Vector3 = pose["position"]
		raw[gmr_name] = Vector3(-p.z, -p.x, p.y)
		raw_q[gmr_name] = pose["quat"]
	if raw.size() < JOINT_MAP.size():
		return  # incomplete frame; keep last pose

	# Low-pass positions (and orientations) to reject body-tracking jitter before
	# the frozen-base IK amplifies it.
	for gmr_name in raw:
		if _smooth.has(gmr_name):
			_smooth[gmr_name] = (_smooth[gmr_name] as Vector3).lerp(raw[gmr_name], SMOOTH_ALPHA)
			_smooth_q[gmr_name] = (_smooth_q[gmr_name] as Quaternion).slerp(raw_q[gmr_name], SMOOTH_ALPHA)
		else:
			_smooth[gmr_name] = raw[gmr_name]
			_smooth_q[gmr_name] = raw_q[gmr_name]

	# Anchor + heading-align exactly like the GMR Python pipeline
	# (anchor_and_align_frame): remove the INITIAL heading yaw (computed once from
	# the shoulder line) and pin the hips to (0, 0, PELVIS_HEIGHT). Using a fixed
	# initial yaw (not per-frame) lets the operator's torso yaw track via waist_yaw.
	if not _heading_computed:
		var side0: Vector3 = (_smooth["LeftShoulder"] as Vector3) - (_smooth["RightShoulder"] as Vector3)
		if Vector2(side0.x, side0.y).length() < 0.0001:
			return
		_heading_yaw = PI / 2.0 - atan2(side0.y, side0.x)
		_heading_computed = true
	var cz := cos(_heading_yaw)
	var sz := sin(_heading_yaw)
	var hips: Vector3 = _smooth["Hips"]

	# Combined orientation transform: Rz(heading) * OPENXR_TO_GMR, applied to each
	# joint quat (mirrors the Python adapter + anchor; wxyz [0.5,0.5,-0.5,-0.5]).
	var rz_q := Quaternion(0.0, 0.0, sin(_heading_yaw / 2.0), cos(_heading_yaw / 2.0))
	var combined_q := _qmul(rz_q, Quaternion(0.5, -0.5, -0.5, 0.5))

	for gmr_name in _smooth:
		var rel: Vector3 = (_smooth[gmr_name] as Vector3) - hips
		# rotate horizontal by the initial heading yaw; pin hips height.
		var gmr_pos := Vector3(rel.x * cz - rel.y * sz, rel.x * sz + rel.y * cz, rel.z + PELVIS_HEIGHT)
		var gmr_quat := _qmul(combined_q, _smooth_q[gmr_name])
		_retargeter.call("set_pose_pq", gmr_name, gmr_pos, gmr_quat)

	var qpos: PackedFloat64Array = _retargeter.call("step")
	if qpos.is_empty():
		return
	_apply_qpos(qpos)


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
		var quat := Quaternion.IDENTITY
		var q_v: Variant = pose.get("q", [])
		if typeof(q_v) == TYPE_ARRAY and (q_v as Array).size() >= 4:
			var qa := q_v as Array
			var cand_q := Quaternion(float(qa[0]), float(qa[1]), float(qa[2]), float(qa[3]))
			if cand_q.length_squared() > 0.000001:
				quat = cand_q.normalized()
		return {"position": position, "quat": quat}
	return {}


# Apply MuJoCo-convention qpos (base 7 + hinge joints) to the GLB link nodes by
# rotating each joint's body node about its local axis. The base is held at the
# rest anchor (upper-body scenario locks it), so only the upper body animates.
func _apply_qpos(qpos: PackedFloat64Array) -> void:
	var base := 7
	for i in range(_qpos_joints.size()):
		var qi := base + i
		if qi >= qpos.size():
			break
		var spec: Dictionary = _qpos_joints[i]
		var body_name: String = spec["body"]
		var node: Node3D = _link_nodes.get(body_name, null)
		if node == null:
			continue
		var rest: Transform3D = _rest_local.get(body_name, node.transform)
		var axis: Vector3 = spec["axis"]
		if axis.length_squared() < 0.000001:
			continue
		# The GLB exporter conjugates every link's local transform by the
		# URDF->Godot axis matrix S (godot_T = S * urdf_T * S^-1), so a joint
		# rotation about URDF/MuJoCo axis a becomes a rotation about S*a in the
		# GLB's local frame. S maps (ax,ay,az) -> (-ay, az, -ax).
		var godot_axis := Vector3(-axis.y, axis.z, -axis.x).normalized()
		var angle := float(qpos[qi])
		node.transform = rest * Transform3D(Basis(godot_axis, angle), Vector3.ZERO)


# --- Anchoring -------------------------------------------------------------


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
