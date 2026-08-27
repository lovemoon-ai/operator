class_name XrStateSender
extends Node
## Publishes one complete XR device-state snapshot per render sample.
##
## Tracking capture and slow-stream caching live in XrTrackingSampler. This
## sender keeps the existing XrStateFrame v1 wire schema stable while handling
## stream cadence and transport delivery.

const XrTrackingSamplerScript := preload("res://scripts/input/xr_tracking_sampler.gd")
const SCHEMA_VERSION := 1
const DEFAULT_RATE_HZ := 72
const V1_BODY_JOINT_FIELDS := ["joint", "flags", "tracked", "radius_m", "pose"]
const V1_MOTION_TRACKER_FIELDS := ["id", "tracker_index", "pose", "battery_level"]

signal frame_sent(frame_id: int, timestamp_ns: int)

var tracking_provider: TrackingProvider
var tcp_handler: TcpHandler
var _sending := false
var _min_send_interval := 1.0 / float(DEFAULT_RATE_HZ)
var _time_since_last_send := 0.0
var _tracking_sampler: XrTrackingSampler


func configure(stream_config: Dictionary) -> void:
	var rate_hz := clampi(int(stream_config.get("rate_hz", DEFAULT_RATE_HZ)), 1, 144)
	_min_send_interval = 1.0 / float(rate_hz)
	var sampler := _ensure_sampler()
	sampler.configure(stream_config)
	var requested_streams: Dictionary = {}
	for stream in stream_config.get("streams", []):
		requested_streams[str(stream)] = true
	print("[XrStateSender] configured schema=%d rate=%d streams=%s" % [
		int(stream_config.get("schema_version", SCHEMA_VERSION)),
		rate_hz,
		str(requested_streams.keys()),
	])


func set_sending(enabled: bool) -> void:
	_sending = enabled
	_time_since_last_send = 0.0
	if not enabled and _tracking_sampler != null:
		_tracking_sampler.reset()


func is_sending() -> bool:
	return _sending


func _process(delta: float) -> void:
	if not _sending or tracking_provider == null or tcp_handler == null:
		return
	if not tcp_handler.is_connected_to_robot():
		return
	_time_since_last_send += delta
	if _time_since_last_send < _min_send_interval:
		return
	_time_since_last_send -= _min_send_interval

	var sampler := _ensure_sampler()
	sampler.tracking_provider = tracking_provider
	var snapshot := sampler.sample_frame()
	if snapshot.is_empty():
		return
	var frame := _frame_v1(snapshot)
	var payload := JSON.stringify(frame).to_utf8_buffer()
	if tcp_handler.send_command("XrStateFrame", payload) == OK:
		frame_sent.emit(int(frame.get("frame_id", 0)), int(frame.get("timestamp_ns", 0)))


func _ensure_sampler() -> XrTrackingSampler:
	if _tracking_sampler == null:
		_tracking_sampler = XrTrackingSamplerScript.new()
	_tracking_sampler.tracking_provider = tracking_provider
	return _tracking_sampler


func _frame_v1(snapshot: Dictionary) -> Dictionary:
	var frame := snapshot.duplicate(true)
	frame.erase("predicted_display_time_ns")
	var body_v: Variant = frame.get("body", null)
	if body_v is Dictionary:
		var body := body_v as Dictionary
		body.erase("source_timestamp_ns")
		var joints_v: Variant = body.get("joints", [])
		if joints_v is Array:
			body["joints"] = _body_joints_v1(
				joints_v as Array,
				int(body.get("sample_timestamp_ns", frame.get("timestamp_ns", 0))),
			)
	var trackers_v: Variant = frame.get("motion_trackers", [])
	if trackers_v is Array:
		frame["motion_trackers"] = _filter_records(
			trackers_v as Array, V1_MOTION_TRACKER_FIELDS)
	return frame


## Field projection only. Which joints exist is the sampler's decision per
## source: PICO reports a fixed set and keeps every entry regardless of `flags`,
## while the Godot XRBodyTracker branch already drops `flags == 0` at the point
## of capture. Dropping untracked joints again here would hand a v1 consumer a
## short array and mis-index every joint after the gap.
func _body_joints_v1(records: Array, sample_timestamp_ns: int) -> Array:
	var filtered := _filter_records(records, V1_BODY_JOINT_FIELDS)
	for joint_v in filtered:
		var joint := joint_v as Dictionary
		var pose_v: Variant = joint.get("pose", null)
		if pose_v is Dictionary:
			var pose := pose_v as Dictionary
			pose["sample_timestamp_ns"] = sample_timestamp_ns
	return filtered


func _filter_records(records: Array, allowed_fields: Array) -> Array:
	var filtered: Array = []
	for record_v in records:
		if not (record_v is Dictionary):
			continue
		var record := record_v as Dictionary
		var output := {}
		for field in allowed_fields:
			if record.has(field):
				output[field] = record[field]
		filtered.append(output)
	return filtered
