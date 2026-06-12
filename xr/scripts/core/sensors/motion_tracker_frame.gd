class_name MotionTrackerFrame
extends RefCounted
## v2 core/sensors (WP4): motion-tracker SensorFrame builders. Two variants
## matching the current JSONL records exactly:
## - pose: {tracker_index, transform, tracking_valid, metadata}
## - event: {event_type, event} (e.g. PICO power-key events)

const COORDINATE_SPACE := "operator_xr_world"
const KIND_POSE := "pose"
const KIND_EVENT := "event"


static func build_pose(
	tracker_index: int,
	source: String,
	timestamp_ns: int,
	transform: Transform3D,
	tracking_valid: bool,
	metadata: Dictionary = {}
) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.MOTION_TRACKER
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = COORDINATE_SPACE
	frame.source_id = source
	frame.valid = tracking_valid
	frame.payload = {
		"kind": KIND_POSE,
		"tracker_index": tracker_index,
		"transform": transform,
		"tracking_valid": tracking_valid,
		"metadata": metadata,
	}
	return frame


static func build_event(
	timestamp_ns: int,
	event_type: String,
	event: Dictionary
) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.MOTION_TRACKER
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = COORDINATE_SPACE
	frame.source_id = "motion_tracker_event"
	frame.payload = {
		"kind": KIND_EVENT,
		"event_type": event_type,
		"event": event,
	}
	return frame


static func is_event(frame: SensorFrame) -> bool:
	return str(frame.payload.get("kind", KIND_POSE)) == KIND_EVENT
