extends Node
class_name Viewport2DInteractionTarget

const TARGET_GROUP := "operator_interaction_target"
const NO_POINTER := Vector2(-1.0, -1.0)

@export var interaction_priority := 20

var _host: Node3D
var _body: Node3D
var _viewport: Viewport
var _pointer_position := NO_POINTER
var _pointer_pressed := false
var _last_hit_point := Vector3.ZERO
var _has_hit_point := false
var _feedback_input_mode := "controllers"
var _feedback_controller: XRController3D


func _ready() -> void:
	_host = get_parent() as Node3D
	if _host != null:
		_body = _host.get_node_or_null("StaticBody3D") as Node3D
		_viewport = _host.get_node_or_null("Viewport") as Viewport
	add_to_group(TARGET_GROUP)


func get_interaction_priority() -> int:
	return interaction_priority


func is_interaction_target_visible() -> bool:
	if _host == null:
		return false
	return _host.is_inside_tree() and _host.visible


func update_pointer_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	if _body == null or _viewport == null or not _body.has_method("global_to_viewport"):
		return false
	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		clear_pointer()
		return false
	var normal := _body.global_transform.basis.z.normalized()
	var denominator := normal.dot(direction)
	if absf(denominator) < 0.0001:
		clear_pointer()
		return false
	var distance_m := normal.dot(_body.global_transform.origin - ray_origin) / denominator
	if distance_m <= 0.0:
		clear_pointer()
		return false

	var hit_point := ray_origin + direction * distance_m
	var position: Vector2 = _body.call("global_to_viewport", hit_point)
	if position.x < 0.0 or position.y < 0.0 or position.x > _viewport.size.x or position.y > _viewport.size.y:
		clear_pointer()
		return false

	_last_hit_point = hit_point
	_has_hit_point = true
	_set_card_feedback()
	if position != _pointer_position:
		var motion := InputEventMouseMotion.new()
		motion.position = position
		motion.global_position = position
		_viewport.push_input(motion)
	_pointer_position = position
	return true


func set_pointer_pressed(pressed: bool) -> void:
	if pressed == _pointer_pressed:
		return
	if pressed and _pointer_position == NO_POINTER:
		return
	if _viewport == null:
		return
	_pointer_pressed = pressed
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = _pointer_position
	event.global_position = _pointer_position
	_viewport.push_input(event)


func set_feedback_input_mode(mode: String, controller: XRController3D = null) -> void:
	_feedback_input_mode = mode
	_feedback_controller = controller
	_set_card_feedback()


func clear_pointer() -> void:
	if _pointer_pressed:
		set_pointer_pressed(false)
	if _viewport != null and _pointer_position != NO_POINTER:
		var motion := InputEventMouseMotion.new()
		motion.position = Vector2(-1000.0, -1000.0)
		motion.global_position = motion.position
		_viewport.push_input(motion)
	_pointer_position = NO_POINTER
	_has_hit_point = false


func get_ray_hit_point(ray_origin: Vector3, ray_direction: Vector3) -> Vector3:
	if _has_hit_point:
		return _last_hit_point
	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		return ray_origin
	return ray_origin + direction * 0.25


func _set_card_feedback() -> void:
	var ui := _scene_instance()
	if ui != null and ui.has_method("set_feedback_input_mode"):
		ui.call("set_feedback_input_mode", _feedback_input_mode, _feedback_controller)


func _scene_instance() -> Node:
	if _host != null and _host.has_method("get_scene_instance"):
		var inst: Variant = _host.call("get_scene_instance")
		if inst is Node:
			return inst as Node
	return null
