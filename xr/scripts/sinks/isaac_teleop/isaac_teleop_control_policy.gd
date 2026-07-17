class_name IsaacTeleopControlPolicy
extends RefCounted
## Converts right-controller input into IsaacTeleop safety controls.
## Grip is a continuous deadman. A/X produces a run-toggle pulse, and B/Y
## produces a reset pulse. Pulses are rising-edge triggered.

const DEFAULT_PRESS_THRESHOLD := 0.5

var _require_deadman := true
var _press_threshold := DEFAULT_PRESS_THRESHOLD
var _primary_was_pressed := false
var _secondary_was_pressed := false


func configure(
	require_deadman: bool = true,
	press_threshold: float = DEFAULT_PRESS_THRESHOLD
) -> void:
	_require_deadman = require_deadman
	_press_threshold = clampf(press_threshold, 0.0, 1.0)
	reset_edges()


func sample(input: Dictionary) -> Dictionary:
	var grip_pressed := _pressed(input, ["grip_click", "grip", "grip_force"])
	var primary_pressed := _pressed(input, ["ax_button", "a_button", "primary_button"])
	var secondary_pressed := _pressed(input, ["by_button", "b_button", "secondary_button"])
	var result := {
		"kill": false,
		"run_toggle": primary_pressed and not _primary_was_pressed,
		"reset": secondary_pressed and not _secondary_was_pressed,
		"deadman": grip_pressed if _require_deadman else true,
	}
	_primary_was_pressed = primary_pressed
	_secondary_was_pressed = secondary_pressed
	return result


func kill_sample() -> Dictionary:
	return {
		"kill": true,
		"run_toggle": false,
		"reset": false,
		"deadman": false,
	}


func reset_edges() -> void:
	_primary_was_pressed = false
	_secondary_was_pressed = false


func _pressed(input: Dictionary, keys: Array[String]) -> bool:
	for key in keys:
		var value_v: Variant = input.get(key, 0.0)
		if value_v is bool and bool(value_v):
			return true
		if (value_v is int or value_v is float) \
				and is_finite(float(value_v)) and float(value_v) >= _press_threshold:
			return true
	return false
