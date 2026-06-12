class_name FrameWriterShim
extends RefCounted
## v2 core/capture (WP4): adapter that consumes canonical SensorFrames and
## calls the existing writer surface (SessionSpoolWriter / LivePushWriter /
## LiveFeedNetworkWriter) with byte-identical arguments. This keeps WP4
## behavior-compatible: samplers emit SensorFrames; the on-disk/on-wire
## formats are unchanged because the writer methods receive exactly the same
## args as before.
##
## WP5 replaces this shim with direct sink fanout.

var _writer: Object


func _init(writer: Object) -> void:
	_writer = writer


func writer() -> Object:
	return _writer


## Mirrors the legacy `writer.has_method("write_motion_tracker_event")` guard
## in body_motion_sampler (LivePushWriter has no motion-tracker surface).
func supports_motion_tracker_events() -> bool:
	return _writer != null and _writer.has_method("write_motion_tracker_event")


## Routes one SensorFrame to the matching writer call. Returns the writer's
## return value (Variant: bool for input/body/motion writes, null for the
## void pose/hand/depth writes on the spool writer).
func on_frame(frame: SensorFrame) -> Variant:
	if _writer == null or frame == null:
		return null
	var p := frame.payload
	match frame.frame_type:
		SensorFrameType.POSE:
			return _writer.write_head_pose(
				frame.timestamp_ns,
				p.get("transform", Transform3D.IDENTITY) as Transform3D,
				bool(p.get("tracking_valid", false)),
				bool(p.get("write_jsonl", true))
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
		SensorFrameType.BODY:
			return _writer.write_body_joints(
				frame.timestamp_ns,
				int(p.get("body_flags", 0)),
				p.get("joints", []) as Array,
				p.get("metadata", {}) as Dictionary
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
		SensorFrameType.MOTION_TRACKER:
			# WP5: motion-tracker writes moved off SessionSpoolWriter into
			# JsonlSidecarSink; guard both variants so this legacy fallback
			# stays safe against writers without that surface.
			if MotionTrackerFrame.is_event(frame):
				if not supports_motion_tracker_events():
					return false
				return _writer.write_motion_tracker_event(
					frame.timestamp_ns,
					str(p.get("event_type", "")),
					p.get("event", {}) as Dictionary
				)
			if not _writer.has_method("write_motion_tracker_pose"):
				return false
			return _writer.write_motion_tracker_pose(
				int(p.get("tracker_index", 0)),
				frame.source_id,
				frame.timestamp_ns,
				p.get("transform", Transform3D.IDENTITY) as Transform3D,
				bool(p.get("tracking_valid", false)),
				p.get("metadata", {}) as Dictionary
			)
	push_warning("FrameWriterShim: unsupported frame type %d" % frame.frame_type)
	return null
