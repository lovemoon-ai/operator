extends Node
class_name OperatorInteractionService

signal input_mode_changed(mode: String)

const SettingsInteractionRouterScript := preload("res://scripts/ui/settings_interaction_router.gd")
const OperatorUIPointerVisualScript := preload("res://scripts/xr/operator_ui_pointer_visual.gd")

const TARGET_GROUP := "operator_interaction_target"
const MODE_CONTROLLERS := "controllers"
const MODE_HANDS := "hands"
const MODE_HEAD := "head"
const LEFT_HAND_TRACKER := &"/user/hand_tracker/left"
const RIGHT_HAND_TRACKER := &"/user/hand_tracker/right"

var current_mode := MODE_CONTROLLERS
var busy := false

var _mode_override := ""
var _router: Node
var _pointer_visual: Node3D
var _origin: XROrigin3D
var _camera: XRCamera3D
var _left_pointer: XRController3D
var _right_pointer: XRController3D

# Ad-hoc head-pose source probe. Runs from app start (this is an autoload),
# 1 Hz tick, prints godot XRCamera3D pose vs xrLocateSpace(VIEW, play) so we
# can confirm whether the recording's "head" actually matches OpenXR VIEW.
var _pico_head_probe_accum_s := 0.0
var _pico_head_probe_count := 0
var _pico_head_probe_bridge: Object


func _ready() -> void:
	_router = SettingsInteractionRouterScript.new()
	_router.name = "OperatorInteractionRouter"
	add_child(_router)
	set_process(true)


func _process(delta: float) -> void:
	_sync_rig()
	_update_mode()
	_update_targets()
	_pico_head_probe_accum_s += delta
	if _pico_head_probe_accum_s >= 1.0:
		_pico_head_probe_accum_s = 0.0
		_emit_pico_head_probe()
	if _router == null:
		return
	_router.interaction_mode = current_mode
	_router.busy = busy
	_router.update_pointer()


func _emit_pico_head_probe() -> void:
	if _pico_head_probe_bridge == null:
		if ClassDB.class_exists("PicoOpenXRExtension"):
			_pico_head_probe_bridge = ClassDB.instantiate("PicoOpenXRExtension")
		if _pico_head_probe_bridge == null:
			return
	if _camera == null:
		return
	var godot_t: Transform3D = _camera.global_transform
	var godot_pos := godot_t.origin
	var godot_quat := godot_t.basis.get_rotation_quaternion()
	_pico_head_probe_count += 1
	print("[PROBE %d] godot.XRCamera3D.global_transform pos=(%.4f, %.4f, %.4f) quat_xyzw=(%.4f, %.4f, %.4f, %.4f)" % [
		_pico_head_probe_count,
		godot_pos.x, godot_pos.y, godot_pos.z,
		godot_quat.x, godot_quat.y, godot_quat.z, godot_quat.w,
	])
	if _pico_head_probe_bridge.has_method("probe_view_space_pose"):
		var probe: Dictionary = _pico_head_probe_bridge.call("probe_view_space_pose")
		if bool(probe.get("available", false)):
			var t: Transform3D = probe.get("transform", Transform3D())
			var p := t.origin
			var q := t.basis.get_rotation_quaternion()
			var dp := godot_pos - p
			print("[PROBE %d] xrLocateSpace(VIEW, play)    pos=(%.4f, %.4f, %.4f) quat_xyzw=(%.4f, %.4f, %.4f, %.4f)  delta_pos_from_godot=(%.4f, %.4f, %.4f) |delta|=%.4f" % [
				_pico_head_probe_count,
				p.x, p.y, p.z,
				q.x, q.y, q.z, q.w,
				dp.x, dp.y, dp.z, dp.length(),
			])
		else:
			print("[PROBE %d] xrLocateSpace probe unavailable: reason=%s xr_result=%s flags=%s" % [
				_pico_head_probe_count,
				probe.get("reason", "?"),
				probe.get("xr_result", "?"),
				probe.get("location_flags", "?"),
			])


func set_mode_override(mode: String) -> void:
	var normalized := _normalize_mode(mode)
	if normalized == MODE_CONTROLLERS:
		normalized = ""
	if normalized == _mode_override:
		return
	_mode_override = normalized
	release_pointer()
	_update_mode()


func get_mode_override() -> String:
	return _mode_override


func get_current_mode() -> String:
	return current_mode


func set_busy(next_busy: bool) -> void:
	busy = next_busy
	if _router != null:
		_router.busy = busy


func release_pointer() -> void:
	if _router != null:
		_router.release_pointer()


func _sync_rig() -> void:
	if _origin != null and not is_instance_valid(_origin):
		_origin = null
	if _camera != null and not is_instance_valid(_camera):
		_camera = null
	if _left_pointer != null and not is_instance_valid(_left_pointer):
		_left_pointer = null
	if _right_pointer != null and not is_instance_valid(_right_pointer):
		_right_pointer = null
	if _pointer_visual != null and not is_instance_valid(_pointer_visual):
		_pointer_visual = null

	var scene := get_tree().current_scene
	if scene == null:
		return
	var origin := _find_xr_origin(scene)
	if origin == null:
		return
	var camera := _find_xr_camera(origin)
	var left_pointer := _find_controller(origin, "LeftAimPointer", &"left_hand", &"aim")
	var right_pointer := _find_controller(origin, "RightAimPointer", &"right_hand", &"aim")
	if left_pointer == null:
		left_pointer = _ensure_pose_controller(origin, "LeftAimPointer", &"left_hand", &"aim")
	if right_pointer == null:
		right_pointer = _ensure_pose_controller(origin, "RightAimPointer", &"right_hand", &"aim")

	if origin == _origin \
			and camera == _camera \
			and left_pointer == _left_pointer \
			and right_pointer == _right_pointer:
		return

	_origin = origin
	_camera = camera
	_left_pointer = left_pointer
	_right_pointer = right_pointer
	_ensure_pointer_visual()
	_router.configure(
			_origin,
			_camera,
			_left_pointer,
			_right_pointer,
			_pointer_visual
	)


func _ensure_pointer_visual() -> void:
	if _origin == null:
		return
	if _pointer_visual != null and is_instance_valid(_pointer_visual):
		if _pointer_visual.get_parent() == _origin:
			return
		_pointer_visual.queue_free()
	_pointer_visual = OperatorUIPointerVisualScript.new()
	_pointer_visual.name = "OperatorInteractionPointerVisual"
	_origin.add_child(_pointer_visual)


func _ensure_pose_controller(
		parent: Node,
		node_name: String,
		tracker: StringName,
		pose: StringName
) -> XRController3D:
	var existing := parent.get_node_or_null(NodePath(node_name)) as XRController3D
	if existing != null:
		existing.tracker = tracker
		existing.pose = pose
		return existing
	var controller := XRController3D.new()
	controller.name = node_name
	controller.tracker = tracker
	controller.pose = pose
	parent.add_child(controller)
	return controller


func _update_mode() -> void:
	var next_mode := _mode_override
	if next_mode.is_empty():
		next_mode = _detect_mode()
	if next_mode.is_empty():
		next_mode = MODE_CONTROLLERS if current_mode == MODE_HEAD else current_mode
	if next_mode.is_empty():
		next_mode = MODE_CONTROLLERS
	if next_mode == current_mode:
		return
	current_mode = next_mode
	release_pointer()
	input_mode_changed.emit(current_mode)
	print("[Operator] Global interaction mode: %s" % current_mode)


func _detect_mode() -> String:
	if _hand_tracker_active(LEFT_HAND_TRACKER) or _hand_tracker_active(RIGHT_HAND_TRACKER):
		return MODE_HANDS
	if _controller_active(_right_pointer) or _controller_active(_left_pointer):
		return MODE_CONTROLLERS
	return ""


func _update_targets() -> void:
	if _router == null:
		return
	var targets := _collect_targets()
	_router.set_targets(targets)


func _collect_targets() -> Array:
	var targets: Array = []
	for node in get_tree().get_nodes_in_group(TARGET_GROUP):
		if node == null:
			continue
		if not (node is Object):
			continue
		targets.append(node)
	targets.sort_custom(func(a, b): return _target_priority(a) > _target_priority(b))
	return targets


func _target_priority(target: Object) -> int:
	if target.has_method("get_interaction_priority"):
		return int(target.call("get_interaction_priority"))
	var value: Variant = target.get("interaction_priority")
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return int(value)
	return 0


func _find_xr_origin(root: Node) -> XROrigin3D:
	if root is XROrigin3D:
		return root as XROrigin3D
	for child in root.get_children():
		var found := _find_xr_origin(child)
		if found != null:
			return found
	return null


func _find_xr_camera(root: Node) -> XRCamera3D:
	if root is XRCamera3D:
		return root as XRCamera3D
	for child in root.get_children():
		var found := _find_xr_camera(child)
		if found != null:
			return found
	return null


func _find_controller(root: Node, preferred_name: String, tracker: StringName, pose: StringName) -> XRController3D:
	var fallback: XRController3D = null
	for child in root.get_children():
		if child is XRController3D:
			var controller := child as XRController3D
			if controller.name == preferred_name:
				return controller
			if fallback == null and controller.tracker == tracker and (pose == &"" or controller.pose == pose):
				fallback = controller
		var nested := _find_controller(child, preferred_name, tracker, pose)
		if nested != null:
			return nested
	return fallback


func _hand_tracker_active(tracker_path: StringName) -> bool:
	var tracker := XRServer.get_tracker(tracker_path)
	if not (tracker is XRHandTracker):
		return false
	var hand_tracker := tracker as XRHandTracker
	if not hand_tracker.has_tracking_data:
		return false
	return hand_tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER


func _controller_active(controller: XRController3D) -> bool:
	if controller == null:
		return false
	if not controller.get_is_active() or not controller.get_has_tracking_data():
		return false
	var haptics := _get_haptics_bus()
	if haptics != null and haptics.has_method("should_use_controller_feedback"):
		return bool(haptics.call("should_use_controller_feedback", controller))
	return true


func _get_haptics_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Haptics")


func _normalize_mode(mode: String) -> String:
	var normalized := mode.strip_edges().to_lower().replace("-", "_")
	match normalized:
		"controller", "controllers":
			return MODE_CONTROLLERS
		"hand", "hands":
			return MODE_HANDS
		"head", "head_button", "head_buttons", "volume", "volume_buttons":
			return MODE_HEAD
		_:
			return normalized
