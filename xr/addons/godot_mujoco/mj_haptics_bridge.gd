class_name MjHapticsBridge
extends Node

@export var simulation_path: NodePath
@export var controller_path: NodePath
@export var min_force := 0.05
@export var pulse_duration := 0.03
@export var pulse_interval := 0.15

var _simulation: MjSimulation
var _controller: XRController3D
var _last_pulse_usec := 0


func _process(_delta: float) -> void:
	_resolve_nodes()
	if _simulation == null or _controller == null:
		return
	var observation := _simulation.get_observation()
	var force := observation.get("force", {})
	var intensity := _force_intensity(force)
	if intensity < min_force:
		return
	var now := Time.get_ticks_usec()
	if float(now - _last_pulse_usec) / 1000000.0 < pulse_interval:
		return
	_last_pulse_usec = now
	if _controller.has_method("trigger_haptic_pulse"):
		_controller.trigger_haptic_pulse("haptic", 0.0, pulse_duration, clampf(intensity, 0.0, 1.0), 0.0)


func _force_intensity(force) -> float:
	if force is Dictionary:
		if force.has("gripper"):
			return absf(float(force["gripper"]))
		if force.has("actuator_force"):
			var values = force["actuator_force"]
			var max_value := 0.0
			for value in values:
				max_value = maxf(max_value, absf(float(value)))
			return max_value
	return 0.0


func _resolve_nodes() -> void:
	if _simulation == null and not simulation_path.is_empty():
		_simulation = get_node_or_null(simulation_path) as MjSimulation
	if _controller == null and not controller_path.is_empty():
		_controller = get_node_or_null(controller_path) as XRController3D
