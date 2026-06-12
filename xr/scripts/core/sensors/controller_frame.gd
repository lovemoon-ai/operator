class_name ControllerFrame
extends RefCounted
## v2 core/sensors (WP4): controller pose + controller input-packet
## SensorFrame builders. Field names mirror the existing writer args exactly.

const COORDINATE_SPACE := "operator_xr_world"


## Controller grip pose. source = "left_controller" / "right_controller".
static func build_pose(
	source: String,
	timestamp_ns: int,
	transform: Transform3D,
	tracking_valid: bool
) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.CONTROLLER
	frame.timestamp_ns = timestamp_ns
	frame.coordinate_space = COORDINATE_SPACE
	frame.source_id = source
	frame.valid = tracking_valid
	frame.payload = {
		"transform": transform,
		"tracking_valid": tracking_valid,
	}
	return frame


## Controller input packet (snapshot or event). `state` is the sampler's
## input-state dictionary: available/pressed/touched masks, trigger_value,
## grip_value, thumbstick: Vector2, trackpad: Vector2.
static func build_input(
	source: String,
	timestamp_ns: int,
	packet_type: int,
	state: Dictionary,
	changed_mask: int
) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.INPUT_EVENT
	frame.timestamp_ns = timestamp_ns
	frame.source_id = source
	frame.payload = {
		"packet_type": packet_type,
		"available_mask": int(state.get("available_mask", 0)),
		"pressed_mask": int(state.get("pressed_mask", 0)),
		"touched_mask": int(state.get("touched_mask", 0)),
		"changed_mask": changed_mask,
		"trigger_value": float(state.get("trigger_value", 0.0)),
		"grip_value": float(state.get("grip_value", 0.0)),
		"thumbstick": state.get("thumbstick", Vector2.ZERO) as Vector2,
		"trackpad": state.get("trackpad", Vector2.ZERO) as Vector2,
	}
	return frame
