extends Node
class_name BodyMotionSampler

const BODY_TRACKER_NAME := &"/user/body_tracker"
const BODY_JOINT_COUNT := 87
const BODY_SAMPLE_INTERVAL_US := 33333
const MOTION_SAMPLE_INTERVAL_US := 11111
const DEFAULT_MOTION_TRACKERS := 2
const MAX_MOTION_TRACKERS := 3
const PICO_BODY_STATUS_VALID := 1
const PICO_BODY_STATUS_LIMITED := 2
const PICO_MIN_BODY_SPAN_M := 0.05
const MOTION_POSE_NAMES := [&"default", &"grip", &"aim", &"pose"]
const RESERVED_TRACKER_NAMES := [
	&"head",
	&"left_hand",
	&"right_hand",
	&"/user/body_tracker",
	&"/user/hand_tracker/left",
	&"/user/hand_tracker/right",
	&"/user/face_tracker"
]
const MOTION_TRACKER_CANDIDATES := [
	&"/user/motion_tracker/0",
	&"/user/motion_tracker/1",
	&"/user/motion_tracker/2",
	&"/user/pico_motion_tracker/0",
	&"/user/pico_motion_tracker/1",
	&"/user/pico_motion_tracker/2",
	&"motion_tracker_0",
	&"motion_tracker_1",
	&"motion_tracker_2",
	&"/user/vive_tracker_htcx/role/waist",
	&"/user/vive_tracker_htcx/role/left_foot",
	&"/user/vive_tracker_htcx/role/right_foot"
]

var writer: Object
# WP4: canonical-frame sink (default: FrameWriterShim over `writer`).
var _frame_sink: Object
var pose_sampler: Object
var pico_openxr_bridge: Object
var _record_body_tracking := false
var _record_motion_trackers := false
var _max_motion_trackers := DEFAULT_MOTION_TRACKERS
var _last_body_sample_us := 0
var _last_motion_sample_us := 0
var _motion_tracker_names: Array[StringName] = []
var _tracker_refresh_countdown := 0

var _sample_count := 0
var _body_writes := 0
var _body_joint_count := 0
var _motion_writes := 0
var _motion_event_writes := 0
var _last_power_key_event_signature := ""

# Runtime that produced the most recently observed body-tracking sample.
# This is what session_spool_writer writes into manifest.sources.body_tracking
# so the offline viewer can pick the right skeleton table.
#   ""                    : never observed a body sample (no body data in mp4)
#   "pico_bd"             : XR_BD_body_tracking + XR_PICO_body_tracking2 (24 joints)
#   "godot_xr_body_tracker": Godot XRBodyTracker @ /user/body_tracker, fed by
#                            the Meta vendor AAR's XR_FB_body_tracking +
#                            XR_META_body_tracking_full_body (up to 87 joints).
var _observed_body_runtime := ""
# Last value of XRBodyTracker.body_flags (BODY_FLAG_UPPER/LOWER/HANDS_SUPPORTED)
# on the fallback path. Reported as `runtime_body_flags` in the manifest so a
# consumer can tell "Quest with only upper-body tracked" from "Quest with full
# body". Always 0 on the PICO path (which has its own status word instead).
var _last_fallback_body_flags := 0
# Rate-limit the "why don't I see body data" diagnostic so a sustained miss
# (no permission, runtime not loaded, ...) doesn't drown out the rest of
# logcat. Same string is suppressed for BODY_DIAG_REPRINT_SECONDS.
const BODY_DIAG_REPRINT_SECONDS := 5.0
var _last_body_diag_message := ""
var _last_body_diag_ticks_us := 0


# Rate-limit a diagnostic line by a stable `key` rather than the full message
# text — body_flags / joint counts in the message change frame-to-frame, so
# matching on the rendered string would let "same situation, different stats"
# spam logcat at 30 Hz.
func _log_body_diag_once(key: String, message: String) -> void:
	var now := Time.get_ticks_usec()
	if key == _last_body_diag_message and now - _last_body_diag_ticks_us < int(BODY_DIAG_REPRINT_SECONDS * 1_000_000):
		return
	_last_body_diag_message = key
	_last_body_diag_ticks_us = now
	push_warning("[BodyMotionSampler] %s" % message)


func configure(p_writer: Object, p_pose_sampler: Object, p_pico_openxr_bridge: Object = null) -> void:
	writer = p_writer
	_frame_sink = FrameWriterShim.new(writer) if writer != null else null
	pose_sampler = p_pose_sampler
	pico_openxr_bridge = p_pico_openxr_bridge
	_refresh_motion_trackers()


func set_frame_sink(sink: Object) -> void:
	_frame_sink = sink


func set_capture_options(options: Dictionary) -> void:
	# Reset runtime tracking state at the start of each session so a previous
	# session's observed runtime cannot leak into the manifest of a session
	# that ended up producing zero body samples (the previous "observed:
	# godot_xr_body_tracker" would otherwise survive into the new manifest).
	_observed_body_runtime = ""
	_last_fallback_body_flags = 0
	_record_body_tracking = bool(options.get("record_body_tracking", false))
	_record_motion_trackers = bool(options.get("record_motion_trackers", false))
	if _record_body_tracking and _record_motion_trackers and _pico_body_supported():
		_log_body_diag_once(
			"pico_body_tracking_disables_independent_trackers",
			"Pico body tracking is enabled; skipping independent motion tracker sampling to keep full-body capture mode.")
		_record_motion_trackers = false
	_max_motion_trackers = clampi(int(options.get("max_motion_trackers", DEFAULT_MOTION_TRACKERS)), 0, MAX_MOTION_TRACKERS)
	if pico_openxr_bridge != null:
		if _record_body_tracking and pico_openxr_bridge.has_method("start_body_tracking"):
			pico_openxr_bridge.call("start_body_tracking", {})
		if _record_motion_trackers and pico_openxr_bridge.has_method("request_motion_trackers"):
			pico_openxr_bridge.call("request_motion_trackers", _max_motion_trackers)
	if _record_motion_trackers:
		_refresh_motion_trackers()


func stop() -> void:
	if pico_openxr_bridge != null and pico_openxr_bridge.has_method("stop_body_tracking"):
		pico_openxr_bridge.call("stop_body_tracking")
	_record_body_tracking = false
	_record_motion_trackers = false
	_last_power_key_event_signature = ""


func pop_metrics() -> Dictionary:
	var metrics := {
		"samples": _sample_count,
		"body_writes": _body_writes,
		"body_joints": _body_joint_count,
		"motion_writes": _motion_writes,
		"motion_event_writes": _motion_event_writes,
		"motion_trackers": _max_motion_trackers if _record_motion_trackers and _pico_motion_supported() else _motion_tracker_names.size(),
		"pico_openxr": _pico_bridge_status()
	}
	_sample_count = 0
	_body_writes = 0
	_body_joint_count = 0
	_motion_writes = 0
	_motion_event_writes = 0
	return metrics


func sample(timestamp_ns: int) -> void:
	if _frame_sink == null:
		return
	if not _record_body_tracking and not _record_motion_trackers:
		return
	_sample_count += 1
	var resolved_ts := _resolve_timestamp(timestamp_ns)
	var now_us := Time.get_ticks_usec()
	if _record_body_tracking and now_us - _last_body_sample_us >= BODY_SAMPLE_INTERVAL_US:
		_sample_body(resolved_ts)
		_last_body_sample_us = now_us
	if _record_motion_trackers and now_us - _last_motion_sample_us >= MOTION_SAMPLE_INTERVAL_US:
		_sample_motion_trackers(resolved_ts)
		_last_motion_sample_us = now_us


func _resolve_timestamp(default_ticks_ns: int) -> int:
	if pose_sampler != null and pose_sampler.has_method("resolve_pose_timestamp_ns"):
		return int(pose_sampler.call("resolve_pose_timestamp_ns", default_ticks_ns))
	return default_ticks_ns


func _sample_body(timestamp_ns: int) -> void:
	if _sample_pico_body(timestamp_ns):
		return
	# Diagnostic logs: pre-fix this code path silently returned three different
	# ways ("no tracker", "wrong tracker type", "no tracking data"), so a Quest
	# operator who saw no body in Rerun had no way to tell which one applied.
	# We rate-limit so a sustained "no tracker" doesn't flood logcat.
	var tracker := XRServer.get_tracker(BODY_TRACKER_NAME)
	if tracker == null:
		_log_body_diag_once("no_tracker",
			"no XRBodyTracker registered at %s — Meta runtime did not initialize XR_FB_body_tracking (check BODY_TRACKING permission + meta_xr_features/body_tracking export flag)" % str(BODY_TRACKER_NAME))
		return
	if not (tracker is XRBodyTracker):
		_log_body_diag_once("wrong_tracker_class",
			"tracker at %s is %s, not XRBodyTracker" % [str(BODY_TRACKER_NAME), tracker.get_class()])
		return
	var body_tracker := tracker as XRBodyTracker
	if not body_tracker.has_tracking_data:
		_log_body_diag_once("no_tracking_data",
			"XRBodyTracker present at %s but has_tracking_data=false; runtime body_flags=%d (UPPER/LOWER/HANDS support bits)" % [str(BODY_TRACKER_NAME), int(body_tracker.body_flags)])
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
			"rotation": {"x": q.x, "y": q.y, "z": q.z, "w": q.w}
		})
	if joints.is_empty():
		return
	_last_fallback_body_flags = int(body_tracker.body_flags)
	if bool(_frame_sink.on_frame(BodyFrame.build(timestamp_ns, _last_fallback_body_flags, joints, "godot_xr_body_tracker"))):
		if _observed_body_runtime != "godot_xr_body_tracker":
			# First successful write — log so the operator can see body tracking
			# really came online (and confirm the joint count matches their
			# expectation, e.g. ~70 for FB upper-body vs ~84 for Meta full body).
			print("[BodyMotionSampler] body tracking online via XRBodyTracker @ %s (%d joints, body_flags=%d)" % [str(BODY_TRACKER_NAME), joints.size(), _last_fallback_body_flags])
		_observed_body_runtime = "godot_xr_body_tracker"
		_body_writes += 1
		_body_joint_count += joints.size()


# Snapshot of the body-tracking runtime that produced the most recent samples.
# session_spool_writer queries this when finalizing the manifest so the offline
# viewer (web/app/scripts/spatialmp4_to_rrd.py) can pick the matching skeleton
# table (PICO 24-joint BD vs Godot/Meta 87-joint XRBodyTracker).
func get_runtime_info() -> Dictionary:
	var info := {
		"observed_runtime": _observed_body_runtime,
	}
	match _observed_body_runtime:
		"pico_bd":
			info["extension"] = "pico_bd_body_tracking"
			info["joint_set"] = "pico_bd_24"
			info["joint_count"] = 24
		"godot_xr_body_tracker":
			# Whether the Meta runtime actually granted the full-body extension
			# is decided at OpenXR session init by the godotopenxr-meta vendor
			# AAR; we surface XRBodyTracker.body_flags so the consumer can see
			# UPPER/LOWER/HANDS support bits without having to demux the mp4.
			info["extension"] = "meta_fb_body_tracking"
			info["joint_set"] = "godot_xr_body_tracker_v1"
			info["joint_count"] = BODY_JOINT_COUNT
			info["runtime_body_flags"] = _last_fallback_body_flags
		_:
			info["extension"] = ""
			info["joint_set"] = ""
			info["joint_count"] = 0
	return info


func _sample_motion_trackers(timestamp_ns: int) -> void:
	if _sample_pico_motion_trackers(timestamp_ns):
		_sample_pico_motion_power_key(timestamp_ns)
		return
	if _tracker_refresh_countdown <= 0 or _motion_tracker_names.is_empty():
		_refresh_motion_trackers()
		_tracker_refresh_countdown = 90
	else:
		_tracker_refresh_countdown -= 1
	for index in range(mini(_motion_tracker_names.size(), _max_motion_trackers)):
		var tracker_name := _motion_tracker_names[index]
		var tracker := XRServer.get_tracker(tracker_name)
		if tracker == null:
			continue
		var pose_record := _tracker_pose_record(tracker)
		if pose_record.is_empty():
			continue
		if bool(_frame_sink.on_frame(MotionTrackerFrame.build_pose(index, String(tracker_name), timestamp_ns, pose_record["transform"], true))):
			_motion_writes += 1


func _refresh_motion_trackers() -> void:
	var names: Array[StringName] = []
	for candidate in MOTION_TRACKER_CANDIDATES:
		var tracker := XRServer.get_tracker(candidate)
		if tracker != null and _tracker_pose_record(tracker).size() > 0:
			names.append(candidate)
	var trackers := XRServer.get_trackers(XRServer.TRACKER_ANY)
	for key in trackers.keys():
		var name := StringName(str(key))
		if names.has(name) or RESERVED_TRACKER_NAMES.has(name):
			continue
		var lowered := str(name).to_lower()
		if not _looks_like_motion_tracker(lowered):
			continue
		var tracker: Object = trackers[key]
		if tracker != null and _tracker_pose_record(tracker).size() > 0:
			names.append(name)
	_motion_tracker_names.clear()
	for index in range(mini(names.size(), _max_motion_trackers)):
		_motion_tracker_names.append(names[index])


func _looks_like_motion_tracker(name: String) -> bool:
	# WP6 sweep: vendor-name heuristics live in xr/scripts/platform/.
	return PicoPlatformAdapter.looks_like_motion_tracker_name(name)


func _tracker_pose_record(tracker: Object) -> Dictionary:
	if tracker == null or not tracker.has_method("has_pose") or not tracker.has_method("get_pose"):
		return {}
	for pose_name in MOTION_POSE_NAMES:
		if not bool(tracker.call("has_pose", pose_name)):
			continue
		var pose: Object = tracker.call("get_pose", pose_name)
		if pose == null:
			continue
		var tracking_valid := true
		if pose.has_method("get_has_tracking_data"):
			tracking_valid = bool(pose.call("get_has_tracking_data"))
		if not tracking_valid:
			continue
		var transform := Transform3D.IDENTITY
		if pose.has_method("get_adjusted_transform"):
			transform = pose.call("get_adjusted_transform") as Transform3D
		else:
			transform = pose.get("transform") as Transform3D
		return {"pose": pose_name, "transform": transform}
	return {}


func _sample_pico_body(timestamp_ns: int) -> bool:
	if pico_openxr_bridge == null or not pico_openxr_bridge.has_method("sample_body_joints"):
		return false
	if not _pico_body_supported():
		return false
	var body_v: Variant = pico_openxr_bridge.call("sample_body_joints")
	if typeof(body_v) != TYPE_DICTIONARY:
		_log_body_diag_once("pico_body_sample_not_dict",
			"Pico body sample returned %s, expected Dictionary" % type_string(typeof(body_v)))
		return true
	var body := body_v as Dictionary
	var joints_v: Variant = body.get("joints", [])
	if typeof(joints_v) != TYPE_ARRAY:
		_log_body_diag_once("pico_body_joints_not_array",
			"Pico body sample joints returned %s, expected Array" % type_string(typeof(joints_v)))
		return true
	var joints := joints_v as Array
	if joints.is_empty():
		return true
	if not _pico_body_sample_ready(body, joints):
		return true
	var body_flags := int(body.get("body_flags", 0))
	if bool(_frame_sink.on_frame(BodyFrame.build(timestamp_ns, body_flags, joints, "pico_bd", body))):
		_observed_body_runtime = "pico_bd"
		_body_writes += 1
		_body_joint_count += joints.size()
	return true


func _pico_body_sample_ready(body: Dictionary, joints: Array) -> bool:
	var status := _pico_bridge_status()
	if bool(status.get("pico_body_tracking2_extension", false)):
		var body_status := int(body.get("status", 0))
		if body_status != PICO_BODY_STATUS_VALID and body_status != PICO_BODY_STATUS_LIMITED:
			_log_body_diag_once(
				_pico_body_diag_key(body, "not_ready"),
				"Pico body sample not ready; skipping recording write: %s"
				% _pico_body_diag_summary(body, joints)
			)
			return false
	var raw_span := _pico_raw_joint_span(joints)
	if raw_span >= 0.0 and raw_span < PICO_MIN_BODY_SPAN_M:
		_log_body_diag_once(
			_pico_body_diag_key(body, "collapsed"),
			"Pico body sample collapsed to one point; skipping recording write: %s"
			% _pico_body_diag_summary(body, joints)
		)
		return false
	return true


func _pico_body_diag_key(body: Dictionary, prefix: String) -> String:
	return "%s:%s:%s:%s:%s" % [
		prefix,
		str(body.get("status", "")),
		str(body.get("message", "")),
		str(body.get("locate_result", "")),
		str(body.get("state_result", "")),
	]


func _pico_body_diag_summary(body: Dictionary, joints: Array) -> String:
	return "status=%s message=%s joints=%d locate_result=%s state_result=%s raw_span=%.4f" % [
		str(body.get("status", "")),
		str(body.get("message", "")),
		joints.size(),
		str(body.get("locate_result", "")),
		str(body.get("state_result", "")),
		_pico_raw_joint_span(joints),
	]


func _pico_raw_joint_span(joints: Array) -> float:
	var have_bounds := false
	var bounds_min := Vector3.ZERO
	var bounds_max := Vector3.ZERO
	for entry_v in joints:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var position := _pico_joint_position(entry_v as Dictionary)
		if position.is_empty():
			continue
		var p: Vector3 = position["value"]
		if have_bounds:
			bounds_min = bounds_min.min(p)
			bounds_max = bounds_max.max(p)
		else:
			bounds_min = p
			bounds_max = p
			have_bounds = true
	if not have_bounds:
		return -1.0
	return (bounds_max - bounds_min).length()


func _pico_joint_position(entry: Dictionary) -> Dictionary:
	var position_v: Variant = entry.get("position", null)
	match typeof(position_v):
		TYPE_VECTOR3:
			return {"value": position_v}
		TYPE_DICTIONARY:
			var dict := position_v as Dictionary
			if dict.has("x") and dict.has("y") and dict.has("z"):
				return {"value": Vector3(float(dict["x"]), float(dict["y"]), float(dict["z"]))}
		TYPE_ARRAY:
			var arr := position_v as Array
			if arr.size() >= 3:
				return {"value": Vector3(float(arr[0]), float(arr[1]), float(arr[2]))}
	return {}


func _sample_pico_motion_trackers(timestamp_ns: int) -> bool:
	if pico_openxr_bridge == null or not pico_openxr_bridge.has_method("sample_motion_trackers"):
		return false
	if not _pico_motion_supported():
		return false
	var trackers: Array = pico_openxr_bridge.call("sample_motion_trackers", _max_motion_trackers)
	for record in trackers:
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var tracking_valid := bool(record.get("tracking_valid", false))
		if not tracking_valid:
			continue
		var transform: Transform3D = record.get("transform", Transform3D.IDENTITY)
		var tracker_index := int(record.get("tracker_index", 0))
		var source := "pico_motion_tracker_%s" % str(record.get("id", tracker_index))
		if bool(_frame_sink.on_frame(MotionTrackerFrame.build_pose(tracker_index, source, timestamp_ns, transform, tracking_valid, record))):
			_motion_writes += 1
	return true


func _sample_pico_motion_power_key(timestamp_ns: int) -> void:
	# Mirrors the legacy `writer.has_method("write_motion_tracker_event")`
	# guard (LivePushWriter has no motion-tracker event surface).
	if _frame_sink == null or not _frame_sink.has_method("supports_motion_tracker_events") \
			or not _frame_sink.supports_motion_tracker_events():
		return
	var status := _pico_bridge_status()
	var event: Variant = status.get("last_motion_power_key_event", {})
	if typeof(event) != TYPE_DICTIONARY or (event as Dictionary).is_empty():
		return
	var signature := JSON.stringify(event)
	if signature.is_empty() or signature == _last_power_key_event_signature:
		return
	_last_power_key_event_signature = signature
	if bool(_frame_sink.on_frame(MotionTrackerFrame.build_event(timestamp_ns, "power_key", event))):
		_motion_event_writes += 1


func _pico_bridge_status() -> Dictionary:
	if pico_openxr_bridge == null or not pico_openxr_bridge.has_method("get_status"):
		return {}
	var status: Variant = pico_openxr_bridge.call("get_status")
	if typeof(status) == TYPE_DICTIONARY:
		return status
	return {}


func _pico_body_supported() -> bool:
	var status := _pico_bridge_status()
	return bool(status.get("bd_body_tracking_extension", false)) and bool(status.get("bd_body_tracking_supported", false))


func _pico_motion_supported() -> bool:
	var status := _pico_bridge_status()
	return bool(status.get("motion_tracking_extension", false))
