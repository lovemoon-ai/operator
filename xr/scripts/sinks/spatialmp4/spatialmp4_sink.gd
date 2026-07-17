class_name SpatialMp4Sink
extends SensorSink
## v2 sinks/spatialmp4 (WP5): writes camera/audio/depth/pose/body data into
## the spatial MP4 via the native muxer contract. The existing
## SessionSpoolWriter remains the engine (session dirs, manifest write +
## finalize-rewrite, sha256, muxer calls) so the on-disk format is
## byte-compatible per SpatialMp4ManifestContract; this sink owns the
## SensorFrame -> muxer dispatch.

const SessionSpoolWriterScript := preload("res://scripts/core/capture/session_spool_writer.gd")

var _writer: Object


func _init(writer_obj: Object = null) -> void:
	_writer = writer_obj if writer_obj != null else SessionSpoolWriterScript.new()


## The wrapped SessionSpoolWriter. Exposed so composition code can keep
## using writer-specific accessors (get_session_dir_absolute, pop_metrics,
## set_android_plugin / set_muxer_plugin, session timestamps, ...).
func writer() -> Object:
	return _writer


## Hands, body joints and motion trackers are written directly to the muxer
## by the hand_capture GDExtension (writeHandJointsPayload /
## writeBodyJointsPayload / writeMotionTrackerMetadataJson), bypassing the
## GDScript frame fanout entirely.
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
	return bool(_writer.start_session(options))


func stop() -> Dictionary:
	if _writer == null:
		return {"final_path": ""}
	_writer.close()
	var final_path := ""
	if _writer.has_method("get_saved_path"):
		final_path = str(_writer.get_saved_path())
	if final_path.is_empty():
		final_path = str(_writer.get_session_dir())
	return {"final_path": final_path}


func set_body_tracking_runtime_info(info: Dictionary) -> void:
	if _writer != null and _writer.has_method("set_body_tracking_runtime_info"):
		_writer.set_body_tracking_runtime_info(info)


func policy() -> Dictionary:
	return {
		"ordering": "in_order",
		"durability": "local_file",
		"drop_policy": "never",
	}


func health() -> Dictionary:
	return {
		"writer_bound": _writer != null,
		"session_dir": str(_writer.get_session_dir()) if _writer != null else "",
	}


## Routes one SensorFrame to the matching writer call with byte-identical
## arguments (mirrors the pre-WP5 FrameWriterShim mp4 paths).
func on_frame(frame: SensorFrame) -> Variant:
	if _writer == null or frame == null:
		return null
	var payload: Variant = frame.payload
	var p: Dictionary = payload if payload is Dictionary else {}
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
	push_warning("SpatialMp4Sink: unsupported frame type %d" % frame.frame_type)
	return null
