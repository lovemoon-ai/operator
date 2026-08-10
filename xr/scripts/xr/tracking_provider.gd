class_name TrackingProvider
extends Node
## Unified OpenXR tracking abstraction.
## Provides head pose, controller poses+input, and hand joint data
## using ONLY standard OpenXR APIs. No vendor-specific calls.

signal tracking_data_ready(data: Dictionary)

const CONTROLLER_CACHE_TTL_MSEC := 250
const LEFT_HAND_TRACKER := &"/user/hand_tracker/left"
const RIGHT_HAND_TRACKER := &"/user/hand_tracker/right"
const HAND_INTERACTION_PROFILE_HINT := "hand_interaction"

## Reference to XRCamera3D in the scene tree
var _camera: XRCamera3D
## References to controller nodes
var _left_controller: XRController3D
var _right_controller: XRController3D
## XR interface reference
var _xr_interface: XRInterface
## Detected platform name
var _platform_name: String = "Unknown"
## Whether hand tracking is available
var _hand_tracking_available: bool = false
var _last_controller_inputs: Array[Dictionary] = [{}, {}]
var _last_controller_input_msec: Array[int] = [0, 0]
var _last_controller_poses: Array[Dictionary] = [{}, {}]
var _last_controller_pose_msec: Array[int] = [0, 0]


func _ready() -> void:
	# Defer finding nodes until tree is ready
	call_deferred("_find_xr_nodes")


func _find_xr_nodes() -> void:
	_xr_interface = XRServer.find_interface("OpenXR")
	if _xr_interface:
		var runtime_name = _xr_interface.get("XRRuntimeName")
		if runtime_name:
			_platform_name = runtime_name

	# Find XR nodes in the scene tree
	var origin := _find_xr_origin()
	if origin:
		for child in origin.get_children():
			if child is XRCamera3D:
				_camera = child
			elif child is XRController3D:
				var tracker_name: String = child.tracker
				if tracker_name == "left_hand" or child.name == "LeftController":
					_left_controller = child
				elif tracker_name == "right_hand" or child.name == "RightController":
					_right_controller = child

	# Check hand tracking support
	_hand_tracking_available = _check_hand_tracking_support()

	print("[TrackingProvider] Initialized - platform: %s, hand_tracking: %s" % [
		_platform_name, _hand_tracking_available
	])


func _find_xr_origin() -> XROrigin3D:
	# Walk up from our parent to find XROrigin3D
	var main := get_parent()
	if main:
		for child in main.get_children():
			if child is XROrigin3D:
				return child
		# Also search deeper
		for child in main.get_children():
			for grandchild in child.get_children():
				if grandchild is XROrigin3D:
					return grandchild
	return null


func _check_hand_tracking_support() -> bool:
	# Check if OpenXR hand tracking extension is available
	var tracker := XRServer.get_tracker(LEFT_HAND_TRACKER)
	return tracker != null


func is_hand_tracking_active(hand: int) -> bool:
	return is_optical_hand_tracking_active(hand)


func is_optical_hand_tracking_active(hand: int) -> bool:
	var tracker = XRServer.get_tracker(_hand_tracker_name(hand))
	if not (tracker is XRHandTracker):
		return false
	var hand_tracker := tracker as XRHandTracker
	if not hand_tracker.has_tracking_data:
		return false
	# Only reject hand data synthesized from a held controller (Quest with the
	# XR_EXT_hand_tracking_data_source controller path). SOURCE_UNKNOWN must
	# still count as optical: runtimes that don't support
	# XR_EXT_hand_tracking_data_source (e.g. Pico OS) never report a source,
	# yet their has_tracking_data is genuine bare-hand tracking. Requiring
	# UNOBSTRUCTED here made hands permanently "inactive" on Pico.
	return hand_tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER


func is_controller_mode_active(hand: int) -> bool:
	var controller: XRController3D = _left_controller if hand == 0 else _right_controller
	if controller == null:
		return false
	if not controller.get_is_active() or not controller.get_has_tracking_data():
		return false
	# Input capability must be decided from the active interaction profile, not
	# from the haptics policy or the presence of hand joints. Pico can expose
	# UNKNOWN-source optical joints while its physical controller is active.
	var profile := _controller_profile(controller)
	if profile.find(HAND_INTERACTION_PROFILE_HINT) != -1:
		return false
	if not profile.is_empty():
		return true
	# Some runtimes briefly expose the pose before publishing its profile. Keep
	# the old conservative fallback for that short window.
	return not is_optical_hand_tracking_active(hand)


## Get the head (camera) pose as a Dictionary.
## Returns: { "position": Vector3, "rotation": Quaternion, "timestamp_ns": int }
func get_head_pose() -> Dictionary:
	if not _camera:
		return {}
	var tracked := false
	if _xr_interface != null:
		tracked = _xr_interface.get_tracking_status() == XRInterface.XR_NORMAL_TRACKING
	var t := _camera.global_transform
	return {
		"tracked": tracked,
		"position": t.origin,
		"rotation": t.basis.get_rotation_quaternion(),
		"timestamp_ns": Time.get_ticks_usec() * 1000
	}


## Get controller pose for given hand (0=left, 1=right).
## Returns: { "position": Vector3, "rotation": Quaternion, "is_active": bool }
func get_controller_pose(hand: int) -> Dictionary:
	var controller: XRController3D = _left_controller if hand == 0 else _right_controller
	if not controller:
		return _get_cached_controller_pose(hand)

	if not is_controller_mode_active(hand):
		return _get_cached_controller_pose(hand)

	var t := controller.global_transform
	var pose := {
		"position": t.origin,
		"rotation": t.basis.get_rotation_quaternion(),
		"is_active": true,
		"timestamp_ns": Time.get_ticks_usec() * 1000,
	}
	_last_controller_poses[hand] = pose
	_last_controller_pose_msec[hand] = Time.get_ticks_msec()
	return pose


## Get controller input state for given hand (0=left, 1=right).
## Returns dictionary of standard OpenXR input bindings.
func get_controller_input(hand: int) -> Dictionary:
	var controller: XRController3D = _left_controller if hand == 0 else _right_controller
	if not controller:
		return _get_cached_controller_input(hand)

	if not is_controller_mode_active(hand):
		return _get_cached_controller_input(hand)

	var primary := controller.get_vector2("primary")
	var input := {
		"trigger": controller.get_float("trigger"),
		"trigger_click": controller.get_float("trigger_click"),
		"grip": controller.get_float("grip"),
		"grip_click": controller.get_float("grip_click"),
		"grip_force": controller.get_float("grip_force"),
		"select_button": controller.get_float("select_button"),
		"primary": primary,
		"joystick": primary,
		"primary_x": primary.x,
		"primary_y": primary.y,
		"primary_click": controller.get_float("primary_click"),
		"ax_button": controller.get_float("ax_button"),
		"by_button": controller.get_float("by_button"),
		"menu_button": controller.get_float("menu_button"),
		"timestamp_ns": Time.get_ticks_usec() * 1000,
	}
	_last_controller_inputs[hand] = input
	_last_controller_input_msec[hand] = Time.get_ticks_msec()
	return input


func _get_cached_controller_pose(hand: int) -> Dictionary:
	var now_msec := Time.get_ticks_msec()
	if now_msec - int(_last_controller_pose_msec[hand]) <= CONTROLLER_CACHE_TTL_MSEC:
		return _last_controller_poses[hand]
	return {"is_active": false}


func _get_cached_controller_input(hand: int) -> Dictionary:
	var now_msec := Time.get_ticks_msec()
	if now_msec - int(_last_controller_input_msec[hand]) <= CONTROLLER_CACHE_TTL_MSEC:
		return _last_controller_inputs[hand]
	return {}


## Get hand joint tracking data for given hand (0=left, 1=right).
## Uses XRHandTracker (OpenXR XR_EXT_hand_tracking).
## Returns an array of 26 joint dictionaries.
func get_hand_joints(hand: int) -> Array[Dictionary]:
	var joints: Array[Dictionary] = []

	var tracker_path := "/user/hand_tracker/left" if hand == 0 else "/user/hand_tracker/right"
	var tracker = XRServer.get_tracker(tracker_path)
	if not tracker or not (tracker is XRHandTracker):
		return joints

	var hand_tracker: XRHandTracker = tracker as XRHandTracker

	# XRHandTracker has 26 joints (0-25) per the OpenXR spec
	for joint_idx in range(26):
		var flags := hand_tracker.get_hand_joint_flags(joint_idx)
		if flags == 0:
			# Joint not tracked
			joints.append({"tracked": false})
			continue

		var transform := hand_tracker.get_hand_joint_transform(joint_idx)
		var radius := hand_tracker.get_hand_joint_radius(joint_idx)
		var linear_velocity := hand_tracker.get_hand_joint_linear_velocity(joint_idx)
		var angular_velocity := hand_tracker.get_hand_joint_angular_velocity(joint_idx)

		joints.append({
			"tracked": true,
			"position": transform.origin,
			"rotation": transform.basis.get_rotation_quaternion(),
			"radius": radius,
			"linear_velocity": linear_velocity,
			"angular_velocity": angular_velocity,
		})

	return joints


## Get capabilities of the current runtime.
func get_capabilities() -> Dictionary:
	return {
		"platform": _platform_name,
		"hand_tracking": _hand_tracking_available,
		"has_left_controller": is_controller_mode_active(0),
		"has_right_controller": is_controller_mode_active(1),
		"left_hand_tracking": is_optical_hand_tracking_active(0),
		"right_hand_tracking": is_optical_hand_tracking_active(1),
	}


func _hand_tracker_name(hand: int) -> StringName:
	return LEFT_HAND_TRACKER if hand == 0 else RIGHT_HAND_TRACKER


func _controller_profile(controller: XRController3D) -> String:
	if controller == null:
		return ""
	var tracker := XRServer.get_tracker(controller.tracker)
	if tracker is XRPositionalTracker:
		return String((tracker as XRPositionalTracker).profile)
	return ""


func get_controller_profile(hand: int) -> String:
	var controller: XRController3D = _left_controller if hand == 0 else _right_controller
	return _controller_profile(controller)


## Collect all tracking data into a single dictionary.
func get_all_tracking_data() -> Dictionary:
	var data := {
		"head": get_head_pose(),
		"left_controller_pose": get_controller_pose(0),
		"right_controller_pose": get_controller_pose(1),
		"left_controller_input": get_controller_input(0),
		"right_controller_input": get_controller_input(1),
		"left_hand_joints": get_hand_joints(0),
		"right_hand_joints": get_hand_joints(1),
		"timestamp_ns": Time.get_ticks_usec() * 1000,
	}
	tracking_data_ready.emit(data)
	return data
