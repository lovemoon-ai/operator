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
##
## IMPORTANT: the candidate ORDER must match the validated offline pipeline
## (GMR extract_spatialmp4_body_joints.py / GODOT_QUEST_UPPER_JOINTS), because
## the GMR ik_config keys ("LeftShoulder", "Chest", ...) are semantic slots, not
## literal joint names — the offline tool fills them from specific body-tracker
## joints, and the overlay must fill them the same way or the IK targets differ:
##   * "*Shoulder" -> *_upper_arm (NOT *_shoulder): Godot's left/right_shoulder
##     are clavicle/scapula points that sit near the spine and collapse the
##     shoulder width, which throws the arm IK off by tens of degrees (flailing
##     upper limbs). The offline pipeline uses *_upper_arm as the shoulder slot.
##   * "Chest" -> upper_chest first (the offline pipeline's Chest = upper_chest).
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

@export var attach_under: NodePath
@export var debug_place_in_front_of_view: bool = true
@export var debug_front_distance_m: float = 1.0
@export var debug_front_vertical_offset_m: float = 0.0  # fine-tune above the XR floor
@export var overlay_alpha: float = 0.55
@export var overlay_tint: Color = Color(0.78, 0.9, 0.7, 1.0)

# --- Debug instrumentation -------------------------------------------------
## (#1) When > 0, dump the first N retargeting frames to user://g1_debug.jsonl:
## per frame the canonical joints read (GMR slot -> raw p/q + matched candidate),
## the GMR source pose fed to the solver, the heading, and the full qpos. Pull
## with `adb pull /sdcard/Android/data/<pkg>/files/g1_debug.jsonl` and replay it
## through the offline C++ tool / render_g1.py to localize where the on-device
## result diverges from the validated offline pipeline.
@export var debug_dump_frames: int = 0
## (#3) When true, ignore live body tracking and replay a known-good qpos
## sequence (debug_replay_path, JSONL of {"joint_q":[...29...]}) straight into the
## GLB each frame — isolates GLB render/FK from the live retargeting input. If
## the robot animates correctly under replay, the render path is fine and the bug
## is upstream (live input -> qpos); if it's wrong, the bug is in the GLB FK/anchor.
@export var debug_replay_qpos: bool = false
@export var debug_replay_path: String = "res://assets/retargeting/g1_robot_solution_demo.jsonl"
@export var debug_replay_fps: float = 30.0
## (#render) When true, write the imported GLB link rest transforms (per-node
## local basis columns + origin + parent) to user://g1_glb_rest.json once. Lets
## an offline check confirm whether Godot's runtime node transforms match the raw
## glTF matrices the FK math was validated against (the prime suspect now that a
## known-good qpos still renders tilted on-device).
@export var debug_dump_glb_rest: bool = false
## Render the live VR-pose IK targets (the exact joints fed to the retargeter,
## heading-aligned + anchored into the G1's frame) as a small skeleton beside the
## robot, so jitter can be attributed: if this skeleton is smooth but the G1
## jitters, it's the solver/retargeting; if the skeleton jitters too, it's the
## tracking input. Offset to the robot's side by debug_vr_pose_offset metres.
@export var debug_show_vr_pose: bool = true
@export var debug_vr_pose_offset: Vector3 = Vector3(0.7, 0.0, 0.0)
## Drive a fixed, perfectly symmetric rest pose (arms hanging) instead of live
## tracking — to check whether the upper-body yaw offset is downstream of a
## symmetric input (heading seeds to 0 here, so any residual yaw is IK/FK, not
## the heading or live asymmetry).
@export var debug_fixed_rest_pose: bool = false
## dt-aware output low-pass on the retargeted qpos (frame-rate independent), to
## suppress the solver's residual jitter / near-singular spikes. Offline-tuned:
## tau≈0.09s + vmax≈1.5 rad/s cuts chest jitter ~40% and kills the 0.25-rad
## elbow spikes at ~2deg lag. Tune live by comparing to the cyan VR-pose skeleton.
@export var output_filter_enabled: bool = true
@export var output_filter_tau_s: float = 0.09     # EMA time constant (seconds)
@export var output_filter_vmax: float = 1.5        # per-joint velocity cap (rad/s)
## Draw a ground grid under the robot's feet so it reads as standing on a floor
## (the upper-body overlay world-locks the pelvis, leaving the feet visually
## floating). The grid sits at the rest-pose foot height below the pelvis.
@export var show_ground_grid: bool = true
@export var ground_grid_half_m: float = 1.0   # grid half-extent (m)
@export var ground_grid_cell_m: float = 0.2

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
## Seed the heading by averaging the shoulder-line direction over this many valid
## startup frames (instead of a single frame), so a noisy/asymmetric first frame
## can't bake a constant yaw bias for the whole session.
const HEADING_SEED_FRAMES := 20
var _heading_accum: Vector3 = Vector3.ZERO
var _heading_count: int = 0
var _smooth: Dictionary = {}    # gmr_name -> smoothed raw Vector3 (position)
var _smooth_q: Dictionary = {}  # gmr_name -> smoothed Quaternion (orientation)

# --- Debug state ----------------------------------------------------------
var _dump_file: FileAccess = null
var _dump_count: int = 0
var _replay_qpos: Array = []    # Array[PackedFloat64Array]
var _replay_idx: int = 0
var _replay_accum: float = 0.0
var _filtered_qpos: PackedFloat64Array = PackedFloat64Array()  # output-filter state
var _filter_last_us: int = 0

# --- VR-pose overlay ------------------------------------------------------
## Bone segments (gmr joint name pairs) for the VR-pose skeleton beside the G1.
const VR_POSE_BONES := [
	["Hips", "Chest"],
	["Chest", "LeftShoulder"], ["LeftShoulder", "LeftArmLower"], ["LeftArmLower", "LeftWrist"],
	["Chest", "RightShoulder"], ["RightShoulder", "RightArmLower"], ["RightArmLower", "RightWrist"],
]
var _vr_pose_root: Node3D = null
var _vr_pose_spheres: Dictionary = {}   # gmr_name -> MeshInstance3D
var _vr_bone_mesh: ImmediateMesh = null
var _vr_pose_mat: StandardMaterial3D = null


func _ready() -> void:
	if not ResourceLoader.exists(GLB_PATH):
		push_error("[G1Overlay] GLB not found at %s. Run scripts/make-robot/make_unitree_g1.sh." % GLB_PATH)
		return
	_load_glb()
	if _pelvis_node == null:
		push_error("[G1Overlay] GLB did not contain a 'pelvis' node; overlay disabled.")
		return
	_apply_overlay_material()
	if show_ground_grid:
		_create_ground_grid()
	_parse_mocap_joints()
	if debug_dump_glb_rest:
		_dump_glb_rest()
	_setup_retargeter()
	if debug_dump_frames > 0:
		_dump_file = FileAccess.open("user://g1_debug.jsonl", FileAccess.WRITE)
		if _dump_file != null:
			print("[G1Overlay] DEBUG: dumping first %d frames -> user://g1_debug.jsonl" % debug_dump_frames)
		else:
			push_warning("[G1Overlay] DEBUG: could not open user://g1_debug.jsonl for dump")
	if debug_replay_qpos:
		_load_replay()
	if debug_place_in_front_of_view:
		call_deferred("_lock_in_front_of_view")
	print("[G1Overlay] ready: %d links, %d qpos joints, retarget=%s" % [
		_link_nodes.size(), _qpos_joints.size(), str(_retarget_active)])


func _process(delta: float) -> void:
	if debug_place_in_front_of_view and not _debug_front_locked:
		_lock_in_front_of_view()
	# (#3) Static qpos replay: drive the GLB straight from a known-good sequence,
	# bypassing live retargeting, to isolate render/FK from the live input.
	if debug_replay_qpos and not _replay_qpos.is_empty():
		_replay_accum += delta
		var step := 1.0 / maxf(debug_replay_fps, 1.0)
		while _replay_accum >= step:
			_replay_accum -= step
			_apply_qpos(_replay_qpos[_replay_idx])
			_replay_idx = (_replay_idx + 1) % _replay_qpos.size()


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
		# A translucent overlay should not cast shadows; turning it off also drops
		# the shadow-mesh render path (a likely trigger of the deep recursive
		# Vulkan render crash seen on-device) and is cheaper to draw.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
			elif el_name == "joint" and not body_stack.is_empty():
				# Only joints inside a <body> are real qpos joints. The MJCF
				# <default> block also contains a <joint> template (with no
				# enclosing body); counting it would shift every subsequent
				# qpos[7+i] mapping by one — each link would get the NEXT joint's
				# angle, tilting the torso and flailing the arms. Skip it by
				# requiring a non-empty body stack.
				var jtype := _attr(parser, "type", "hinge")
				if jtype != "free" and jtype != "ball":
					var jname := _attr(parser, "name", "")
					var axis_s := _attr(parser, "axis", "0 0 1")
					var body_name := String(body_stack[body_stack.size() - 1])
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
	if debug_replay_qpos:
		return  # (#3) replay drives the GLB from _process; ignore live input
	var joints_v: Variant = frame.get("joints", {})
	if typeof(joints_v) != TYPE_DICTIONARY:
		return
	var joints := joints_v as Dictionary
	if debug_fixed_rest_pose:
		# Drive a perfectly symmetric, hardcoded rest pose instead of live tracking,
		# to isolate the upper-body yaw offset: with symmetric shoulders the heading
		# seeds to 0, so any residual G1 yaw is downstream (IK config / mapping / FK),
		# not the heading seed or live input asymmetry.
		joints = _fixed_rest_joints()

	# Collect each driven joint's world pose. Positions convert to GMR with a
	# fixed handedness-preserving axis swap (Godot X=right,Y=up,Z=back ->
	# GMR X=fwd,Y=left,Z=up). Orientations are carried too: the SE3 IK error
	# couples the position tangent to the target rotation, so feeding identity
	# quats gives visibly wrong arm angles (verified offline vs the Python ref).
	var raw: Dictionary = {}       # gmr_name -> Vector3 (GMR-swapped position)
	var raw_q: Dictionary = {}     # gmr_name -> Quaternion (canonical orientation)
	var matched: Dictionary = {}   # gmr_name -> which candidate name resolved
	var canon: Dictionary = {}     # gmr_name -> {p,q,matched} raw canonical (dump only)
	var dumping := _dump_file != null and _dump_count < debug_dump_frames
	for gmr_name in JOINT_MAP:
		var pose := _canonical_pose(joints, JOINT_MAP[gmr_name])
		if pose.is_empty():
			continue
		var p: Vector3 = pose["position"]
		raw[gmr_name] = Vector3(-p.z, -p.x, p.y)
		raw_q[gmr_name] = pose["quat"]
		matched[gmr_name] = pose["matched"]
		if dumping:
			var cq: Quaternion = pose["quat"]
			# Raw canonical p (pre GMR-swap) + q (xyzw): this record is directly
			# convertible to the offline tool's body.jsonl input format.
			canon[gmr_name] = {"p": [p.x, p.y, p.z], "q": [cq.x, cq.y, cq.z, cq.w], "matched": pose["matched"]}
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
		# Seed the one-time heading by AVERAGING the shoulder-line direction over the
		# first HEADING_SEED_FRAMES valid frames. Both shoulders must have resolved
		# via their primary candidate (*_upper_arm), not the narrow clavicle
		# fallback. Averaging (vs a single frame) stops a noisy/asymmetric startup
		# frame from baking a constant yaw bias. Re-seed by toggling the overlay
		# while squared to forward.
		if matched.get("LeftShoulder", "") != JOINT_MAP["LeftShoulder"][0] \
				or matched.get("RightShoulder", "") != JOINT_MAP["RightShoulder"][0]:
			return
		var side0: Vector3 = (_smooth["LeftShoulder"] as Vector3) - (_smooth["RightShoulder"] as Vector3)
		var side_h := Vector2(side0.x, side0.y)
		if side_h.length() < 0.05:  # reject degenerate/collapsed shoulder lines
			return
		side_h = side_h.normalized()
		_heading_accum += Vector3(side_h.x, side_h.y, 0.0)
		_heading_count += 1
		if _heading_count < HEADING_SEED_FRAMES:
			return  # keep accumulating; don't drive the robot until heading is stable
		_heading_yaw = PI / 2.0 - atan2(_heading_accum.y, _heading_accum.x)
		_heading_computed = true
	var cz := cos(_heading_yaw)
	var sz := sin(_heading_yaw)
	var hips: Vector3 = _smooth["Hips"]

	# Combined orientation transform: Rz(heading) * OPENXR_TO_GMR, applied to each
	# joint quat (mirrors the Python adapter + anchor; wxyz [0.5,0.5,-0.5,-0.5]).
	var rz_q := Quaternion(0.0, 0.0, sin(_heading_yaw / 2.0), cos(_heading_yaw / 2.0))
	var combined_q := _qmul(rz_q, Quaternion(0.5, -0.5, -0.5, 0.5))

	var src: Dictionary = {}       # gmr_name -> GMR source pose fed to the solver (dump)
	var targets: Dictionary = {}   # gmr_name -> Vector3 gmr_pos (for the VR-pose overlay)
	for gmr_name in _smooth:
		var rel: Vector3 = (_smooth[gmr_name] as Vector3) - hips
		# rotate horizontal by the initial heading yaw; pin hips height.
		var gmr_pos := Vector3(rel.x * cz - rel.y * sz, rel.x * sz + rel.y * cz, rel.z + PELVIS_HEIGHT)
		var gmr_quat := _qmul(combined_q, _smooth_q[gmr_name])
		_retargeter.call("set_pose_pq", gmr_name, gmr_pos, gmr_quat)
		targets[gmr_name] = gmr_pos
		if dumping:
			src[gmr_name] = {
				"gmr_pos": [gmr_pos.x, gmr_pos.y, gmr_pos.z],
				"gmr_quat": [gmr_quat.x, gmr_quat.y, gmr_quat.z, gmr_quat.w],
			}
	if debug_show_vr_pose:
		_update_vr_pose(targets)

	var qpos: PackedFloat64Array = _retargeter.call("step")
	if qpos.is_empty():
		return
	var shown_qpos := _filter_qpos(qpos) if output_filter_enabled else qpos
	_apply_qpos(shown_qpos)

	if dumping:
		_dump_frame(canon, src, shown_qpos)


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
		# Reject non-finite tracking samples here so NaN/inf can never propagate
		# into the IK targets or the GLB node transforms (a NaN transform corrupts
		# the renderer's cull structure -> intermittent render-thread crash).
		if not (is_finite(position.x) and is_finite(position.y) and is_finite(position.z)):
			continue
		var quat := Quaternion.IDENTITY
		var q_v: Variant = pose.get("q", [])
		if typeof(q_v) == TYPE_ARRAY and (q_v as Array).size() >= 4:
			var qa := q_v as Array
			var cand_q := Quaternion(float(qa[0]), float(qa[1]), float(qa[2]), float(qa[3]))
			if cand_q.length_squared() > 0.000001:
				quat = cand_q.normalized()
		return {"position": position, "quat": quat, "matched": cand}
	return {}


# dt-aware output low-pass on the qpos: one EMA step toward the target, with the
# per-frame change capped at vmax*dt. Frame-rate independent (uses the real time
# between frames), so the offline-tuned tau/vmax transfer to the device's ~60Hz.
func _filter_qpos(qpos: PackedFloat64Array) -> PackedFloat64Array:
	var now := Time.get_ticks_usec()
	if _filtered_qpos.size() != qpos.size() or _filter_last_us == 0:
		_filtered_qpos = qpos.duplicate()
		_filter_last_us = now
		return qpos
	var dt := clampf(float(now - _filter_last_us) / 1_000_000.0, 0.001, 0.1)
	_filter_last_us = now
	var a := 1.0 - exp(-dt / maxf(output_filter_tau_s, 0.001))
	var cap := output_filter_vmax * dt
	for i in range(qpos.size()):
		var prev: float = _filtered_qpos[i]
		var step: float = clampf(a * (qpos[i] - prev), -cap, cap)
		_filtered_qpos[i] = prev + step
	return _filtered_qpos.duplicate()


# Hardcoded symmetric rest pose (arms hanging) in the canonical Godot frame
# (X=right, Y=up, Z=back). Mirror-symmetric across X=0, left at -X / right at +X
# so the shoulder line seeds the heading to 0 (facing forward).
func _fixed_rest_joints() -> Dictionary:
	# A real captured frame (positions + REAL orientations). Identity quats here
	# would corrupt the arm angles (the SE3 IK couples the position residual to the
	# target rotation), so the static G1 should be compared against the cyan
	# skeleton with real per-joint orientations to check correspondence.
	var pose := {
		"hips": {"p": [-0.3552, 1.1647, -0.1924], "q": [-0.0985, 0.7871, 0.1294, 0.5949]},
		"upper_chest": {"p": [-0.4246, 1.4912, -0.1792], "q": [-0.0588, 0.8077, 0.0637, 0.5832]},
		"left_upper_arm": {"p": [-0.4473, 1.5405, -0.3334], "q": [-0.0185, -0.2289, 0.9345, -0.2721]},
		"left_lower_arm": {"p": [-0.3382, 1.3823, -0.4218], "q": [-0.3303, -0.4092, -0.5362, 0.6603]},
		"left_wrist": {"p": [-0.1288, 1.4259, -0.4055], "q": [0.2542, 0.5520, -0.3639, 0.7059]},
		"right_upper_arm": {"p": [-0.3533, 1.5376, -0.0438], "q": [0.9189, 0.2706, -0.2555, 0.1308]},
		"right_lower_arm": {"p": [-0.2342, 1.3641, -0.0220], "q": [-0.6284, -0.4996, -0.2258, 0.5519]},
		"right_wrist": {"p": [-0.0480, 1.3830, -0.1330], "q": [0.2544, 0.8571, -0.2757, 0.3530]},
	}
	var out := {}
	for name in pose:
		out[name] = {"valid": true, "pose": {"p": pose[name]["p"], "q": pose[name]["q"]}}
	return out


# --- Ground grid -----------------------------------------------------------


# Rest-pose foot-sole height below the pelvis origin (GLB bbox min Y). The legs
# are locked in the upper-body scenario, so the feet stay at this fixed offset.
const FOOT_BELOW_PELVIS := 0.792


# Draw a horizontal grid at foot level, parented under the (world-locked, yaw-
# only) pelvis so it stays flat under the robot's feet.
func _create_ground_grid() -> void:
	if _pelvis_node == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "GroundGrid"
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.5, 0.8, 1.0, 0.5)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var y := -FOOT_BELOW_PELVIS
	var ext := ground_grid_half_m
	var cell := maxf(ground_grid_cell_m, 0.02)
	var n := int(ext / cell)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i in range(-n, n + 1):
		var t := i * cell
		im.surface_add_vertex(Vector3(t, y, -ext))
		im.surface_add_vertex(Vector3(t, y, ext))
		im.surface_add_vertex(Vector3(-ext, y, t))
		im.surface_add_vertex(Vector3(ext, y, t))
	im.surface_end()
	_pelvis_node.add_child(mi)


# --- VR-pose overlay -------------------------------------------------------


# Build the VR-pose skeleton nodes once: a bright unshaded joint sphere per IK
# target plus a line mesh for the bones, parented under the (world-locked) pelvis
# so it stays beside the robot. Positions are filled in by _update_vr_pose().
func _ensure_vr_pose_nodes() -> void:
	if _vr_pose_root != null or _pelvis_node == null:
		return
	_vr_pose_root = Node3D.new()
	_vr_pose_root.name = "VRPoseOverlay"
	_pelvis_node.add_child(_vr_pose_root)

	_vr_pose_mat = StandardMaterial3D.new()
	_vr_pose_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_vr_pose_mat.albedo_color = Color(0.2, 0.7, 1.0)  # cyan, distinct from the green G1
	_vr_pose_mat.disable_receive_shadows = true

	var sphere := SphereMesh.new()
	sphere.radius = 0.03
	sphere.height = 0.06
	sphere.radial_segments = 8
	sphere.rings = 4
	for gmr_name in JOINT_MAP:
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.material_override = _vr_pose_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_vr_pose_root.add_child(mi)
		_vr_pose_spheres[gmr_name] = mi

	var bones := MeshInstance3D.new()
	bones.name = "VRPoseBones"
	_vr_bone_mesh = ImmediateMesh.new()
	bones.mesh = _vr_bone_mesh
	bones.material_override = _vr_pose_mat
	bones.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vr_pose_root.add_child(bones)


# Place the joint spheres + rebuild the bone lines from the current IK targets.
# targets are gmr_pos (GMR coords: x-fwd, y-left, z-up); map to the GLB/Godot link
# frame with S (x,y,z)->(-y,z,-x), make them hips-relative, and shift to the side.
func _update_vr_pose(targets: Dictionary) -> void:
	_ensure_vr_pose_nodes()
	if _vr_pose_root == null or not targets.has("Hips"):
		return
	var hips: Vector3 = targets["Hips"]
	var local: Dictionary = {}
	for gmr_name in _vr_pose_spheres:
		if not targets.has(gmr_name):
			continue
		var g: Vector3 = (targets[gmr_name] as Vector3) - hips
		var p := Vector3(-g.y, g.z, -g.x) + debug_vr_pose_offset
		local[gmr_name] = p
		(_vr_pose_spheres[gmr_name] as MeshInstance3D).position = p
	_vr_bone_mesh.clear_surfaces()
	_vr_bone_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _vr_pose_mat)
	for bone in VR_POSE_BONES:
		if local.has(bone[0]) and local.has(bone[1]):
			_vr_bone_mesh.surface_add_vertex(local[bone[0]])
			_vr_bone_mesh.surface_add_vertex(local[bone[1]])
	_vr_bone_mesh.surface_end()


# --- Debug helpers ---------------------------------------------------------


# (#render) Dump the imported GLB link rest transforms so an offline check can
# compare Godot's runtime node frames to the raw glTF matrices the FK was
# validated against. basis is stored as the three COLUMN vectors (the local->
# parent basis), origin is the local translation; parent is the node parent name.
func _dump_glb_rest() -> void:
	# Imported GLB link rest transforms (local basis columns + origin + parent).
	var links: Dictionary = {}
	for nm in _link_nodes:
		var n: Node3D = _link_nodes[nm]
		var t: Transform3D = n.transform
		# Basis.x/.y/.z are the column (basis) vectors (Godot 4 has no get_column).
		var c0 := t.basis.x
		var c1 := t.basis.y
		var c2 := t.basis.z
		var par := n.get_parent()
		links[nm] = {
			"parent": (str(par.name) if par != null else ""),
			"cols": [c0.x, c0.y, c0.z, c1.x, c1.y, c1.z, c2.x, c2.y, c2.z],
			"origin": [t.origin.x, t.origin.y, t.origin.z],
		}
	# Parsed MJCF qpos joint table (name, enclosing body, axis) in qpos order —
	# lets the offline check verify the runtime joint->body->axis mapping too.
	var jtab: Array = []
	for j in _qpos_joints:
		var ax: Vector3 = j["axis"]
		jtab.append({"name": j["name"], "body": j["body"], "axis": [ax.x, ax.y, ax.z]})
	var out := {"links": links, "joints": jtab}
	var payload := JSON.stringify(out)
	# Write to a pullable external path first (user:// is the app-internal dir on
	# Android and is not reachable with a plain `adb pull`). The capture pipeline
	# already has external-storage permission for /sdcard/DCIM/SpatialMP4.
	for p in ["/sdcard/DCIM/g1_glb_rest.json", "/sdcard/Download/g1_glb_rest.json", "user://g1_glb_rest.json"]:
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string(payload)
			f.close()
			print("[G1Overlay] DEBUG: wrote GLB rest (%d links, %d joints) -> %s" % [links.size(), jtab.size(), p])
			return
	push_warning("[G1Overlay] DEBUG: could not open any GLB rest dump path")


# (#1) Append one frame of the live pipeline to user://g1_debug.jsonl:
#   canon : raw canonical p/q per GMR slot (offline body.jsonl-compatible)
#   src   : the GMR source pose actually fed to the solver
#   qpos  : the full 36-entry qpos the native retargeter returned on-device
# Feeding `canon` into the offline C++ tool should reproduce `qpos`; if it does
# not, the live input or the native solver is the divergence; if it does, the
# bug is downstream in _apply_qpos / the GLB render.
func _dump_frame(canon: Dictionary, src: Dictionary, qpos: PackedFloat64Array) -> void:
	var qarr: Array = []
	qarr.resize(qpos.size())
	for i in range(qpos.size()):
		qarr[i] = qpos[i]
	var rec := {
		"frame": _dump_count,
		"heading_deg": rad_to_deg(_heading_yaw),
		"canon": canon,
		"src": src,
		"qpos": qarr,
	}
	_dump_file.store_line(JSON.stringify(rec))
	_dump_file.flush()
	_dump_count += 1
	if _dump_count >= debug_dump_frames:
		_dump_file.close()
		_dump_file = null
		print("[G1Overlay] DEBUG: dump complete (%d frames) -> user://g1_debug.jsonl" % debug_dump_frames)


# (#3) Load a known-good qpos JSONL ({"joint_q":[...29...]} per line) for replay.
# joint_q maps to qpos[7..35]; the base (qpos[0..6]) stays at rest (unused by
# _apply_qpos, which reads from index 7).
func _load_replay() -> void:
	var bytes := FileAccess.get_file_as_bytes(debug_replay_path)
	if bytes.is_empty():
		push_warning("[G1Overlay] DEBUG: replay qpos file not found: %s" % debug_replay_path)
		return
	for line in bytes.get_string_from_utf8().split("\n", false):
		var t := line.strip_edges()
		if t.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(t)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var jq_v: Variant = (parsed as Dictionary).get("joint_q", [])
		if typeof(jq_v) != TYPE_ARRAY:
			continue
		var jq := jq_v as Array
		var arr := PackedFloat64Array()
		arr.resize(7 + jq.size())
		for i in range(jq.size()):
			arr[7 + i] = float(jq[i])
		_replay_qpos.append(arr)
	print("[G1Overlay] DEBUG: replay loaded %d qpos frames from %s" % [_replay_qpos.size(), debug_replay_path])


# Apply MuJoCo-convention qpos (base 7 + hinge joints) to the GLB link nodes by
# rotating each joint's body node about its local axis. The base is held at the
# rest anchor (upper-body scenario locks it), so only the upper body animates.
func _apply_qpos(qpos: PackedFloat64Array) -> void:
	# Never apply a frame with a non-finite entry: one NaN/inf angle would make a
	# node transform (and its AABB) NaN, which corrupts the renderer's cull tree
	# and crashes the render thread on a later draw. Drop the frame instead.
	for v in qpos:
		if not is_finite(v):
			return
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
	# Stand the robot's feet on the REAL XR floor instead of floating it relative
	# to the head. The reference space is floor-referenced, so the XROrigin sits on
	# the floor; put the pelvis FOOT_BELOW_PELVIS above that floor Y (+ optional
	# fine-tune). The legs are locked, so the feet stay at this fixed offset.
	anchor.y = _xr_floor_y() + FOOT_BELOW_PELVIS + debug_front_vertical_offset_m
	var operator_xform := Transform3D(Basis(Vector3.UP, yaw), anchor)
	_pelvis_node.global_transform = operator_xform * _pelvis_rest_transform
	_debug_front_locked = true
	return true


# Floor world-Y from the XR origin. The OpenXR reference space is floor-referenced
# (the XROrigin sits on the physical floor), so the origin's world Y is the floor.
func _xr_floor_y() -> float:
	if _head_camera != null:
		var p := _head_camera.get_parent()
		if p is XROrigin3D:
			return (p as XROrigin3D).global_transform.origin.y
	return 0.0
