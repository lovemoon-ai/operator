class_name XrStateSender
extends Node
## The host session's `xr_state` channel: one XrStateFrame per render sample.
##
## XrTrackingSource samples into its StreamBinding and XrStateSink encodes the
## tick; this channel owns stream cadence, the tracking interlock and transport
## delivery on the ctrl connection.

const SCHEMA_VERSION := 1
const DEFAULT_RATE_HZ := 72

signal frame_sent(frame_id: int, timestamp_ns: int)
signal tracking_blocked(report: Dictionary)

var tracking_provider: TrackingProvider
var tcp_handler: TcpHandler
var _sending := false
var _min_send_interval := 1.0 / float(DEFAULT_RATE_HZ)
var _time_since_last_send := 0.0
var _tracking_sampler: XrTrackingSource
var _tracking_interlocked := false
var _has_published_tracking := false


func configure(stream_config: Dictionary) -> void:
	var rate_hz := clampi(int(stream_config.get("rate_hz", DEFAULT_RATE_HZ)), 1, 144)
	_min_send_interval = 1.0 / float(rate_hz)
	var sampler := _ensure_sampler()
	sampler.configure(stream_config)
	if not sampler.has_tracker_demand():
		# A new head/controller/hand-only request is not governed by an old
		# body-session latch. Changing to another body request does NOT re-arm.
		rearm_tracking()
	var requested_streams: Dictionary = {}
	for stream in stream_config.get("streams", []):
		requested_streams[str(stream)] = true
	print("[XrStateSender] configured schema=%d rate=%d streams=%s" % [
		int(stream_config.get("schema_version", SCHEMA_VERSION)),
		rate_hz,
		str(requested_streams.keys()),
	])


func set_sending(enabled: bool) -> void:
	if _sending == enabled:
		return
	_sending = enabled
	_time_since_last_send = 0.0
	if enabled:
		_ensure_sampler().activate()
	elif _tracking_sampler != null:
		_tracking_sampler.reset()
		if not _tracking_interlocked:
			_tracking_sampler.shutdown()


func rearm_tracking() -> void:
	_tracking_interlocked = false
	_has_published_tracking = false


func is_tracking_interlocked() -> bool:
	return _tracking_interlocked


func tracking_report() -> Dictionary:
	if _tracking_sampler == null:
		return {"needed": false, "allowed": true, "phase": "off"}
	var report := _tracking_sampler.tracking_report()
	report["rearm_required"] = _tracking_interlocked
	return report


func shutdown() -> void:
	_sending = false
	if _tracking_sampler != null:
		_tracking_sampler.shutdown()


func _exit_tree() -> void:
	shutdown()


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
	if not sampler.is_tracking_ready():
		_on_tracking_invalidated(sampler.tracking_status())
		return
	if _tracking_interlocked:
		return
	var snapshot := sampler.sample_frame()
	if snapshot.is_empty():
		return
	if not sampler.snapshot_tracking_ready(snapshot):
		_on_tracking_invalidated({"phase": "waiting_body"})
		return
	var frame := XrStateSink.frame_v1(snapshot)
	if _send_frame(frame) == OK:
		_has_published_tracking = true
		frame_sent.emit(int(frame.get("frame_id", 0)), int(frame.get("timestamp_ns", 0)))


func _send_frame(frame: Dictionary) -> Error:
	var payload := JSON.stringify(frame).to_utf8_buffer()
	return tcp_handler.send_latest_command("XrStateFrame", payload)


func _ensure_sampler() -> XrTrackingSource:
	if _tracking_sampler == null:
		_tracking_sampler = XrTrackingSource.new()
		_tracking_sampler.tracking_invalidated.connect(_on_tracking_invalidated)
	_tracking_sampler.tracking_provider = tracking_provider
	return _tracking_sampler


func _on_tracking_invalidated(report: Dictionary) -> void:
	if not _sending or _tracking_interlocked:
		return
	if not _has_published_tracking and report.get("phase") in ["waiting_body", "motion_setup"]:
		return # Already-calibrated startup may still be waiting for its first frame.
	_tracking_interlocked = true
	if _tracking_sampler != null:
		_tracking_sampler.reset()
	# No robot-independent neutral command exists in XrStateFrame v1. Closing
	# transport gives the host an explicit loss instead of stale valid poses.
	call_deferred("_disconnect_for_tracking", report)


func _disconnect_for_tracking(report: Dictionary) -> void:
	if not _tracking_interlocked:
		return
	if tcp_handler != null:
		tcp_handler.disconnect_from_robot()
	tracking_blocked.emit(report)

