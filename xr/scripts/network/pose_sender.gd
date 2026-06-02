class_name PoseSender
extends Node
## Collects tracking data from TrackingProvider, serializes to JSON
## in the format compatible with existing Operator protocol, and
## sends via TcpHandler.
##
## JSON format (must match existing C# implementation exactly):
## {
##   "Head": { "pose": "x,y,z,qx,qy,qz,qw" },
##   "Controller": {
##     "left": { "pose": "x,y,z,qx,qy,qz,qw", "trigger": 0.0, ... },
##     "right": { "pose": "x,y,z,qx,qy,qz,qw", "trigger": 0.0, ... }
##   },
##   "Hand": {
##     "leftHand": [ { "pose": "x,y,z,qx,qy,qz,qw", "radius": 0.01 }, ... ],
##     "rightHand": [ { "pose": "x,y,z,qx,qy,qz,qw", "radius": 0.01 }, ... ]
##   },
##   "timeStampNs": 123456789
## }

## Reference to the tracking provider (set by main.gd)
var tracking_provider: TrackingProvider
## Reference to the TCP handler (set by main.gd)
var tcp_handler: TcpHandler

## Whether pose sending is active
var _sending: bool = false
## Send rate limiting: minimum interval between sends (seconds)
var _min_send_interval: float = 1.0 / 72.0  # ~72 Hz default
## Time accumulator for rate limiting
var _time_since_last_send: float = 0.0


func _physics_process(delta: float) -> void:
	if not _sending:
		return
	if not tcp_handler or not tcp_handler.is_connected_to_robot():
		return
	if not tracking_provider:
		return

	_time_since_last_send += delta
	if _time_since_last_send < _min_send_interval:
		return
	_time_since_last_send = 0.0

	var pose_data := _build_pose_data()
	var json_str := JSON.stringify(pose_data)
	var json_bytes := json_str.to_utf8_buffer()
	tcp_handler.send_command("Tracking", json_bytes)


## Build the complete pose data dictionary in the compatible format.
func _build_pose_data() -> Dictionary:
	var head := tracking_provider.get_head_pose()
	var left_ctrl := tracking_provider.get_controller_pose(0)
	var right_ctrl := tracking_provider.get_controller_pose(1)
	var left_input := tracking_provider.get_controller_input(0)
	var right_input := tracking_provider.get_controller_input(1)
	var left_hand := tracking_provider.get_hand_joints(0)
	var right_hand := tracking_provider.get_hand_joints(1)

	var data := {
		"Head": _format_head(head),
		"Controller": {
			"left": _format_controller(left_ctrl, left_input),
			"right": _format_controller(right_ctrl, right_input),
		},
		"Hand": {
			"leftHand": _format_hand_joints(left_hand),
			"rightHand": _format_hand_joints(right_hand),
		},
		"timeStampNs": Time.get_ticks_usec() * 1000,
	}
	return data


## Format head pose to compatible format: { "pose": "x,y,z,qx,qy,qz,qw" }
func _format_head(head: Dictionary) -> Dictionary:
	if head.is_empty():
		return {}
	var pos: Vector3 = head["position"]
	var rot: Quaternion = head["rotation"]
	return {
		"pose": _pose_string(pos, rot)
	}


## Format controller data to compatible format.
func _format_controller(pose: Dictionary, input: Dictionary) -> Dictionary:
	if pose.is_empty() or not pose.get("is_active", false):
		return {}

	var pos: Vector3 = pose["position"]
	var rot: Quaternion = pose["rotation"]
	var result := {
		"pose": _pose_string(pos, rot)
	}

	# Add input values if available
	if not input.is_empty():
		result["trigger"] = input.get("trigger", 0.0)
		result["triggerClick"] = input.get("trigger_click", 0.0)
		result["grip"] = input.get("grip", 0.0)
		result["gripClick"] = input.get("grip_click", 0.0)
		result["primaryX"] = input.get("primary_x", 0.0)
		result["primaryY"] = input.get("primary_y", 0.0)
		result["primaryClick"] = input.get("primary_click", 0.0)
		result["axButton"] = input.get("ax_button", 0.0)
		result["byButton"] = input.get("by_button", 0.0)
		result["menuButton"] = input.get("menu_button", 0.0)

	return result


## Format hand joint array to compatible format.
## Each joint: { "pose": "x,y,z,qx,qy,qz,qw", "radius": float }
func _format_hand_joints(joints: Array[Dictionary]) -> Array:
	var result := []
	for joint in joints:
		if not joint.get("tracked", false):
			result.append({})
			continue
		var pos: Vector3 = joint["position"]
		var rot: Quaternion = joint["rotation"]
		var radius: float = joint.get("radius", 0.0)
		result.append({
			"pose": _pose_string(pos, rot),
			"radius": radius,
		})
	return result


## Format position + quaternion as the compatible comma-separated string.
## Format: "x,y,z,qx,qy,qz,qw"
func _pose_string(pos: Vector3, rot: Quaternion) -> String:
	return "%s,%s,%s,%s,%s,%s,%s" % [
		_float_str(pos.x), _float_str(pos.y), _float_str(pos.z),
		_float_str(rot.x), _float_str(rot.y), _float_str(rot.z), _float_str(rot.w)
	]


## Format float to string, matching C# default float formatting.
func _float_str(v: float) -> String:
	# Use snprintf-style to avoid locale issues, match C# behavior
	return "%.6f" % v


## Enable or disable pose sending.
func set_sending(enabled: bool) -> void:
	_sending = enabled
	_time_since_last_send = 0.0
	if enabled:
		print("[PoseSender] Sending enabled")
	else:
		print("[PoseSender] Sending disabled")


## Set the send rate in Hz.
func set_send_rate(hz: float) -> void:
	if hz > 0:
		_min_send_interval = 1.0 / hz


## Check if currently sending.
func is_sending() -> bool:
	return _sending
