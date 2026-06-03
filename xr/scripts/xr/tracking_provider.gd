class_name TrackingProvider
extends Node
## Unified OpenXR tracking abstraction.
## Provides head pose, controller poses+input, and hand joint data
## using ONLY standard OpenXR APIs. No vendor-specific calls.

signal tracking_data_ready(data: Dictionary)

const CONTROLLER_CACHE_TTL_MSEC := 250

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
	var tracker := XRServer.get_tracker("/user/hand_tracker/left")
	return tracker != null


## Get the head (camera) pose as a Dictionary.
## Returns: { "position": Vector3, "rotation": Quaternion, "timestamp_ns": int }
func get_head_pose() -> Dictionary:
	if not _camera:
		return {}
	var t := _camera.global_transform
	return {
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

	var is_active: bool = controller.get_is_active()
	if not is_active:
		return _get_cached_controller_pose(hand)

	var t := controller.global_transform
	var pose := {
		"position": t.origin,
		"rotation": t.basis.get_rotation_quaternion(),
		"is_active": true
	}
	_last_controller_poses[hand] = pose
	_last_controller_pose_msec[hand] = Time.get_ticks_msec()
	return pose


## Get controller input state for given hand (0=left, 1=right).
## Returns dictionary of standard OpenXR input bindings.
func get_controller_input(hand: int) -> Dictionary:
	var controller: XRController3D = _left_controller if hand == 0 else _right_controller
	if not controller or not controller.get_is_active():
		return _get_cached_controller_input(hand)

	var input := {
		"trigger": controller.get_float("trigger"),
		"trigger_click": controller.get_float("trigger_click"),
		"grip": controller.get_float("grip"),
		"grip_click": controller.get_float("grip_click"),
		"grip_force": controller.get_float("grip_force"),
		"select_button": controller.get_float("select_button"),
		"primary_x": controller.get_vector2("primary").x,
		"primary_y": controller.get_vector2("primary").y,
		"primary_click": controller.get_float("primary_click"),
		"ax_button": controller.get_float("ax_button"),
		"by_button": controller.get_float("by_button"),
		"menu_button": controller.get_float("menu_button"),
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
		"has_left_controller": _left_controller != null and _left_controller.get_is_active() if _left_controller else false,
		"has_right_controller": _right_controller != null and _right_controller.get_is_active() if _right_controller else false,
	}


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
