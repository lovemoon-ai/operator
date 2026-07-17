class_name FrameWriterShim
extends RefCounted

const SensorFrameTypeScript := preload("res://scripts/contracts/sensor/frame_types.gd")

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


## Routes one SensorFrame to the matching writer call. Returns the writer's
## return value (Variant: bool for input writes, null for the void
## pose/depth writes on the spool writer).
func on_frame(frame: Object) -> Variant:
	if _writer == null or frame == null:
		return null
	var payload: Variant = frame.payload
	var p: Dictionary = payload if payload is Dictionary else {}
	match frame.frame_type:
		SensorFrameTypeScript.POSE:
			return _writer.write_head_pose(
				frame.timestamp_ns,
				p.get("transform", Transform3D.IDENTITY) as Transform3D,
				bool(p.get("tracking_valid", false))
			)
		SensorFrameTypeScript.CONTROLLER:
			return _writer.write_controller_pose(
				frame.source_id,
				frame.timestamp_ns,
				p.get("transform", Transform3D.IDENTITY) as Transform3D,
				bool(p.get("tracking_valid", false))
			)
		SensorFrameTypeScript.INPUT_EVENT:
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
		SensorFrameTypeScript.DEPTH:
			return _writer.write_depth_frame(
				frame.timestamp_ns,
				str(p.get("eye", frame.source_id)),
				str(p.get("image_path", "")),
				int(p.get("width", 0)),
				int(p.get("height", 0)),
				p.get("metadata", {}) as Dictionary,
				p.get("depth_u16_mm", PackedByteArray()) as PackedByteArray
			)
	push_warning("FrameWriterShim: unsupported frame type %d" % frame.frame_type)
	return null
