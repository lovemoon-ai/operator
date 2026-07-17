class_name IsaacTeleopBodySampler
extends Node
## Low-latency body source for the external IsaacTeleop stream.
##
## Recording uses BodyMotionSampler's native writer. This sampler is kept
## separate because its output is a canonical SensorFrame rather than MP4 or
## JSONL, and therefore must not reactivate the retired recording fallback.

const BODY_TRACKER_NAME := &"/user/body_tracker"
const BODY_JOINT_COUNT := 87
const BODY_SAMPLE_INTERVAL_US := 33333

const PICO_BODY_STATUS_VALID := 1
const PICO_BODY_STATUS_LIMITED := 2

var _pose_sampler: Object
var _pico_openxr_bridge: Object
var _frame_sink: Object
var _record_body_tracking := false
var _last_body_sample_us := 0
var _coordinate_space := OpenXRExportSpace.coordinate_space_id(OpenXRExportSpace.DEFAULT)


func configure(p_pose_sampler: Object, p_pico_openxr_bridge: Object = null) -> void:
	_pose_sampler = p_pose_sampler
	_pico_openxr_bridge = p_pico_openxr_bridge


func set_frame_sink(sink: Object) -> void:
	_frame_sink = sink


func set_capture_options(options: Dictionary) -> void:
	_record_body_tracking = bool(options.get("record_body_tracking", false))
	if _record_body_tracking \
			and _pico_openxr_bridge != null \
			and _pico_openxr_bridge.has_method("start_body_tracking"):
		_pico_openxr_bridge.call("start_body_tracking", {})


func stop() -> void:
	if _pico_openxr_bridge != null and _pico_openxr_bridge.has_method("stop_body_tracking"):
		_pico_openxr_bridge.call("stop_body_tracking")
	_record_body_tracking = false


func sample(timestamp_ns: int) -> void:
	if _frame_sink == null or not _record_body_tracking:
		return
	var now_us := Time.get_ticks_usec()
	if now_us - _last_body_sample_us < BODY_SAMPLE_INTERVAL_US:
		return
	_last_body_sample_us = now_us
	var resolved_timestamp := timestamp_ns
	if _pose_sampler != null and _pose_sampler.has_method("resolve_pose_timestamp_ns"):
		resolved_timestamp = int(
			_pose_sampler.call("resolve_pose_timestamp_ns", timestamp_ns))
	if _sample_pico_body(resolved_timestamp):
		return
	_sample_meta_body(resolved_timestamp)


func _sample_pico_body(timestamp_ns: int) -> bool:
	if not _pico_body_supported():
		return false
	if not _pico_openxr_bridge.has_method("sample_body_joints"):
		return true
	var body_v: Variant = _pico_openxr_bridge.call("sample_body_joints")
	if not (body_v is Dictionary):
		return true
	var body := body_v as Dictionary
	var joints_v: Variant = body.get("joints", [])
	if not (joints_v is Array):
		return true
	var joints := joints_v as Array
	if joints.is_empty():
		return true
	var status := int(body.get("status", PICO_BODY_STATUS_VALID))
	if status != PICO_BODY_STATUS_VALID and status != PICO_BODY_STATUS_LIMITED:
		return true
	_emit_body_frame(
		timestamp_ns,
		joints,
		"pico_bd",
		int(body.get("body_flags", 0)),
		body)
	return true


func _sample_meta_body(timestamp_ns: int) -> void:
	var tracker := XRServer.get_tracker(BODY_TRACKER_NAME)
	if tracker == null or not (tracker is XRBodyTracker):
		return
	var body_tracker := tracker as XRBodyTracker
	if not body_tracker.has_tracking_data:
		return
	var joints: Array = []
	for joint in range(BODY_JOINT_COUNT):
		var flags := int(body_tracker.get_joint_flags(joint))
		if flags == 0:
			continue
		var transform := body_tracker.get_joint_transform(joint)
		var q := transform.basis.get_rotation_quaternion()
		var p := transform.origin
		joints.append({
			"joint": joint,
			"flags": flags,
			"radius_m": 0.0,
			"position": {"x": p.x, "y": p.y, "z": p.z},
			"rotation": {"x": q.x, "y": q.y, "z": q.z, "w": q.w},
		})
	if joints.is_empty():
		return
	_emit_body_frame(
		timestamp_ns,
		joints,
		"godot_xr_body_tracker",
		int(body_tracker.body_flags))


func _emit_body_frame(
	timestamp_ns: int,
	joints: Array,
	runtime: String,
	body_flags: int,
	metadata: Dictionary = {},
) -> void:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.BODY
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = _coordinate_space
	frame.source_id = "body"
	frame.payload = {
		"body_flags": body_flags,
		"joints": joints,
		"runtime": runtime,
		"metadata": metadata,
	}
	_frame_sink.on_frame(frame)


func _pico_body_supported() -> bool:
	if _pico_openxr_bridge == null or not _pico_openxr_bridge.has_method("get_status"):
		return false
	var status_v: Variant = _pico_openxr_bridge.call("get_status")
	if not (status_v is Dictionary):
		return false
	var status := status_v as Dictionary
	return bool(status.get("bd_body_tracking_extension", false)) \
		and bool(status.get("bd_body_tracking_supported", false))
