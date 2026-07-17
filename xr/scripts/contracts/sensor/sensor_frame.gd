class_name SensorFrame
extends RefCounted
## v2 contracts (WP4): canonical sensor frame passed from samplers/sources to
## sinks. Pure data + validation; no engine singletons, no vendor knowledge.
##
## timestamp_ns is always in the Godot-ticks-ns monotonic domain
## (clock_monotonic_ns) — the same PTS domain as the mp4 media tracks.

## One of SensorFrameType.* ids.
var frame_type := -1
## Monotonic Godot ticks ns (clock_monotonic_ns domain).
var timestamp_ns := 0
## Raw OpenXR XrTime ns when the sample came from the XR runtime, else 0.
var xr_timestamp_ns := 0
## Device/sensor hardware timestamp ns when available, else 0.
var device_timestamp_ns := 0
## Coordinate space the spatial payload is expressed in (for example,
## "openxr_stage"). Required for pose-like frames.
var coordinate_space := ""
## Stable source identifier (e.g. "head", "left_controller", tracker name).
var source_id := ""
## SensorCapability.* id of the producing capability, -1 if unknown.
var capability_id := -1
## Per-source monotonically increasing sequence number (0 if unused).
var sequence := 0
## Whether the sample carries valid tracking data.
var valid := true
## Frame-type-specific payload. Shapes are defined by the builders under
## core/sensors/ and consumed by sinks/FrameWriterShim.
var payload: Dictionary = {}

const _POSE_LIKE_TYPES := [
	SensorFrameType.POSE,
	SensorFrameType.CONTROLLER,
	SensorFrameType.HAND,
	SensorFrameType.BODY,
	SensorFrameType.MOTION_TRACKER,
]


func validate() -> Array[String]:
	var errors: Array[String] = []
	if SensorFrameType.id_to_string(frame_type).is_empty():
		errors.append("frame_type %d is not a known SensorFrameType" % frame_type)
	if timestamp_ns <= 0:
		errors.append("timestamp_ns must be > 0 (got %d)" % timestamp_ns)
	if frame_type in _POSE_LIKE_TYPES and coordinate_space.is_empty():
		errors.append(
			"coordinate_space must be non-empty for pose-like frame type %s"
			% SensorFrameType.id_to_string(frame_type))
	return errors


func type_name() -> String:
	return SensorFrameType.id_to_string(frame_type)
