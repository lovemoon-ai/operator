class_name PoseFrame
extends RefCounted
## v2 core/sensors (WP4): head-pose SensorFrame builder/accessors.
## Payload shape: {transform: Transform3D, tracking_valid: bool,
## write_jsonl: bool} (write_jsonl carries the sampler's JSONL throttle
## decision through to the writer shim unchanged).

const DEFAULT_COORDINATE_SPACE := "openxr_play_space"


static func build(
	timestamp_ns: int,
	transform: Transform3D,
	tracking_valid: bool,
	write_jsonl: bool = true,
	coordinate_space: String = DEFAULT_COORDINATE_SPACE
) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.POSE
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = coordinate_space
	frame.source_id = "head"
	frame.valid = tracking_valid
	frame.payload = {
		"transform": transform,
		"tracking_valid": tracking_valid,
		"write_jsonl": write_jsonl,
	}
	return frame


static func transform_of(frame: SensorFrame) -> Transform3D:
	return frame.payload.get("transform", Transform3D.IDENTITY)


static func tracking_valid(frame: SensorFrame) -> bool:
	return bool(frame.payload.get("tracking_valid", false))


static func write_jsonl(frame: SensorFrame) -> bool:
	return bool(frame.payload.get("write_jsonl", true))
