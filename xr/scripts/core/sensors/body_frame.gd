class_name BodyFrame
extends RefCounted
## v2 core/sensors (WP4): body-tracking SensorFrame builder.
## Payload shape: {body_flags: int, joints: Array, runtime: String,
## metadata: Dictionary}. metadata is the optional per-frame extras dict the
## spool writer merges into the body JSONL record (e.g. the full PICO sample
## with velocity/acceleration), passed through unchanged.

const COORDINATE_SPACE := "operator_xr_world"


static func build(
	timestamp_ns: int,
	body_flags: int,
	joints: Array,
	runtime: String = "",
	metadata: Dictionary = {}
) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.BODY
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = COORDINATE_SPACE
	frame.source_id = "body"
	frame.payload = {
		"body_flags": body_flags,
		"joints": joints,
		"runtime": runtime,
		"metadata": metadata,
	}
	return frame
