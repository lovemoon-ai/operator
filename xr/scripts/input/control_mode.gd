class_name ControlMode
extends RefCounted
## Core abstraction that maps VR inputs to DeviceCommand based on DeviceDescriptor.
## Reads a descriptor's input_mapping array and transforms VR source values
## (joystick axes, triggers, buttons, poses) into the target command format.

var _descriptor: Dictionary = {}
var _mappings: Array = []
var _dead_zones: Dictionary = {}  # axis_name -> dead_zone
var _button_targets: Dictionary = {}  # button_name -> button definition
var _toggle_states: Dictionary = {}  # button_name -> bool (for toggle buttons)
var _enable_hold_until_msec: int = 0

const ENABLE_RELEASE_GRACE_MSEC := 100


func configure(descriptor: Dictionary) -> void:
	_descriptor = descriptor
	_mappings = descriptor.get("input_mapping", [])
	_dead_zones.clear()
	_button_targets.clear()
	# Build dead zone lookup from control_schema.axes
	var schema = descriptor.get("control_schema", {})
	for axis_def in schema.get("axes", []):
		_dead_zones[axis_def["name"]] = axis_def.get("dead_zone", 0.0)
	for button_def in schema.get("buttons", []):
		_button_targets[button_def["name"]] = button_def


func collect_command(tracking: TrackingProvider) -> Dictionary:
	var cmd = {"axes": {}, "buttons": {}, "poses": {}, "timestamp_ns": Time.get_ticks_usec() * 1000}
	for mapping in _mappings:
		var source: String = mapping["source"]
		var target: String = mapping["target"]
		var scale: float = mapping.get("scale", 1.0)
		var invert: bool = mapping.get("invert", false)
		var offset: float = mapping.get("offset", 0.0)

		var value = _read_vr_source(source, tracking)
		if value == null:
			continue

		if target == "enable":
			var enable_pressed := _source_value_to_button(value, scale, invert, offset)
			if enable_pressed:
				_enable_hold_until_msec = Time.get_ticks_msec() + ENABLE_RELEASE_GRACE_MSEC
			else:
				enable_pressed = Time.get_ticks_msec() <= _enable_hold_until_msec
			cmd["buttons"][target] = bool(cmd["buttons"].get(target, false)) or enable_pressed
			continue

		if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			var fval: float = float(value)
			if invert: fval = -fval
			fval = fval * scale + offset
			if _button_targets.has(target):
				cmd["buttons"][target] = fval >= 0.5
			else:
				# Apply dead zone
				var dz = _dead_zones.get(target, 0.0)
				if absf(fval) < dz: fval = 0.0
				cmd["axes"][target] = fval
		elif typeof(value) == TYPE_BOOL:
			cmd["buttons"][target] = value
		elif value is Dictionary and value.has("position"):
			cmd["poses"][target] = {
				"position": [value["position"].x, value["position"].y, value["position"].z],
				"rotation": [value["rotation"].x, value["rotation"].y, value["rotation"].z, value["rotation"].w]
			}
	return cmd


func _read_vr_source(source: String, tracking: TrackingProvider) -> Variant:
	# Map all possible VR input sources
	match source:
		"left_joystick_x": return _get_input(tracking, 0, "joystick").x
		"left_joystick_y": return _get_input(tracking, 0, "joystick").y
		"right_joystick_x": return _get_input(tracking, 1, "joystick").x
		"right_joystick_y": return _get_input(tracking, 1, "joystick").y
		"left_trigger": return _get_input_float(tracking, 0, "trigger")
		"right_trigger": return _get_input_float(tracking, 1, "trigger")
		"left_grip": return _get_grip_value(tracking, 0)
		"right_grip": return _get_grip_value(tracking, 1)
		"button_a": return _get_input_bool(tracking, 1, "ax_button")
		"button_b": return _get_input_bool(tracking, 1, "by_button")
		"button_x": return _get_input_bool(tracking, 0, "ax_button")
		"button_y": return _get_input_bool(tracking, 0, "by_button")
		"right_controller_pose": return tracking.get_controller_pose(1)
		"left_controller_pose": return tracking.get_controller_pose(0)
		"head_pose": return tracking.get_head_pose()
		"right_hand_joints": return tracking.get_hand_joints(1)
		"left_hand_joints": return tracking.get_hand_joints(0)
	return null


func _source_value_to_button(value: Variant, scale: float, invert: bool, offset: float) -> bool:
	if typeof(value) == TYPE_BOOL:
		return bool(value)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		var numeric_value := float(value)
		if invert:
			numeric_value = -numeric_value
		numeric_value = numeric_value * scale + offset
		return numeric_value >= 0.5
	if value is Vector2:
		var vector_value: Vector2 = value
		var vector_magnitude := vector_value.length()
		if invert:
			vector_magnitude = -vector_magnitude
		vector_magnitude = vector_magnitude * scale + offset
		return vector_magnitude >= 0.5
	return false


# Helper methods to safely extract input values
func _get_input(tracking: TrackingProvider, hand: int, key: String) -> Vector2:
	var input = tracking.get_controller_input(hand)
	if input.is_empty(): return Vector2.ZERO
	var val = input.get(key, Vector2.ZERO)
	if val is Vector2: return val
	return Vector2.ZERO


func _get_input_float(tracking: TrackingProvider, hand: int, key: String) -> float:
	var input = tracking.get_controller_input(hand)
	if input.is_empty(): return 0.0
	return float(input.get(key, 0.0))


func _get_grip_value(tracking: TrackingProvider, hand: int) -> float:
	var input = tracking.get_controller_input(hand)
	if input.is_empty(): return 0.0
	return maxf(
		float(input.get("grip", 0.0)),
		maxf(float(input.get("grip_click", 0.0)), float(input.get("grip_force", 0.0)))
	)


func _get_input_bool(tracking: TrackingProvider, hand: int, key: String) -> bool:
	var input = tracking.get_controller_input(hand)
	if input.is_empty(): return false
	return float(input.get(key, 0.0)) > 0.5
