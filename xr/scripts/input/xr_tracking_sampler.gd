class_name XrTrackingSampler
extends RefCounted
## Captures one complete XR tracking snapshot from a single render sample.
##
## High-rate OpenXR fields are read together. Body and motion-tracker data are
## sampled at a configurable lower cadence and cached with their own sample
## timestamps so multiple protocol senders can share the same snapshot shape.

const SCHEMA_VERSION := 1
const DEFAULT_BODY_RATE_HZ := 30
const DEFAULT_BODY_SAMPLE_INTERVAL_US := 33333
const DEFAULT_MAX_MOTION_TRACKERS := 3
const BODY_TRACKER_NAME := &"/user/body_tracker"
const BODY_JOINT_COUNT := 87
const MOTION_POSE_NAMES := [&"default", &"grip", &"aim", &"pose"]
const RESERVED_TRACKER_NAMES := [
	&"head", &"left_hand", &"right_hand", BODY_TRACKER_NAME,
	&"/user/hand_tracker/left", &"/user/hand_tracker/right", &"/user/face_tracker",
]
const PICO_BODY_JOINT_INT_EXTENSIONS := [
	"posture", "velocity_flags", "acceleration_flags",
]
const PICO_BODY_JOINT_VECTOR_EXTENSIONS := [
	"linear_velocity", "angular_velocity",
	"linear_acceleration", "angular_acceleration",
]
const PICO_BODY_STATUS_VALID := 1
const PICO_BODY_STATUS_LIMITED := 2
const PICO_MIN_BODY_SPAN_M := 0.05

var tracking_provider: TrackingProvider
var _frame_id := 0
var _requested_streams: Dictionary = {}
var _body_sample_interval_us := DEFAULT_BODY_SAMPLE_INTERVAL_US
var _last_body_sample_us := -DEFAULT_BODY_SAMPLE_INTERVAL_US
var _cached_body: Variant = null
var _cached_motion_trackers: Array = []
var _pico_bridge: Object = null
var _strict_pico_body_validation := false
var _include_predicted_display_time := false
var _started_pico_body := false


func configure(stream_config: Dictionary) -> void:
	var body_rate_hz := clampi(
		int(stream_config.get("body_rate_hz", DEFAULT_BODY_RATE_HZ)), 1, 144)
	_body_sample_interval_us = maxi(1, int(1_000_000.0 / float(body_rate_hz)))
	_strict_pico_body_validation = bool(
		stream_config.get("strict_pico_body_validation", false))
	_include_predicted_display_time = bool(
		stream_config.get("include_predicted_display_time", false))
	if _last_body_sample_us < 0:
		_last_body_sample_us = -_body_sample_interval_us
	_requested_streams.clear()
	for stream in stream_config.get("streams", []):
		_requested_streams[str(stream)] = true
	_resolve_pico_bridge()
	if _pico_bridge != null:
		if _wants("body") and _pico_bridge.has_method("start_body_tracking"):
			var started: Variant = _pico_bridge.call("start_body_tracking", {})
			_started_pico_body = typeof(started) != TYPE_BOOL or bool(started)
		if _wants("motion_trackers") and _pico_bridge.has_method("request_motion_trackers"):
			_pico_bridge.call("request_motion_trackers", DEFAULT_MAX_MOTION_TRACKERS)


func reset() -> void:
	_last_body_sample_us = -_body_sample_interval_us
	_cached_body = null
	_cached_motion_trackers.clear()


func shutdown() -> void:
	if _started_pico_body and _pico_bridge != null \
			and _pico_bridge.has_method("stop_body_tracking"):
		_pico_bridge.call("stop_body_tracking")
	_started_pico_body = false
	reset()


func sample_frame() -> Dictionary:
	if tracking_provider == null:
		return {}
	# Captured once. All high-rate fields below are read without yielding.
	var timestamp_ns := _ticks_usec() * 1000
	var predicted_display_time_ns := timestamp_ns
	if _include_predicted_display_time:
		predicted_display_time_ns = _predicted_display_time_ns(timestamp_ns)
	_frame_id += 1
	var raw := tracking_provider.get_all_tracking_data()
	_refresh_slow_tracking(timestamp_ns)
	return {
		"schema_version": SCHEMA_VERSION,
		"frame_id": _frame_id,
		"timestamp_ns": timestamp_ns,
		"predicted_display_time_ns": predicted_display_time_ns,
		"coordinate_space": "godot_world",
		"head": _pose(raw.get("head", {}), timestamp_ns),
		"controllers": {
			"left": _controller(raw.get("left_controller_pose", {}), raw.get("left_controller_input", {}), 0, timestamp_ns),
			"right": _controller(raw.get("right_controller_pose", {}), raw.get("right_controller_input", {}), 1, timestamp_ns),
		},
		"hands": {
			"left": _hand(raw.get("left_hand_joints", []), 0, timestamp_ns),
			"right": _hand(raw.get("right_hand_joints", []), 1, timestamp_ns),
		},
		"body": _cached_body,
		"motion_trackers": _cached_motion_trackers,
	}


func _wants(name: String) -> bool:
	return _requested_streams.is_empty() or _requested_streams.has(name)


func _controller(
		pose_raw: Dictionary, input_raw: Dictionary, hand: int, timestamp_ns: int
) -> Dictionary:
	if not _wants("controllers"):
		return {}
	var values := {}
	for key in input_raw.keys():
		if str(key) == "timestamp_ns":
			continue
		var value: Variant = input_raw[key]
		if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			values[str(key)] = float(value)
		elif typeof(value) == TYPE_BOOL:
			values[str(key)] = 1.0 if bool(value) else 0.0
	return {
		"pose": _pose(pose_raw, timestamp_ns),
		"input": {
			"sample_timestamp_ns": int(input_raw.get("timestamp_ns", timestamp_ns)),
			"values": values,
		},
		"interaction_profile": tracking_provider.get_controller_profile(hand),
	}


func _hand(joints_raw: Array, hand: int, timestamp_ns: int) -> Dictionary:
	if not _wants("hands"):
		return {}
	var joints: Array = []
	for joint_index in range(joints_raw.size()):
		var raw: Dictionary = joints_raw[joint_index] if joints_raw[joint_index] is Dictionary else {}
		var tracked := bool(raw.get("tracked", false))
		joints.append({
			"joint": joint_index,
			"flags": int(raw.get("flags", 1 if tracked else 0)),
			"tracked": tracked,
			"radius_m": float(raw.get("radius", raw.get("radius_m", 0.0))),
			"pose": _pose(raw, timestamp_ns, tracked),
		})
	return {
		"active": tracking_provider.is_hand_tracking_active(hand),
		"sample_timestamp_ns": timestamp_ns,
		"joints": joints,
	}


func _pose(raw: Dictionary, timestamp_ns: int, default_valid: bool = true) -> Dictionary:
	var valid := bool(raw.get("valid", raw.get("is_active", default_valid))) and not raw.is_empty()
	var result := {
		"valid": valid,
		"sample_timestamp_ns": int(raw.get("timestamp_ns", raw.get("sample_timestamp_ns", timestamp_ns))),
		"position": _vec3(raw.get("position", null)),
		"rotation": _quat(raw.get("rotation", null)),
	}
	if raw.has("linear_velocity"):
		result["linear_velocity"] = _vec3(raw.get("linear_velocity"))
	if raw.has("angular_velocity"):
		result["angular_velocity"] = _vec3(raw.get("angular_velocity"))
	if raw.has("confidence"):
		result["confidence"] = float(raw.get("confidence"))
	return result


func _refresh_slow_tracking(timestamp_ns: int) -> void:
	var now_us := _ticks_usec()
	if now_us - _last_body_sample_us < _body_sample_interval_us:
		return
	_last_body_sample_us = now_us
	if _wants("body"):
		_cached_body = _sample_body(timestamp_ns)
	if _wants("motion_trackers"):
		_cached_motion_trackers = _sample_motion_trackers(timestamp_ns)


func _sample_body(timestamp_ns: int) -> Variant:
	if _pico_bridge != null and _pico_bridge.has_method("sample_body_joints"):
		var pico_raw: Variant = _pico_bridge.call("sample_body_joints")
		if pico_raw is Dictionary and bool(pico_raw.get("active", false)):
			var pico_body := pico_raw as Dictionary
			var status_ready := not _strict_pico_body_validation \
				or not _pico_bridge_has_body_tracking2() \
				or _pico_body_state_ready(pico_body)
			var span_ready := not _strict_pico_body_validation \
				or _pico_body_position_span(pico_body) >= PICO_MIN_BODY_SPAN_M
			if status_ready and span_ready:
				return _body_from_records(pico_body, "pico_bd_24", timestamp_ns)

	var tracker := XRServer.get_tracker(BODY_TRACKER_NAME)
	if not (tracker is XRBodyTracker):
		return null
	var body_tracker := tracker as XRBodyTracker
	if not body_tracker.has_tracking_data:
		return null
	var joints: Array = []
	for joint_index in range(BODY_JOINT_COUNT):
		var flags := int(body_tracker.get_joint_flags(joint_index))
		if flags == 0:
			continue
		var transform := body_tracker.get_joint_transform(joint_index)
		joints.append({
			"joint": joint_index,
			"flags": flags,
			"tracked": true,
			"radius_m": 0.0,
			"pose": _pose({
				"position": transform.origin,
				"rotation": transform.basis.get_rotation_quaternion(),
			}, timestamp_ns),
		})
	return {
		"active": not joints.is_empty(),
		"sample_timestamp_ns": timestamp_ns,
		"joint_set": "godot_xr_body_tracker_v1",
		"body_flags": int(body_tracker.body_flags),
		"joints": joints,
	}


func _body_from_records(raw: Dictionary, joint_set: String, timestamp_ns: int) -> Dictionary:
	var source_timestamp_ns := int(raw.get("source_timestamp_ns", timestamp_ns))
	var joints: Array = []
	for raw_joint_v in raw.get("joints", []):
		if not (raw_joint_v is Dictionary):
			continue
		var raw_joint := raw_joint_v as Dictionary
		var flags := int(raw_joint.get("flags", 0))
		var joint_source_timestamp_ns := int(
			raw_joint.get("source_timestamp_ns", source_timestamp_ns))
		var joint := {
			"joint": int(raw_joint.get("joint", joints.size())),
			"flags": flags,
			"tracked": flags != 0,
			"radius_m": float(raw_joint.get("radius_m", 0.0)),
			"source_timestamp_ns": joint_source_timestamp_ns,
			"pose": _pose(raw_joint, joint_source_timestamp_ns, flags != 0),
		}
		for key in PICO_BODY_JOINT_INT_EXTENSIONS:
			if raw_joint.has(key):
				joint[key] = int(raw_joint.get(key))
		for key in PICO_BODY_JOINT_VECTOR_EXTENSIONS:
			if raw_joint.has(key):
				joint[key] = _vec3(raw_joint.get(key))
		joints.append(joint)
	return {
		"active": bool(raw.get("active", false)),
		"sample_timestamp_ns": timestamp_ns,
		"source_timestamp_ns": source_timestamp_ns,
		"joint_set": joint_set,
		"body_flags": int(raw.get("body_flags", 0)),
		"joints": joints,
	}


func _sample_motion_trackers(timestamp_ns: int) -> Array:
	if _pico_bridge != null and _pico_bridge.has_method("sample_motion_trackers"):
		var pico_records: Variant = _pico_bridge.call(
			"sample_motion_trackers", DEFAULT_MAX_MOTION_TRACKERS)
		if pico_records is Array and not pico_records.is_empty():
			var pico_result: Array = []
			for record_v in pico_records:
				if not (record_v is Dictionary):
					continue
				var record := record_v as Dictionary
				var tracker := {
					"id": str(record.get("id", pico_result.size())),
					"tracker_index": int(record.get("tracker_index", pico_result.size())),
					"pose": _pose(record, timestamp_ns, bool(record.get("tracking_valid", false))),
					"battery_level": record.get("battery_level", null),
				}
				for key in PICO_BODY_JOINT_INT_EXTENSIONS:
					if record.has(key):
						tracker[key] = int(record.get(key))
				for key in PICO_BODY_JOINT_VECTOR_EXTENSIONS:
					if record.has(key):
						tracker[key] = _vec3(record.get(key))
				pico_result.append(tracker)
			return pico_result

	var result: Array = []
	var trackers := XRServer.get_trackers(XRServer.TRACKER_ANY)
	for key in trackers.keys():
		if result.size() >= DEFAULT_MAX_MOTION_TRACKERS:
			break
		var name := StringName(str(key))
		if RESERVED_TRACKER_NAMES.has(name) or not _looks_like_motion_tracker(str(name)):
			continue
		var pose_record := _tracker_pose(trackers[key])
		if pose_record.is_empty():
			continue
		result.append({
			"id": str(name),
			"tracker_index": result.size(),
			"pose": _pose(pose_record, timestamp_ns),
		})
	return result


func _tracker_pose(tracker: Object) -> Dictionary:
	if tracker == null or not tracker.has_method("has_pose") or not tracker.has_method("get_pose"):
		return {}
	for pose_name in MOTION_POSE_NAMES:
		if not bool(tracker.call("has_pose", pose_name)):
			continue
		var pose: Object = tracker.call("get_pose", pose_name)
		if pose == null or not bool(pose.call("get_has_tracking_data")):
			continue
		var transform: Transform3D = pose.call("get_adjusted_transform")
		return {
			"valid": true,
			"position": transform.origin,
			"rotation": transform.basis.get_rotation_quaternion(),
		}
	return {}


func _looks_like_motion_tracker(name: String) -> bool:
	var lowered := name.to_lower()
	return lowered.contains("motion_tracker") \
		or lowered.contains("vive_tracker") \
		or lowered.contains("waist") \
		or lowered.contains("foot")


func _resolve_pico_bridge() -> void:
	if _pico_bridge != null:
		return
	var main_loop := Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return
	var autoload := (main_loop as SceneTree).root.get_node_or_null("PicoOpenXRBridge")
	if autoload != null and autoload.has_method("get_bridge"):
		_pico_bridge = autoload.call("get_bridge")


func _predicted_display_time_ns(fallback_timestamp_ns: int) -> int:
	if _pico_bridge != null and _pico_bridge.has_method("get_predicted_display_time_ns"):
		var raw: Variant = _pico_bridge.call("get_predicted_display_time_ns")
		if typeof(raw) == TYPE_INT or typeof(raw) == TYPE_FLOAT:
			var predicted_display_time_ns := int(raw)
			if predicted_display_time_ns > 0:
				return predicted_display_time_ns
	return fallback_timestamp_ns


func _pico_body_state_ready(body: Dictionary) -> bool:
	var status := int(body.get("status", 0))
	return status == PICO_BODY_STATUS_VALID or status == PICO_BODY_STATUS_LIMITED


func _pico_bridge_has_body_tracking2() -> bool:
	if _pico_bridge == null or not _pico_bridge.has_method("get_status"):
		return false
	var raw: Variant = _pico_bridge.call("get_status")
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	return bool((raw as Dictionary).get("pico_body_tracking2_extension", false))


func _pico_body_position_span(body: Dictionary) -> float:
	var joints_v: Variant = body.get("joints", [])
	if typeof(joints_v) != TYPE_ARRAY:
		return 0.0
	var have_bounds := false
	var bounds_min := Vector3.ZERO
	var bounds_max := Vector3.ZERO
	for entry_v in (joints_v as Array):
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var entry := entry_v as Dictionary
		if int(entry.get("flags", 0)) == 0:
			continue
		var position_v: Variant = _pico_joint_position(entry)
		if not (position_v is Vector3):
			continue
		var position := position_v as Vector3
		if have_bounds:
			bounds_min = bounds_min.min(position)
			bounds_max = bounds_max.max(position)
		else:
			bounds_min = position
			bounds_max = position
			have_bounds = true
	return (bounds_max - bounds_min).length() if have_bounds else 0.0


func _pico_joint_position(joint: Dictionary) -> Variant:
	var raw: Variant = joint.get("position", null)
	var position := Vector3.ZERO
	if raw is Vector3:
		position = raw as Vector3
	elif raw is Dictionary:
		var record := raw as Dictionary
		if not record.has("x") or not record.has("y") or not record.has("z"):
			return null
		position = Vector3(float(record.get("x")), float(record.get("y")), float(record.get("z")))
	elif raw is Array and raw.size() >= 3:
		position = Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	else:
		return null
	if not is_finite(position.x) or not is_finite(position.y) or not is_finite(position.z):
		return null
	return position


func _ticks_usec() -> int:
	return Time.get_ticks_usec()


func _vec3(value: Variant) -> Array:
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Dictionary:
		return [
			float(value.get("x", 0.0)),
			float(value.get("y", 0.0)),
			float(value.get("z", 0.0)),
		]
	if value is Array and value.size() >= 3:
		return [float(value[0]), float(value[1]), float(value[2])]
	return [0.0, 0.0, 0.0]


func _quat(value: Variant) -> Array:
	if value is Quaternion:
		return [value.x, value.y, value.z, value.w]
	if value is Dictionary:
		return [
			float(value.get("x", 0.0)),
			float(value.get("y", 0.0)),
			float(value.get("z", 0.0)),
			float(value.get("w", 1.0)),
		]
	if value is Array and value.size() >= 4:
		return [float(value[0]), float(value[1]), float(value[2]), float(value[3])]
	return [0.0, 0.0, 0.0, 1.0]
