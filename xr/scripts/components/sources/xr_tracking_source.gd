class_name XrTrackingSource
extends RefCounted
signal tracking_invalidated(report: Dictionary)
## Capability layer (components/sources): the host session's tracking source.
## Each sample() reads head, controllers (pose + full input map), hands, body
## and motion trackers once, emits them as SensorFrames on `binding`, and
## closes the tick with StreamBinding.end_of_tick(). It never encodes a wire
## format: `state_sink` (an XrStateSink attached to `binding`) assembles the
## tick; composition roots may attach further sinks to `binding`.
##
## Poses are read through TrackingProvider in godot_world: it owns the UI input
## capture and controller-mode rules teleop depends on. Body and motion
## trackers are sampled at a lower cadence under a TrackingSessionService lease
## and each tick re-delivers the latest sample with its own timestamp.
##
## Timebase: every frame of a tick carries one timestamp_ns with PoseSampler's
## definition — the OpenXR predicted display time moved into godot_ticks_ns
## when the runtime exposes it and the capture plugin has its XrTime offset,
## else the sampling instant. A raw XrTime is never emitted as timestamp_ns.

const DEFAULT_BODY_RATE_HZ := 30
const DEFAULT_BODY_SAMPLE_INTERVAL_US := 33333
const DEFAULT_MAX_MOTION_TRACKERS := 3
const COORDINATE_SPACE := "godot_world"
const BODY_TRACKER_NAME := &"/user/body_tracker"
const BODY_JOINT_COUNT := 87
const MOTION_POSE_NAMES := [&"default", &"grip", &"aim", &"pose"]
const RESERVED_TRACKER_NAMES := [
	&"head", &"left_hand", &"right_hand", BODY_TRACKER_NAME,
	&"/user/hand_tracker/left", &"/user/hand_tracker/right", &"/user/face_tracker",
]
const PICO_MOTION_EXTENSIONS := [
	"posture", "velocity_flags", "acceleration_flags",
	"linear_velocity", "angular_velocity",
	"linear_acceleration", "angular_acceleration",
]
const PICO_BODY_STATUS_VALID := 1
const PICO_BODY_STATUS_LIMITED := 2
const PICO_MIN_BODY_SPAN_M := 0.05

var tracking_provider: TrackingProvider
var tracking_sessions: Object
var binding := StreamBinding.new()
var state_sink := XrStateSink.new()
var _requested_streams: Dictionary = {}
var _body_sample_interval_us := DEFAULT_BODY_SAMPLE_INTERVAL_US
var _last_body_sample_us := -DEFAULT_BODY_SAMPLE_INTERVAL_US
var _body_frame: SensorFrame = null
var _motion_frames: Array = []
var _pico_bridge: Object = null
var _strict_pico_body_validation := false
var _include_predicted_display_time := false
var _activated := false
var _tracking_generation := -1
var _timebase_resolved := false
var _display_time: Object = null
var _capture_provider: Object = null
var _xr_time_offset_ns := 0


func _init() -> void:
	binding.add_sink(state_sink)


func configure(stream_config: Dictionary) -> void:
	reset()
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
	if _activated:
		activate()


func activate() -> void:
	_activated = true
	if tracking_sessions == null:
		tracking_sessions = TrackingSessionService.shared()
	if tracking_sessions != null:
		if tracking_sessions.has_signal("changed") and not tracking_sessions.is_connected("changed", _on_tracking_changed):
			tracking_sessions.connect("changed", _on_tracking_changed)
		# Preserve the protocol's existing body-priority semantics. Never ask
		# for independent tracker mode as a side effect of requesting "all".
		var capabilities: Array = ["body"] if _wants("body") else (["motion"] if _wants("motion_trackers") else [])
		tracking_sessions.acquire(self, capabilities, DEFAULT_MAX_MOTION_TRACKERS)


func tracking_status() -> Dictionary:
	activate()
	return tracking_sessions.status(self) if tracking_sessions != null else {"allowed": _pico_bridge == null, "phase": "unavailable"}


func tracking_report() -> Dictionary:
	# UI inspection must never activate a source or acquire a tracking lease.
	if not _activated:
		return {"needed": false, "allowed": true, "phase": "off"}
	if tracking_sessions == null:
		return {"needed": has_tracker_demand(), "allowed": _pico_bridge == null, "phase": "unavailable"}
	return tracking_sessions.status(self)


func is_tracking_ready() -> bool:
	return bool(tracking_status().get("allowed", false))


func has_tracker_demand() -> bool:
	return _wants("body") or _wants("motion_trackers")


func snapshot_tracking_ready(snapshot: Dictionary) -> bool:
	if _pico_bridge == null:
		return true
	if _wants("body"):
		var body: Variant = snapshot.get("body")
		return body is Dictionary and not body.get("joints", []).is_empty()
	if _wants("motion_trackers"):
		return not snapshot.get("motion_trackers", []).is_empty()
	return true


func _on_tracking_changed() -> void:
	if not _activated or tracking_sessions == null:
		return
	var report: Dictionary = tracking_sessions.status(self)
	if not bool(report.get("allowed", false)):
		reset()
		tracking_invalidated.emit(report)


func reset() -> void:
	_last_body_sample_us = -_body_sample_interval_us
	_body_frame = null
	_motion_frames.clear()


func shutdown() -> void:
	if tracking_sessions != null:
		tracking_sessions.release(self)
	_activated = false
	reset()


## One tick through `binding`, returning the XrStateSink snapshot ({} when
## there is no tracking provider).
func sample_frame() -> Dictionary:
	sample()
	return state_sink.take_snapshot()


func sample() -> void:
	if tracking_provider == null:
		return
	var readiness := tracking_status()
	var generation := int(readiness.get("generation", 0))
	if generation != _tracking_generation or not bool(readiness.get("allowed", false)):
		reset()
		_tracking_generation = generation
	# Captured once. All high-rate fields below are read without yielding.
	var timestamp_ns := _pose_timestamp_ns(_ticks_usec() * 1000)
	var clock := _frame(SensorFrameType.CLOCK, "xr_tracking", timestamp_ns, {
		"predicted_display_time_ns":
			_predicted_display_time_ns(timestamp_ns) if _include_predicted_display_time else timestamp_ns,
	})
	var raw := tracking_provider.get_all_tracking_data()
	if bool(readiness.get("allowed", false)):
		_refresh_slow_tracking(timestamp_ns)
	binding.on_frame(clock)
	binding.on_frame(_frame(SensorFrameType.POSE, "head", timestamp_ns, raw.get("head", {})))
	if _wants("controllers"):
		for hand in [0, 1]:
			var side := "left" if hand == 0 else "right"
			binding.on_frame(_frame(SensorFrameType.CONTROLLER, side + "_controller", timestamp_ns, {
				"pose": raw.get(side + "_controller_pose", {}),
				"input": raw.get(side + "_controller_input", {}),
				"interaction_profile": tracking_provider.get_controller_profile(hand),
			}))
	if _wants("hands"):
		for hand in [0, 1]:
			var side := "left" if hand == 0 else "right"
			binding.on_frame(_frame(SensorFrameType.HAND, side + "_hand", timestamp_ns, {
				"active": tracking_provider.is_hand_tracking_active(hand),
				"joints": raw.get(side + "_hand_joints", []),
			}))
	if _body_frame != null:
		binding.on_frame(_body_frame)
	for motion_frame in _motion_frames:
		binding.on_frame(motion_frame)
	binding.end_of_tick()


func _frame(frame_type: int, source_id: String, timestamp_ns: int, payload: Dictionary, valid := true) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = frame_type
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = COORDINATE_SPACE
	frame.source_id = source_id
	frame.valid = valid
	frame.payload = payload
	return frame


func _wants(name: String) -> bool:
	return _requested_streams.is_empty() or _requested_streams.has(name)


func _refresh_slow_tracking(timestamp_ns: int) -> void:
	var now_us := _ticks_usec()
	if now_us - _last_body_sample_us < _body_sample_interval_us:
		return
	_last_body_sample_us = now_us
	if _wants("body"):
		var body: Variant = _sample_body()
		_body_frame = _frame(SensorFrameType.BODY, "body", timestamp_ns, body) if body is Dictionary else null
	if _wants("motion_trackers"):
		_motion_frames.clear()
		for tracker_v in _sample_motion_trackers():
			var tracker := tracker_v as Dictionary
			_motion_frames.append(_frame(
				SensorFrameType.MOTION_TRACKER, str(tracker["id"]), timestamp_ns, tracker,
				bool(tracker.get("valid", true))))


## Body record for XrStateSink: {active, joint_set, body_flags,
## [source_timestamp_ns], joints: raw joint records}, or null.
func _sample_body() -> Variant:
	if _pico_bridge != null:
		var pico_raw: Variant = tracking_sessions.sample_body(self) if tracking_sessions != null else {}
		if pico_raw is Dictionary and bool(pico_raw.get("active", false)):
			var pico_body := pico_raw as Dictionary
			var status_ready := not _strict_pico_body_validation \
				or not _pico_bridge_has_body_tracking2() \
				or _pico_body_state_ready(pico_body)
			var span_ready := not _strict_pico_body_validation \
				or _pico_body_position_span(pico_body) >= PICO_MIN_BODY_SPAN_M
			if status_ready and span_ready:
				var record := pico_body.duplicate()
				record["joint_set"] = "pico_bd_24"
				return record
		return null # No synthetic/other-runtime fallback around the Pico gate.

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
			"position": transform.origin,
			"rotation": transform.basis.get_rotation_quaternion(),
		})
	return {
		"active": not joints.is_empty(),
		"joint_set": "godot_xr_body_tracker_v1",
		"body_flags": int(body_tracker.body_flags),
		"joints": joints,
	}


## Motion tracker records for XrStateSink: {id, tracker_index, valid, pose:
## raw record, fields: wire extras}.
func _sample_motion_trackers() -> Array:
	if _pico_bridge != null and _wants("body"):
		# sample_motion_trackers can itself request devices. Suppress that path
		# even while body startup fails; never steal the trackers from body mode.
		return []
	if _pico_bridge != null:
		var pico_records: Variant = tracking_sessions.sample_motion(self) if tracking_sessions != null else []
		var pico_result: Array = []
		if pico_records is Array:
			for record_v in pico_records:
				if not (record_v is Dictionary):
					continue
				var record := record_v as Dictionary
				var fields := {"battery_level": record.get("battery_level", null)}
				for key in PICO_MOTION_EXTENSIONS:
					if record.has(key):
						fields[key] = record[key]
				pico_result.append({
					"id": str(record.get("id", pico_result.size())),
					"tracker_index": int(record.get("tracker_index", pico_result.size())),
					"valid": bool(record.get("tracking_valid", false)),
					"pose": record,
					"fields": fields,
				})
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
		result.append({"id": str(name), "tracker_index": result.size(), "pose": pose_record})
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


## PoseSampler.resolve_pose_timestamp_ns's definition, refusing the raw XrTime
## domain while the capture plugin's offset is unknown (teleop-only builds
## ship no capture plugin and keep the sampling instant).
func _pose_timestamp_ns(ticks_ns: int) -> int:
	if not _timebase_resolved:
		_timebase_resolved = true
		var platform := PlatformRegistry.shared()
		_display_time = platform.depth_time_extension()
		if _display_time != null:
			_capture_provider = platform.fallback_capture_provider()
	if _display_time == null or _capture_provider == null:
		return ticks_ns
	if _xr_time_offset_ns == 0:
		var offset: Variant = _capture_provider.call("getXrTimeToGodotTicksOffsetNs")
		_xr_time_offset_ns = int(offset) if offset != null else 0
		if _xr_time_offset_ns == 0:
			return ticks_ns
	var raw: Variant = _display_time.call("get_predicted_display_time_ns")
	if raw == null or int(raw) <= 0:
		return ticks_ns
	return int(raw) + _xr_time_offset_ns


## XRoboToolkit's legacy predictTime: the Pico bridge's raw XrTime.
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
