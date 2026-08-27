class_name XrtSender
extends Node
## Direct, latest-only XRoboToolkit sender. There is deliberately no queue:
## each render tick samples once and either writes that frame or drops it.

const XrtProtocolScript = preload("res://scripts/compat/xrobot_toolkit/xrt_protocol.gd")
const XrtTrackingEncoderScript = preload("res://scripts/compat/xrobot_toolkit/xrt_tracking_encoder.gd")
const XrTrackingSamplerScript = preload("res://scripts/input/xr_tracking_sampler.gd")

const TRACKING_RATE_HZ := 72
const BODY_RATE_HZ := 50
const HEARTBEAT_INTERVAL_SEC := 10.0
## A wall clock that lands further behind than this is treated as a step (NTP),
## not as jitter, and the top timestamp re-baselines onto the new clock.
const MAX_BACKWARD_CLOCK_STEP_NS := 1_000_000_000

signal frame_sent(timestamp_ns: int)
signal handshake_sent
signal protocol_ready
signal send_failed(reason: String)

var client: Node
var sampler: RefCounted
var encoder := XrtTrackingEncoderScript.new()
var device_sn := ""
var app_version := ""

var _sending := false
var _send_elapsed := 0.0
var _heartbeat_elapsed := 0.0
var _handshake_complete := false
var _protocol_ready := false
var _live_neutral_required := true
var _last_top_timestamp_ns := 0
var _sampler_configured := false
var _app_focused := true


func configure(
	tracking_provider: Node,
	xrt_client: Node,
	sampler_override: RefCounted = null,
	options: Dictionary = {}
) -> void:
	_unbind_client()
	client = xrt_client
	sampler = sampler_override if sampler_override != null else XrTrackingSamplerScript.new()
	sampler.set("tracking_provider", tracking_provider)
	_sampler_configured = false
	set_identity(options)
	_bind_client()


func set_identity(options: Dictionary) -> void:
	var requested_sn: Variant = options.get("device_sn", device_sn)
	device_sn = _resolve_identity_field(requested_sn, _default_device_sn(), "operator-xr")
	var requested_version: Variant = options.get("app_version", app_version)
	app_version = _resolve_identity_field(
		requested_version, _default_app_version(), "Operator")


func set_sending(enabled: bool) -> void:
	if _sending == enabled:
		return
	if not enabled and _sending and _protocol_ready and _client_connected():
		_send_neutral()
	_sending = enabled
	_send_elapsed = 0.0
	if sampler != null:
		if enabled:
			_configure_sampler()
		sampler.call("reset")
	if enabled:
		if _protocol_ready and _client_connected() and _live_neutral_required:
			if _send_neutral() == OK:
				_live_neutral_required = false
	else:
		_live_neutral_required = true


func is_sending() -> bool:
	return _sending


## Mirrors the Android APPLICATION_PAUSED/APPLICATION_RESUMED lifecycle onto the
## wire. Losing focus while sending immediately emits one neutral frame so a
## paused headset never leaves a live grasp pose as the last thing a receiver
## saw. Idempotent: repeating the same value sends nothing further.
func set_app_focused(focused: bool) -> void:
	if _app_focused == focused:
		return
	_app_focused = focused
	if focused:
		return
	if _sending and _protocol_ready and _client_connected():
		_send_neutral()


func is_app_focused() -> bool:
	return _app_focused


func reset() -> void:
	_send_elapsed = 0.0
	_heartbeat_elapsed = 0.0
	_handshake_complete = false
	_protocol_ready = false
	_live_neutral_required = true
	_last_top_timestamp_ns = 0
	if sampler != null:
		sampler.call("reset")


func is_protocol_ready() -> bool:
	return _protocol_ready


func _process(delta: float) -> void:
	if not _client_connected() or not _handshake_complete:
		return
	if not _protocol_ready:
		_complete_protocol_setup()
		return
	_heartbeat_elapsed += delta
	if _heartbeat_elapsed >= HEARTBEAT_INTERVAL_SEC:
		_heartbeat_elapsed = fmod(_heartbeat_elapsed, HEARTBEAT_INTERVAL_SEC)
		_send_packet(XrtProtocolScript.pack_text(XrtProtocolScript.CMD_HEARTBEAT, device_sn))
	if not _sending or sampler == null:
		return
	if _live_neutral_required:
		if _send_neutral() == OK:
			_live_neutral_required = false
		return
	_send_elapsed += delta
	var interval := 1.0 / float(TRACKING_RATE_HZ)
	if _send_elapsed < interval:
		return
	_send_elapsed = fmod(_send_elapsed, interval)
	var snapshot: Variant = sampler.call("sample_frame")
	if not (snapshot is Dictionary) or snapshot.is_empty():
		return
	_send_tracking(_encode_snapshot(snapshot as Dictionary))


func _on_client_connected() -> void:
	reset()
	var connect_error := _send_packet(
		XrtProtocolScript.pack_text(XrtProtocolScript.CMD_CONNECT, "%s|-1" % device_sn)
	)
	if connect_error != OK:
		return
	var version_error := _send_packet(
		XrtProtocolScript.pack_text(
			XrtProtocolScript.CMD_VERSION,
			"%s|1.0|%s" % [device_sn, app_version]
		)
	)
	if version_error != OK:
		return
	_handshake_complete = true
	handshake_sent.emit()
	_complete_protocol_setup()


func _on_client_disconnected(_reason := "") -> void:
	reset()


func _on_client_failed(_reason := "") -> void:
	reset()


func _complete_protocol_setup() -> void:
	if _protocol_ready or not _handshake_complete or not _client_connected():
		return
	if _send_neutral() != OK:
		return
	_protocol_ready = true
	_live_neutral_required = false
	protocol_ready.emit()


## The stop frame. It carries explicit neutral Hand and Body sections, not empty
## ones: a receiver that holds last-known state would otherwise keep driving the
## fingers from the last live grasp pose.
func _send_neutral() -> Error:
	var timestamp_ns := _next_top_timestamp_ns()
	var predicted_display_time_ns := _monotonic_time_ns()
	return _send_tracking(
		encoder.neutral(timestamp_ns, predicted_display_time_ns, _app_focused)
	)


func _encode_snapshot(snapshot: Dictionary) -> Dictionary:
	var frame := snapshot.duplicate(true)
	var frame_monotonic_ns := int(frame.get("timestamp_ns", 0))
	if frame_monotonic_ns <= 0:
		frame_monotonic_ns = _monotonic_time_ns()
	var predicted_display_time_ns := int(
		frame.get("predicted_display_time_ns", frame_monotonic_ns))
	if predicted_display_time_ns <= 0:
		predicted_display_time_ns = frame_monotonic_ns
	var timestamp_ns := _next_top_timestamp_ns()
	frame["predicted_display_time_ns"] = predicted_display_time_ns
	frame["timestamp_ns"] = timestamp_ns
	frame["focus"] = _app_focused
	# Motion is deliberately excluded because requesting it on Pico disables the
	# full-body mode used by HoloMotion's primary compatibility path.
	frame["motion_trackers"] = []

	var legacy_body_timestamp_ns := 0
	var body_value: Variant = frame.get("body", null)
	if body_value is Dictionary:
		var body := (body_value as Dictionary).duplicate(true)
		var body_monotonic_ns := int(body.get("sample_timestamp_ns", frame_monotonic_ns))
		legacy_body_timestamp_ns = maxi(
			1,
			body_monotonic_ns + (timestamp_ns - frame_monotonic_ns),
		)
		body["legacy_timestamp_ns"] = legacy_body_timestamp_ns
		frame["body"] = body
	return encoder.encode(frame, true)


func _send_tracking(tracking: Dictionary) -> Error:
	var envelope := XrtProtocolScript.encode_tracking_envelope(tracking)
	var packet := XrtProtocolScript.pack(XrtProtocolScript.CMD_TRACKING, envelope)
	var error := _send_packet(packet)
	if error == OK:
		frame_sent.emit(int(tracking.get("timeStampNs", 0)))
	return error


func _send_packet(packet: PackedByteArray) -> Error:
	if client == null or not client.has_method("send_packet"):
		return ERR_UNCONFIGURED
	var error := int(client.call("send_packet", packet))
	if error != OK:
		send_failed.emit("XRoboToolkit send failed: error %d" % error)
	return error


func _client_connected() -> bool:
	return (
		client != null
		and client.has_method("is_connected_to_server")
		and bool(client.call("is_connected_to_server"))
	)


func _bind_client() -> void:
	if client == null:
		return
	if client.has_signal("connected"):
		client.connect("connected", Callable(self, "_on_client_connected"))
	if client.has_signal("disconnected"):
		client.connect("disconnected", Callable(self, "_on_client_disconnected"))
	if client.has_signal("failed"):
		client.connect("failed", Callable(self, "_on_client_failed"))


func _configure_sampler() -> void:
	if sampler == null or _sampler_configured:
		return
	sampler.call("configure", {
		"rate_hz": TRACKING_RATE_HZ,
		"body_rate_hz": BODY_RATE_HZ,
		"strict_pico_body_validation": true,
		"include_predicted_display_time": true,
		# Requesting Pico motion trackers switches the runtime to object-tracking
		# mode and invalidates full-body tracking. Legacy compatibility prioritizes
		# Body, so Motion remains intentionally disabled on this path.
		"streams": ["head", "controllers", "hands", "body"],
	})
	_sampler_configured = true


func shutdown() -> void:
	set_sending(false)
	if sampler != null and sampler.has_method("shutdown"):
		sampler.call("shutdown")
	_sampler_configured = false
	reset()


func _unbind_client() -> void:
	if client == null:
		return
	for signal_name in ["connected", "disconnected", "failed"]:
		var callback := Callable(self, "_on_client_%s" % signal_name)
		if client.has_signal(signal_name) and client.is_connected(signal_name, callback):
			client.disconnect(signal_name, callback)


func _default_device_sn() -> String:
	var unique_id := OS.get_unique_id().strip_edges()
	return unique_id if not unique_id.is_empty() else "operator-xr"


func _default_app_version() -> String:
	var configured := str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	return configured if not configured.is_empty() else "Operator"


func _resolve_identity_field(value: Variant, default_value: String, hard_fallback: String) -> String:
	var resolved := str(value).strip_edges()
	if resolved.is_empty() or resolved.contains("|"):
		resolved = default_value.strip_edges()
	if resolved.is_empty() or resolved.contains("|"):
		return hard_fallback
	return resolved


func _unix_time_ns() -> int:
	return int(Time.get_unix_time_from_system() * 1000000000.0)


func _monotonic_time_ns() -> int:
	return Time.get_ticks_usec() * 1000


func _next_top_timestamp_ns() -> int:
	var timestamp_ns := _unix_time_ns()
	if timestamp_ns <= _last_top_timestamp_ns:
		# Nudge only clock-granularity regressions. A real backward step (NTP)
		# re-baselines onto the new wall clock; bumping by 1 ns per frame would
		# otherwise wedge the stream at 1 ns/frame for the rest of the session.
		if _last_top_timestamp_ns - timestamp_ns <= MAX_BACKWARD_CLOCK_STEP_NS:
			timestamp_ns = _last_top_timestamp_ns + 1
	_last_top_timestamp_ns = timestamp_ns
	return timestamp_ns
