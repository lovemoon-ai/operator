class_name HandFrame
extends RefCounted
## v2 core/sensors (WP4): hand-tracking SensorFrame builder.
## Payload shape: {hand: "left"|"right", joints: Array of
## {joint, flags, radius_m, position, rotation}} — identical to the records
## the spool writer packs into the HJNT mp4 payload and the hands JSONL.

const COORDINATE_SPACE := "operator_xr_world"


static func build(hand: String, timestamp_ns: int, joints: Array) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.HAND
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = COORDINATE_SPACE
	frame.source_id = hand
	frame.payload = {
		"hand": hand,
		"joints": joints,
	}
	return frame
