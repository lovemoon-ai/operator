class_name LiveStreamSink
extends SensorSink
## v2 sinks/live_stream (WP5): publishes live frames to the local/remote
## live-feed server. Wraps the existing LivePushWriter /
## LiveFeedNetworkWriter unchanged — connection logs ("Live feed push
## connected:", live-pull markers) stay inside those scripts and the native
## plugin. The plugin object is injected by the composition root (platform
## LIVE_STREAM_SERVER provider); this sink never probes singletons.

const LivePushWriterScript := preload("res://addons/live-push/live_push_writer.gd")

var _writer: Object


func _init(writer_obj: Object = null) -> void:
	_writer = writer_obj if writer_obj != null else LivePushWriterScript.new()


## The wrapped live writer (configure_server, pop_metrics, ... stay
## reachable for the composition root).
func writer() -> Object:
	return _writer


## The live push surface has no body / motion-tracker streams (matches the
## legacy LivePushWriter method set).
func accepted_frame_types() -> Array:
	return [
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.INPUT_EVENT,
		SensorFrameType.HAND,
		SensorFrameType.DEPTH,
	]


func start(options: Dictionary) -> bool:
	if _writer == null:
		return false
	return bool(_writer.start_session(options))


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
	return {"writer_bound": _writer != null}


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
		SensorFrameType.HAND:
			return _writer.write_hand_joints(
				str(p.get("hand", frame.source_id)),
				frame.timestamp_ns,
				p.get("joints", []) as Array
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
