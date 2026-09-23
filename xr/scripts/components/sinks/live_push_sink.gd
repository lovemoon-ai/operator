class_name LivePushSink
extends SensorSink
## Capability layer (components/sinks): publishes canonical SensorFrames as
## OLCP `media_up` frames. It wraps the frozen LivePushWriter engine
## (addons/live-push), whose Android plugin also receives Kotlin-direct RGB
## through the SpatialDataSink contract.
##
## The destination is injected by the session that mounts the sink and is
## never chosen by the sink itself: an ingest session supplies its locally
## configured endpoint, a host session supplies its connected peer plus the
## session-owned `media` block its bridge injected. Timestamps pass through
## unchanged (claw/architecture/wire-protocol.md, "Headset timebase").

signal push_failed(message: String)
signal push_connected(endpoint: String)
signal push_disconnected(endpoint: String)

const LivePushWriterScript := preload("res://addons/live-push/live_push_writer.gd")

var _writer: Object
var _plugin: Object
var _target_host := ""
var _target_port := 0
var _target_token := ""


func _init(writer_obj: Object = null) -> void:
	_writer = writer_obj if writer_obj != null else LivePushWriterScript.new()


## The wrapped writer (session paths, pop_metrics, ... stay reachable for the
## composition root).
func writer() -> Object:
	return _writer


## Session-injected destination. The session options passed to start() cannot
## override it.
func set_target(host: String, port: int, auth_token: String) -> void:
	_target_host = host.strip_edges()
	_target_port = port
	_target_token = auth_token
	if _writer != null and has_target():
		_writer.configure_server(_target_host, _target_port, _target_token)


func clear_target() -> void:
	_target_host = ""
	_target_port = 0
	_target_token = ""


func has_target() -> bool:
	return not _target_host.is_empty() and _target_port > 0 and _target_port <= 65535


func target_host() -> String:
	return _target_host


## Binds the platform's live push plugin (Kotlin SpatialDataSink). Idempotent.
func bind_plugin(plugin: Object) -> void:
	if plugin == null or plugin == _plugin:
		return
	_plugin = plugin
	if _writer != null and _writer.has_method("set_live_server_plugin"):
		_writer.set_live_server_plugin(plugin)
	_connect_plugin_signal(["live_feed_error", "live_capture_error"], _on_plugin_error)
	_connect_plugin_signal(["live_feed_connected", "live_capture_connected"], _on_plugin_connected)
	_connect_plugin_signal(["live_feed_disconnected", "live_capture_disconnected"], _on_plugin_disconnected)
	print("LivePushPlugin singleton bound")


func plugin() -> Object:
	return _plugin


## When true, the plugin fans the camera provider's Kotlin-direct RGB/depth out
## to the local recorder AND this push sink instead of replacing the recorder.
## Used when one capture feeds both a local recording and an ingest endpoint.
func set_recorder_tee(enabled: bool) -> void:
	if _plugin != null:
		_plugin.call("setRecorderTee", enabled)


## The live push surface has no body / motion-tracker streams. Hands are pushed
## directly by the hand_capture GDExtension (writeHandJointsJson on the live
## plugin), bypassing the GDScript frame fanout entirely.
func accepted_frame_types() -> Array:
	return [
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.INPUT_EVENT,
		SensorFrameType.DEPTH,
	]


func start(options: Dictionary) -> bool:
	if _writer == null:
		return false
	return bool(_writer.start_session(session_options(options)))


## Options with the injected destination applied over any caller-supplied
## server keys.
func session_options(options: Dictionary) -> Dictionary:
	var merged := options.duplicate(true)
	if has_target():
		merged["server_host"] = _target_host
		merged["server_port"] = _target_port
		merged["server_auth_token"] = _target_token
	return merged


func stop() -> Dictionary:
	if _writer != null:
		_writer.close()
	return {"final_path": ""}


func policy() -> Dictionary:
	return {
		"ordering": "in_order",
		"durability": "none",
		"drop_policy": "queue_bounded",
	}


func health() -> Dictionary:
	return {
		"writer_bound": _writer != null,
		"plugin_bound": _plugin != null,
		"target": "%s:%d" % [_target_host, _target_port] if has_target() else "",
	}


func on_frame(frame: SensorFrame) -> Variant:
	if _writer == null or frame == null:
		return null
	var p := frame.payload
	match frame.frame_type:
		SensorFrameType.POSE:
			return _writer.write_head_pose(
				frame.timestamp_ns,
				p.get("transform", Transform3D.IDENTITY) as Transform3D,
				bool(p.get("tracking_valid", false))
			)
		SensorFrameType.CONTROLLER:
			return _writer.write_controller_pose(
				frame.source_id,
				frame.timestamp_ns,
				p.get("transform", Transform3D.IDENTITY) as Transform3D,
				bool(p.get("tracking_valid", false))
			)
		SensorFrameType.INPUT_EVENT:
			return _writer.write_controller_input(
				frame.source_id,
				frame.timestamp_ns,
				int(p.get("packet_type", 0)),
				int(p.get("available_mask", 0)),
				int(p.get("pressed_mask", 0)),
				int(p.get("touched_mask", 0)),
				int(p.get("changed_mask", 0)),
				float(p.get("trigger_value", 0.0)),
				float(p.get("grip_value", 0.0)),
				p.get("thumbstick", Vector2.ZERO) as Vector2,
				p.get("trackpad", Vector2.ZERO) as Vector2
			)
		SensorFrameType.DEPTH:
			return _writer.write_depth_frame(
				frame.timestamp_ns,
				str(p.get("eye", frame.source_id)),
				str(p.get("image_path", "")),
				int(p.get("width", 0)),
				int(p.get("height", 0)),
				p.get("metadata", {}) as Dictionary,
				p.get("depth_u16_mm", PackedByteArray()) as PackedByteArray
			)
	return null


func _connect_plugin_signal(names: Array, callback: Callable) -> void:
	for name_v in names:
		var signal_name := StringName(str(name_v))
		if _plugin.has_signal(signal_name):
			if not _plugin.is_connected(signal_name, callback):
				_plugin.connect(signal_name, callback)
			return


func _on_plugin_error(message: String) -> void:
	push_failed.emit(message)


func _on_plugin_connected(endpoint: String) -> void:
	print("Live feed push connected: %s" % endpoint)
	push_connected.emit(endpoint)


func _on_plugin_disconnected(endpoint: String) -> void:
	print("Live feed push disconnected: %s" % endpoint)
	push_disconnected.emit(endpoint)
