class_name MjTeleopRig
extends Node

@export var simulation_path: NodePath
@export var left_controller_path: NodePath
@export var right_controller_path: NodePath
@export var enable_keyboard_fallback := true
@export var action_interval := 1.0 / 30.0

var last_action := {}
var _simulation: MjSimulation
var _left: XRController3D
var _right: XRController3D
var _accumulator := 0.0


func _ready() -> void:
	_resolve_nodes()


func _process(delta: float) -> void:
	_accumulator += delta
	if _accumulator < action_interval:
		return
	_accumulator = 0.0
	_resolve_nodes()
	last_action = collect_action()
	if _simulation:
		_simulation.apply_action(last_action)


func collect_action() -> Dictionary:
	var base_x := 0.0
	var base_yaw := 0.0
	var gripper := 0.0
	var actuators := {}
	if _left:
		base_x = _axis(_left, "primary")
		base_yaw = _axis(_left, "primary_x")
	if _right:
		gripper = _trigger(_right)
		actuators["vr_ee_x"] = _right.global_position.x
		actuators["vr_ee_y"] = _right.global_position.y
		actuators["vr_ee_z"] = _right.global_position.z
	if enable_keyboard_fallback:
		base_x += Input.get_axis("ui_down", "ui_up")
		base_yaw += Input.get_axis("ui_left", "ui_right")
		if Input.is_action_pressed("ui_accept"):
			gripper = 1.0
	return {
		"schema": "operator.mujoco.teleop.v1",
		"timestamp": Time.get_ticks_usec(),
		"base": {"x": clampf(base_x, -1.0, 1.0), "yaw": clampf(base_yaw, -1.0, 1.0)},
		"gripper": clampf(gripper, 0.0, 1.0),
		"actuators": actuators,
	}


func _resolve_nodes() -> void:
	if _simulation == null and not simulation_path.is_empty():
		_simulation = get_node_or_null(simulation_path) as MjSimulation
	if _left == null and not left_controller_path.is_empty():
		_left = get_node_or_null(left_controller_path) as XRController3D
	if _right == null and not right_controller_path.is_empty():
		_right = get_node_or_null(right_controller_path) as XRController3D


func _axis(controller: XRController3D, action_name: String) -> float:
	if controller.has_method("get_float"):
		return float(controller.get_float(action_name))
	return 0.0


func _trigger(controller: XRController3D) -> float:
	for action_name in ["trigger", "trigger_click", "grip"]:
		if controller.has_method("get_float"):
			var value := float(controller.get_float(action_name))
			if value > 0.01:
				return value
	return 0.0
