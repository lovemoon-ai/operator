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
# Controller input timestamps are kept for diagnostics only. A tracked physical
# controller stays authoritative while its controller interaction profile is
# active; it must not expire merely because Pico also publishes UNKNOWN-source
# optical hand joints.
const PINCH_ARBITRATION_DISTANCE_M := 0.05
const HAND_JOINT_THUMB_TIP := 5
const HAND_JOINT_INDEX_FINGER_TIP := 10
# Trackers driven by XR_EXT_hand_interaction are bare hands even though they
# look like active XRController3D poses to Godot.
const HAND_INTERACTION_PROFILE_HINT := "hand_interaction"
# Godot reports "no interaction profile" as this literal string, NOT as an empty
# string: OpenXRInterface seeds every tracker with set_tracker_profile(
# INTERACTION_PROFILE_NONE) and resets it to the same value whenever the profile
# RID goes null (openxr_interface.cpp, INTERACTION_PROFILE_NONE =
# "/interaction_profiles/none"). An unbound tracker is neither a hand nor a
# controller, so it must be excluded explicitly -- an is_empty() test never
# matches it and silently classifies it as a physical controller.
const INTERACTION_PROFILE_NONE := "/interaction_profiles/none"

# On-device interaction debug log. OPT-IN ONLY — it records a snapshot every
# second, so it must not run (or write to shared storage) on a normal release
# build. Enable it for a diagnostic session with:
#   adb shell am start -n <pkg>/<activity> --es operator.interaction_debug 1
# then read it back without root or a debuggable build via:
#   adb pull /sdcard/Android/data/com.lovemoon.operator/files/interaction_debug.log
# Falls back to user:// (private app storage) off Android.
const DEBUG_LOG_FILENAME := "interaction_debug.log"
const DEBUG_LOG_MAX_BYTES := 262144
const DEBUG_LOG_SNAPSHOT_INTERVAL_S := 1.0

var current_mode := MODE_CONTROLLERS
var busy := false

var _last_controller_input_msec := 0
var _debug_log_accum_s := 0.0
var _debug_log_path_cache := ""
var _debug_log_enabled := false

var _mode_override := ""
# Last pose action that actually carried tracking data, per tracker. Used to
# hold a stable selection while tracking is momentarily lost.
var _preferred_pose_cache := {}
# Instance id of the XRPositionalTracker each cache entry was derived from, so
# the cache can be dropped when the runtime rebuilds the tracker.
var _pose_cache_tracker_ids := {}
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
	_debug_log_enabled = _interaction_debug_requested()
	if _debug_log_enabled:
		print("[Operator] Interaction debug log: %s" % _debug_log_path())
	_router = SettingsInteractionRouterScript.new()
	_router.name = "OperatorInteractionRouter"
	add_child(_router)
	set_process(true)


func _interaction_debug_requested() -> bool:
	## Mirrors the launcher's argument handling: `--es operator.interaction_debug 1`
	## arrives as either a user arg or a plain cmdline arg depending on the
	## Android launch path.
	var all_args: Array = []
	all_args.append_array(OS.get_cmdline_user_args())
	all_args.append_array(OS.get_cmdline_args())
	for raw in all_args:
		var arg := String(raw).strip_edges()
		if arg == "--interaction-debug":
			return true
		for prefix in ["operator.interaction_debug=", "operator_interaction_debug=",
				"--interaction-debug="]:
			if arg.begins_with(prefix):
				var value := arg.substr(prefix.length()).strip_edges().to_lower()
				return value in ["1", "true", "yes", "on"]
	return false


func _process(delta: float) -> void:
	_sync_rig()
	_update_mode()
	_update_targets()
	if _debug_log_enabled:
		_debug_log_accum_s += delta
		if _debug_log_accum_s >= DEBUG_LOG_SNAPSHOT_INTERVAL_S:
			_debug_log_accum_s = 0.0
			_write_debug_snapshot()
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
	_pico_head_probe_count += 1
	# Hand off to native; output goes to logcat via __android_log_print under
	# the "Operator-PROBE" tag, which `make log` picks up regardless of whether
	# Godot's stdout is captured by the Android runtime (on Pico, it isn't).
	if _pico_head_probe_bridge.has_method("log_head_pose_comparison"):
		_pico_head_probe_bridge.call("log_head_pose_comparison", _camera.global_transform)


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
	var left_pose := _preferred_pointer_pose(&"left_hand")
	var right_pose := _preferred_pointer_pose(&"right_hand")
	var left_pointer := _find_controller(origin, "LeftAimPointer", &"left_hand", left_pose)
	var right_pointer := _find_controller(origin, "RightAimPointer", &"right_hand", right_pose)
	if left_pointer == null:
		left_pointer = _ensure_pose_controller(origin, "LeftAimPointer", &"left_hand", left_pose)
	if right_pointer == null:
		right_pointer = _ensure_pose_controller(origin, "RightAimPointer", &"right_hand", right_pose)
	# Preferred-name lookup intentionally survives scene changes, so keep the
	# selected pose synchronized even when the XRController3D node is reused.
	left_pointer.tracker = &"left_hand"
	left_pointer.pose = left_pose
	right_pointer.tracker = &"right_hand"
	right_pointer.pose = right_pose

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


func _preferred_pointer_pose(tracker_name: StringName) -> StringName:
	var tracker := XRServer.get_tracker(tracker_name)
	if not (tracker is XRPositionalTracker):
		return _cached_pointer_pose(tracker_name)
	var positional := tracker as XRPositionalTracker
	_reset_pose_cache_if_tracker_replaced(tracker_name, positional)

	# While a tracker has no interaction profile, OpenXRInterface::handle_tracker()
	# early-returns (`if (p_tracker->interaction_profile.is_null()) return;`), so
	# it neither refreshes nor invalidates any XRPose. Every has_tracking_data
	# keeps whatever value it last had — frozen, not live. Re-deriving a selection
	# from those values would latch onto a pose that is stale but still reads as
	# tracked, so hold the last real choice until the runtime rebinds a profile.
	if _profile_is_none(String(positional.profile)):
		return _cached_pointer_pose(tracker_name)

	# Select on LIVE tracking data only. Deliberately NOT on has_pose(), and
	# deliberately NOT gated on the profile string:
	#
	# - has_pose() is a latch. XRPositionalTracker only ever inserts into its
	#   pose map; nothing in the engine erases an entry (no poses.erase/clear
	#   exists), and invalidate_pose() keeps the entry while only clearing
	#   has_tracking_data. So once `aim` has been published once it reports
	#   has_pose() == true forever. (Verified against Godot 4.5-stable.)
	# - The profile string cannot gate the `default` fallback either. If the
	#   runtime keeps reporting a hand profile after the user picks up a
	#   controller, a profile-gated fallback would refuse `default` and hand back
	#   a dead `aim`. Live pose data is the only signal that stays correct when
	#   the profile is wrong or late.
	#
	# `aim` still wins whenever it is live, so a hand that publishes both poses
	# keeps its pointing ray; `default` is only reached once `aim` is genuinely
	# dead, and the hand path then falls back to _hand_joint_ray() in the router.
	#
	# NOTE: which poses Pico actually publishes per profile (the older comment
	# above claims controllers only get `default`) is inherited from that comment
	# and has NOT been measured on device. This selection deliberately does not
	# depend on that claim being true — it just takes whichever pose is live.
	if _pose_is_tracked(positional, &"aim"):
		_preferred_pose_cache[tracker_name] = &"aim"
		return &"aim"
	if _pose_is_tracked(positional, &"default"):
		_preferred_pose_cache[tracker_name] = &"default"
		return &"default"
	# Nothing is tracked right now (idle controller, hand out of view). Keep the
	# last known good pose so the selection does not flap while tracking is
	# reacquired.
	return _cached_pointer_pose(tracker_name)


func _cached_pointer_pose(tracker_name: StringName) -> StringName:
	return _preferred_pose_cache.get(tracker_name, &"aim")


func _reset_pose_cache_if_tracker_replaced(
		tracker_name: StringName,
		positional: XRPositionalTracker
) -> void:
	# An action-map reload or uninitialize() runs free_trackers(), which destroys
	# and rebuilds the XRControllerTracker — the one path that really does reset
	# has_pose(). The rebuilt tracker has no poses yet, so a cached selection from
	# the previous instance would be handed out instead of being re-derived.
	var instance_id := positional.get_instance_id()
	if _pose_cache_tracker_ids.get(tracker_name) == instance_id:
		return
	_pose_cache_tracker_ids[tracker_name] = instance_id
	_preferred_pose_cache.erase(tracker_name)


func _pose_is_tracked(positional: XRPositionalTracker, pose_name: StringName) -> bool:
	var pose := positional.get_pose(pose_name)
	return pose != null and pose.has_tracking_data


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
	if _debug_log_enabled:
		_append_debug_line("%d MODE -> %s" % [Time.get_ticks_msec(), current_mode])


func _detect_mode() -> String:
	var now := Time.get_ticks_msec()
	var controller_input := _controller_input_detected()
	if controller_input:
		_last_controller_input_msec = now
	var controller_tracking := _controller_tracking(_right_pointer) \
			or _controller_tracking(_left_pointer)
	var hands_unobstructed := _hand_tracker_unobstructed(LEFT_HAND_TRACKER) \
			or _hand_tracker_unobstructed(RIGHT_HAND_TRACKER)
	# Real controller evidence always wins over passive hand-joint data. Pico can
	# report UNKNOWN-source optical joints while a pico4_controller pose and its
	# actions are active; treating those joints as an exclusive hands signal is
	# what previously disabled the controller.
	if controller_input:
		return MODE_CONTROLLERS
	# A physical-controller interaction profile on EITHER side means a controller
	# is in hand, and is authoritative even while the runtime is reacquiring its
	# pose (PICO 4 Ultra keeps publishing button actions during that window).
	#
	# This is checked BEFORE the bare-hand profile test on purpose. The profile is
	# per top-level path, so picking controllers up one at a time — the natural
	# motion — leaves the still-bare hand reporting hand_interaction while the
	# other side already reports pico4_controller. Testing hands first let that
	# one bare hand pin the whole app to MODE_HANDS and starved the live
	# controller, until the user happened to press a trigger.
	if _tracker_profile_is_controller(_left_pointer) \
			or _tracker_profile_is_controller(_right_pointer):
		return MODE_CONTROLLERS
	# XR_EXT_hand_interaction is an unambiguous bare-hand profile. It is checked
	# before generic pose tracking because Godot exposes it through the same
	# left_hand/right_hand XRController3D nodes.
	if _tracker_profile_is_hand(_left_pointer) or _tracker_profile_is_hand(_right_pointer):
		return MODE_HANDS
	# A live non-hand controller pose remains in controller mode without a time
	# limit. This prevents the pointer from disappearing after an idle timeout.
	if controller_tracking:
		return MODE_CONTROLLERS
	# Only consider joint/pinch evidence after no physical controller pose is
	# active. UNKNOWN is valid optical data on Pico, but is not by itself proof
	# that a simultaneously tracked controller should be disabled.
	if _hand_pinch_gesture_active():
		return MODE_HANDS
	if hands_unobstructed or _hands_data_present():
		return MODE_HANDS
	return ""


func _controller_input_detected() -> bool:
	return _pointer_input_detected(_left_pointer) or _pointer_input_detected(_right_pointer)


func _pointer_input_detected(pointer: XRController3D) -> bool:
	if pointer == null:
		return false
	# Pinch via XR_EXT_hand_interaction also drives these action values —
	# only count input coming from a real controller profile.
	if _tracker_profile_is_hand(pointer):
		return false
	if pointer.get_float(&"trigger") >= 0.35:
		return true
	for action in ["trigger_click", "primary_click", "select_button"]:
		if pointer.is_button_pressed(action):
			return true
	return pointer.get_vector2(&"primary").length() >= 0.4


func _hands_data_present() -> bool:
	return _hand_tracker_active(LEFT_HAND_TRACKER) \
			or _hand_tracker_active(RIGHT_HAND_TRACKER) \
			or _tracker_profile_is_hand(_left_pointer) \
			or _tracker_profile_is_hand(_right_pointer)


func _hand_pinch_gesture_active() -> bool:
	for side in [[LEFT_HAND_TRACKER, _left_pointer], [RIGHT_HAND_TRACKER, _right_pointer]]:
		var pointer: XRController3D = side[1]
		if pointer != null and _tracker_profile_is_hand(pointer) \
				and pointer.get_float(&"hand_pinch") >= 0.55:
			return true
		var tracker := XRServer.get_tracker(side[0])
		if tracker is XRHandTracker:
			var hand := tracker as XRHandTracker
			if hand.has_tracking_data \
					and hand.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER:
				var pinch_distance := _pinch_distance(hand)
				if pinch_distance >= 0.0 and pinch_distance <= PINCH_ARBITRATION_DISTANCE_M:
					return true
	return false


func _pinch_distance(hand: XRHandTracker) -> float:
	if (hand.get_hand_joint_flags(HAND_JOINT_THUMB_TIP) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) == 0:
		return -1.0
	if (hand.get_hand_joint_flags(HAND_JOINT_INDEX_FINGER_TIP) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) == 0:
		return -1.0
	var thumb := hand.get_hand_joint_transform(HAND_JOINT_THUMB_TIP).origin
	var index := hand.get_hand_joint_transform(HAND_JOINT_INDEX_FINGER_TIP).origin
	return thumb.distance_to(index)


func _tracker_profile(pointer: XRController3D) -> String:
	if pointer == null:
		return ""
	var tracker := XRServer.get_tracker(pointer.tracker)
	if tracker is XRPositionalTracker:
		return String((tracker as XRPositionalTracker).profile)
	return ""


func _tracker_profile_is_hand(pointer: XRController3D) -> bool:
	return _tracker_profile(pointer).find(HAND_INTERACTION_PROFILE_HINT) != -1


func _tracker_profile_is_controller(pointer: XRController3D) -> bool:
	var profile := _tracker_profile(pointer)
	if profile.is_empty() or _profile_is_none(profile):
		return false
	return profile.find(HAND_INTERACTION_PROFILE_HINT) == -1


func _profile_is_none(profile: String) -> bool:
	return profile == INTERACTION_PROFILE_NONE


func _write_debug_snapshot() -> void:
	var now := Time.get_ticks_msec()
	var scene_name := "?"
	if get_tree() != null and get_tree().current_scene != null:
		scene_name = String(get_tree().current_scene.name)
	var target_count := 0
	if get_tree() != null:
		target_count = get_tree().get_nodes_in_group(TARGET_GROUP).size()
	var recent_ms := -1
	if _last_controller_input_msec > 0:
		recent_ms = now - _last_controller_input_msec
	_append_debug_line("%d mode=%s busy=%d scene=%s targets=%d input_ago_ms=%d | L[%s] R[%s] | handL[%s] handR[%s]" % [
		now,
		current_mode,
		int(busy),
		scene_name,
		target_count,
		recent_ms,
		_pointer_debug(_left_pointer),
		_pointer_debug(_right_pointer),
		_hand_debug(LEFT_HAND_TRACKER),
		_hand_debug(RIGHT_HAND_TRACKER),
	])


func _pointer_debug(pointer: XRController3D) -> String:
	if pointer == null:
		return "null"
	var profile := _tracker_profile(pointer)
	return "act=%d trk=%d prof=%s sel=%s trig=%.2f poses=%s" % [
		int(pointer.get_is_active()),
		int(pointer.get_has_tracking_data()),
		profile.get_file() if not profile.is_empty() else "-",
		String(pointer.pose),
		pointer.get_float(&"trigger"),
		_tracker_pose_debug(pointer),
	]


func _tracker_pose_debug(pointer: XRController3D) -> String:
	var tracker := XRServer.get_tracker(pointer.tracker)
	if not (tracker is XRPositionalTracker):
		return "none"
	var positional := tracker as XRPositionalTracker
	var states: Array[String] = []
	for pose_name in [&"default", &"aim", &"grip"]:
		var pose := positional.get_pose(pose_name)
		var label := String(pose_name).left(1)
		if pose == null:
			states.append("%s:-" % label)
		else:
			states.append("%s:%d/%d" % [
				label,
				int(pose.get_has_tracking_data()),
				int(pose.get_tracking_confidence()),
			])
	return ",".join(states)


func _hand_debug(tracker_path: StringName) -> String:
	var tracker := XRServer.get_tracker(tracker_path)
	if not (tracker is XRHandTracker):
		return "none"
	var hand := tracker as XRHandTracker
	if not hand.has_tracking_data:
		return "idle"
	return "data src=%d pinch=%.3f" % [hand.hand_tracking_source, _pinch_distance(hand)]


func _debug_log_path() -> String:
	if not _debug_log_path_cache.is_empty():
		return _debug_log_path_cache
	_debug_log_path_cache = "user://".path_join(DEBUG_LOG_FILENAME)
	if OS.get_name() == "Android":
		# shared_storage = false resolves to getExternalFilesDir(), i.e.
		# /sdcard/Android/data/<package>/files — readable over adb without root
		# and without a debuggable build, unlike user:// (private app storage).
		var external := OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP, false)
		if not external.is_empty():
			_debug_log_path_cache = external.path_join(DEBUG_LOG_FILENAME)
	return _debug_log_path_cache


func _append_debug_line(line: String) -> void:
	var path := _debug_log_path()
	var file: FileAccess = null
	if FileAccess.file_exists(path):
		file = FileAccess.open(path, FileAccess.READ_WRITE)
		if file != null:
			if file.get_length() > DEBUG_LOG_MAX_BYTES:
				file.close()
				file = FileAccess.open(path, FileAccess.WRITE)
			else:
				file.seek_end()
	else:
		file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_line(line)
	file.close()


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


func _hand_tracker_unobstructed(tracker_path: StringName) -> bool:
	var tracker := XRServer.get_tracker(tracker_path)
	if not (tracker is XRHandTracker):
		return false
	var hand_tracker := tracker as XRHandTracker
	return hand_tracker.has_tracking_data \
			and hand_tracker.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED


func _controller_tracking(controller: XRController3D) -> bool:
	# Raw pose tracking gated only on the interaction profile — deliberately
	# NOT on Haptics.should_use_controller_feedback (that heuristic made
	# controllers permanently lose detection on Pico). A pose driven by
	# XR_EXT_hand_interaction is a bare hand, not a controller, even though
	# Godot reports it as an active XRController3D.
	if controller == null:
		return false
	if not controller.get_is_active() or not controller.get_has_tracking_data():
		return false
	return not _tracker_profile_is_hand(controller)


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
