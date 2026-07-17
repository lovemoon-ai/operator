class_name PoseFrame
extends RefCounted

const SensorFrameScript := preload("res://scripts/contracts/sensor/sensor_frame.gd")
const SensorFrameTypeScript := preload("res://scripts/contracts/sensor/frame_types.gd")

## v2 core/sensors (WP4): head-pose SensorFrame builder/accessors.
## Payload shape: {transform: Transform3D, tracking_valid: bool}.

const DEFAULT_COORDINATE_SPACE := "openxr_play_space"


static func build(
	timestamp_ns: int,
	transform: Transform3D,
	tracking_valid: bool,
	coordinate_space: String = DEFAULT_COORDINATE_SPACE
) -> Object:
	var frame := SensorFrameScript.new()
	frame.frame_type = SensorFrameTypeScript.POSE
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = coordinate_space
	frame.source_id = "head"
	frame.valid = tracking_valid
	frame.payload = {
		"transform": transform,
		"tracking_valid": tracking_valid,
	}
	return frame


static func transform_of(frame: Object) -> Transform3D:
	return frame.payload.get("transform", Transform3D.IDENTITY)


static func tracking_valid(frame: Object) -> bool:
	return bool(frame.payload.get("tracking_valid", false))
