extends Node
class_name SettingsInteractionRouter

const LEFT_HAND_TRACKER := &"/user/hand_tracker/left"
const RIGHT_HAND_TRACKER := &"/user/hand_tracker/right"
const HAND_PINCH_DISTANCE_M := 0.028

var click_actions: PackedStringArray = PackedStringArray(["trigger_click", "primary_click", "select_button"])
var analog_trigger_action: StringName = &"trigger"
var trigger_press_threshold := 0.55
var trigger_release_threshold := 0.35
var interaction_mode := "controllers"
var busy := false

var origin: XROrigin3D
var hmd_camera: XRCamera3D
var left_pointer: XRController3D
var right_pointer: XRController3D
var ui_pointer_visual: Node

var _targets: Array[Object] = []
var _pressed_target: Object
var _controller_pointer_down: XRController3D
var _hand_pointer_down := false
var _trigger_down: Dictionary = {}


func configure(
		xr_origin: XROrigin3D,
		camera: XRCamera3D,
		left: XRController3D,
		right: XRController3D,
		pointer_visual: Node
) -> void:
	origin = xr_origin
	hmd_camera = camera
	left_pointer = left
	right_pointer = right
	ui_pointer_visual = pointer_visual
	_connect_controller(left_pointer)
	_connect_controller(right_pointer)


func set_targets(targets: Array) -> void:
	_targets.clear()
	for target in targets:
		if target is Object:
			_targets.append(target)


func update_pointer() -> void:
	_update_analog_trigger(left_pointer)
	_update_analog_trigger(right_pointer)

	var target := _active_target()
	if target == null:
		release_pointer()
		return

	if _should_use_controller_pointer(target):
		_update_controller_pointer(target)
	elif interaction_mode == "hands":
		_update_hand_pointer(target)
	else:
		release_pointer()


func release_pointer() -> void:
	_release_pressed_target()
	_controller_pointer_down = null
	_hand_pointer_down = false
	for target in _targets:
		if target and target.has_method("clear_pointer"):
			target.clear_pointer()
	_hide_ui_pointer_visual()


func _connect_controller(pointer: XRController3D) -> void:
	if pointer == null:
		return
	if not pointer.button_pressed.is_connected(_on_controller_button_pressed.bind(pointer)):
		pointer.button_pressed.connect(_on_controller_button_pressed.bind(pointer))
	if not pointer.button_released.is_connected(_on_controller_button_released.bind(pointer)):
		pointer.button_released.connect(_on_controller_button_released.bind(pointer))


func _active_target() -> Object:
	for target in _targets:
		if target == null:
			continue
		var visible_value: Variant = target.get("visible")
		if typeof(visible_value) != TYPE_NIL and bool(visible_value):
			return target
	return null


func _should_use_controller_pointer(target: Object) -> bool:
	if interaction_mode == "hands":
		return false
	if _targets.size() > 0 and target == _targets[0]:
		return true
	return interaction_mode == "controllers" or (interaction_mode == "head" and not busy)


func _update_controller_pointer(target: Object) -> void:
	if _hand_pointer_down:
		_release_pressed_target()
		_hand_pointer_down = false

	var pointer: XRController3D = _controller_pointer_down
	if pointer == null:
		if _has_tracking(right_pointer):
			pointer = right_pointer
		elif _has_tracking(left_pointer):
			pointer = left_pointer
	if pointer == null:
		target.clear_pointer()
		_hide_ui_pointer_visual()
		return

	var ray_origin := pointer.global_transform.origin
	var ray_direction := -pointer.global_transform.basis.z
	var feedback_mode := _feedback_mode_for_pointer(pointer)
	_set_target_feedback(target, feedback_mode, pointer if feedback_mode == "controllers" else null)
	if target.update_pointer_from_ray(ray_origin, ray_direction):
		_show_ui_pointer_visual(ray_origin, ray_direction, target, _controller_pointer_down != null)
	else:
		target.clear_pointer()
		_show_idle_ui_pointer_visual(ray_origin, ray_direction)


func _update_hand_pointer(target: Object) -> void:
	if _controller_pointer_down:
		_release_pressed_target()
		_controller_pointer_down = null

	var tracker := _tracked_hand(RIGHT_HAND_TRACKER)
	if tracker == null:
		tracker = _tracked_hand(LEFT_HAND_TRACKER)
	if tracker == null or origin == null or hmd_camera == null:
		if _hand_pointer_down:
			_release_pressed_target()
			_hand_pointer_down = false
		target.clear_pointer()
		_hide_ui_pointer_visual()
		return

	var index_tip: Vector3 = origin.to_global(tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin)
	var thumb_tip: Vector3 = origin.to_global(tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin)
	var direction := index_tip - hmd_camera.global_position
	var has_intersection := false
	var ray_direction := Vector3.ZERO
	if direction.length_squared() > 0.000001:
		ray_direction = direction.normalized()
		_set_target_feedback(target, "hands")
		has_intersection = target.update_pointer_from_ray(hmd_camera.global_position, ray_direction)
	var pressed := has_intersection and index_tip.distance_to(thumb_tip) <= HAND_PINCH_DISTANCE_M
	if has_intersection:
		_show_ui_pointer_visual(hmd_camera.global_position, ray_direction, target, pressed)
	elif ray_direction.length_squared() > 0.000001:
		target.clear_pointer()
		_show_idle_ui_pointer_visual(hmd_camera.global_position, ray_direction)
	else:
		_hide_ui_pointer_visual()
	if pressed != _hand_pointer_down:
		_hand_pointer_down = pressed
		if pressed:
			_press_target(target)
		else:
			_release_pressed_target()


func _on_controller_button_pressed(action: StringName, pointer: XRController3D) -> void:
	var action_name := String(action)
	if not click_actions.has(action_name):
		return
	_press_from_controller(pointer)


func _on_controller_button_released(action: StringName, pointer: XRController3D) -> void:
	var action_name := String(action)
	if not click_actions.has(action_name):
		return
	if pointer != _controller_pointer_down:
		return
	_release_pressed_target()
	_controller_pointer_down = null


func _update_analog_trigger(pointer: XRController3D) -> void:
	if pointer == null or analog_trigger_action == &"":
		return
	var key := pointer.get_instance_id()
	var value := pointer.get_float(analog_trigger_action)
	var was_down := bool(_trigger_down.get(key, false))
	var is_down := value > trigger_release_threshold if was_down else value >= trigger_press_threshold
	_trigger_down[key] = is_down
	if is_down == was_down:
		return
	if is_down:
		_press_from_controller(pointer)
	elif pointer == _controller_pointer_down:
		_release_pressed_target()
		_controller_pointer_down = null


func _press_from_controller(pointer: XRController3D) -> void:
	var target := _active_target()
	if target == null:
		return
	var feedback_mode := _feedback_mode_for_pointer(pointer)
	_set_target_feedback(target, feedback_mode, pointer if feedback_mode == "controllers" else null)
	if not target.update_pointer_from_ray(pointer.global_transform.origin, -pointer.global_transform.basis.z):
		return
	_controller_pointer_down = pointer
	_show_ui_pointer_visual(pointer.global_transform.origin, -pointer.global_transform.basis.z, target, true)
	_press_target(target)


func _press_target(target: Object) -> void:
	_pressed_target = target
	target.set_pointer_pressed(true)


func _release_pressed_target() -> void:
	if _pressed_target:
		_pressed_target.set_pointer_pressed(false)
		_pressed_target = null


func _show_ui_pointer_visual(ray_origin: Vector3, ray_direction: Vector3, target: Object, pressed: bool) -> void:
	if ui_pointer_visual == null:
		return
	if not ui_pointer_visual.has_method("show_ray"):
		return
	var hit_point := ray_origin + ray_direction.normalized() * 0.25
	if target.has_method("get_ray_hit_point"):
		hit_point = target.get_ray_hit_point(ray_origin, ray_direction)
	ui_pointer_visual.show_ray(ray_origin, ray_direction, hit_point, pressed)


func _show_idle_ui_pointer_visual(ray_origin: Vector3, ray_direction: Vector3) -> void:
	if ui_pointer_visual == null:
		return
	if ui_pointer_visual.has_method("show_idle_ray"):
		ui_pointer_visual.show_idle_ray(ray_origin, ray_direction)
	elif ui_pointer_visual.has_method("clear"):
		ui_pointer_visual.clear()


func _set_target_feedback(target: Object, mode: String, controller: XRController3D = null) -> void:
	if target != null and target.has_method("set_feedback_input_mode"):
		target.set_feedback_input_mode(mode, controller)


func _feedback_mode_for_pointer(pointer: XRController3D) -> String:
	var haptics := _get_haptics_bus()
	if haptics != null and haptics.has_method("should_use_controller_feedback"):
		if not bool(haptics.call("should_use_controller_feedback", pointer)):
			return "hands"
	return "controllers"


func _get_haptics_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Haptics")


func _hide_ui_pointer_visual() -> void:
	if ui_pointer_visual and ui_pointer_visual.has_method("clear"):
		ui_pointer_visual.clear()


func _tracked_hand(tracker_name: StringName) -> XRHandTracker:
	var tracker := XRServer.get_tracker(tracker_name)
	if tracker is XRHandTracker and (tracker as XRHandTracker).has_tracking_data:
		return tracker as XRHandTracker
	return null


func _has_tracking(pointer: XRController3D) -> bool:
	return pointer != null and pointer.get_has_tracking_data()
