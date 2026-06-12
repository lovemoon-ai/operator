extends Node
class_name SettingsInteractionRouter

const LEFT_HAND_TRACKER := &"/user/hand_tracker/left"
const RIGHT_HAND_TRACKER := &"/user/hand_tracker/right"
const HAND_JOINT_PALM := 0
const HAND_JOINT_WRIST := 1
const HAND_JOINT_THUMB_TIP := 5
const HAND_JOINT_INDEX_FINGER_PROXIMAL := 7
const HAND_JOINT_INDEX_FINGER_TIP := 10
const HAND_JOINT_MIDDLE_FINGER_PROXIMAL := 12
const HAND_JOINT_MIDDLE_FINGER_TIP := 15
const HAND_PINCH_PRESS_DISTANCE_M := 0.055
const HAND_PINCH_RELEASE_DISTANCE_M := 0.075
const HAND_PINCH_OPEN_DISTANCE_M := 0.120
const HAND_PINCH_PRESS_VALUE := 0.55
const HAND_PINCH_RELEASE_VALUE := 0.35
const HAND_RAY_SMOOTH_ALPHA := 0.42
const HAND_RAY_PALM_FORWARD_OFFSET_M := 0.018
const HAND_RAY_MAX_FINGER_BLEND := 0.18
const HAND_ACTIVE_SWITCH_GRACE_MS := 350

var click_actions: PackedStringArray = PackedStringArray(["trigger_click", "primary_click", "select_button"])
var analog_trigger_action: StringName = &"trigger"
var hand_pinch_action: StringName = &"hand_pinch"
var hand_pinch_ready_action: StringName = &"hand_pinch_ready"
var scroll_vector_action: StringName = &"primary"
var trigger_press_threshold := 0.55
var trigger_release_threshold := 0.35
var scroll_dead_zone := 0.28
var scroll_speed_pixels_per_second := 760.0
var interaction_mode := "controllers"
var busy := false

var origin: XROrigin3D
var hmd_camera: XRCamera3D
var left_pointer: XRController3D
var right_pointer: XRController3D
var ui_pointer_visual: Node

var _targets: Array[Object] = []
var _pressed_target: Object
var _hover_target: Object
var _controller_pointer_down: XRController3D
var _hand_pointer_down := false
var _trigger_down: Dictionary = {}
var _active_hand_side := ""
var _active_hand_seen_msec := 0
var _hand_ray_source := ""
var _hand_ray_origin := Vector3.ZERO
var _hand_ray_direction := Vector3.ZERO
var _last_scroll_ticks_usec := 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_RESUMED:
		reset_input_state()


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

	if _candidate_targets().is_empty():
		_last_scroll_ticks_usec = 0
		release_pointer()
		return

	if _should_use_controller_pointer():
		_update_controller_pointer()
	elif interaction_mode == "hands":
		_update_hand_pointer()
	else:
		release_pointer()

	# Joystick scrolls whichever target the pointer is currently hovering;
	# _hover_target is set by the controller/hand pointer updates above.
	_update_joystick_scroll(_hover_target)


func release_pointer() -> void:
	_release_pressed_target()
	_controller_pointer_down = null
	_hand_pointer_down = false
	for target in _targets:
		if target and target.has_method("clear_pointer"):
			target.clear_pointer()
	_hover_target = null
	_hide_ui_pointer_visual()
	_reset_hand_state()


func reset_input_state() -> void:
	_trigger_down.clear()
	_last_scroll_ticks_usec = 0
	release_pointer()


func _update_joystick_scroll(target: Object) -> void:
	if target == null or not target.has_method("scroll_by_pixels"):
		_last_scroll_ticks_usec = 0
		return
	var now := Time.get_ticks_usec()
	if _last_scroll_ticks_usec <= 0:
		_last_scroll_ticks_usec = now
		return
	var delta_seconds := clampf(float(now - _last_scroll_ticks_usec) / 1000000.0, 0.0, 0.05)
	_last_scroll_ticks_usec = now
	var axis_y := _scroll_axis(_controller_pointer_down)
	if absf(axis_y) < scroll_dead_zone:
		var right_y := _scroll_axis(right_pointer)
		var left_y := _scroll_axis(left_pointer)
		axis_y = right_y if absf(right_y) >= absf(left_y) else left_y
	if absf(axis_y) < scroll_dead_zone:
		return
	target.call("scroll_by_pixels", -axis_y * scroll_speed_pixels_per_second * delta_seconds)


func _scroll_axis(pointer: XRController3D) -> float:
	if pointer == null or scroll_vector_action == &"" or not _has_tracking(pointer):
		return 0.0
	var value := pointer.get_vector2(scroll_vector_action)
	return value.y


func _connect_controller(pointer: XRController3D) -> void:
	if pointer == null:
		return
	if not pointer.button_pressed.is_connected(_on_controller_button_pressed.bind(pointer)):
		pointer.button_pressed.connect(_on_controller_button_pressed.bind(pointer))
	if not pointer.button_released.is_connected(_on_controller_button_released.bind(pointer)):
		pointer.button_released.connect(_on_controller_button_released.bind(pointer))


func _candidate_targets() -> Array[Object]:
	var out: Array[Object] = []
	for target in _targets:
		if target == null:
			continue
		if not _target_visible(target):
			continue
		if not target.has_method("update_pointer_from_ray"):
			continue
		if not target.has_method("set_pointer_pressed"):
			continue
		if not target.has_method("clear_pointer"):
			continue
		out.append(target)
	return out


func _target_visible(target: Object) -> bool:
	if target.has_method("is_interaction_target_visible"):
		return bool(target.call("is_interaction_target_visible"))
	var visible_value: Variant = target.get("visible")
	if typeof(visible_value) == TYPE_NIL:
		return true
	return bool(visible_value)


func _should_use_controller_pointer() -> bool:
	if interaction_mode == "hands":
		return false
	return interaction_mode == "controllers" or (interaction_mode == "head" and not busy)


func _update_controller_pointer() -> void:
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
		_set_hover_target(null)
		_hide_ui_pointer_visual()
		return

	var ray_origin := pointer.global_transform.origin
	var ray_direction := -pointer.global_transform.basis.z
	var feedback_mode := _feedback_mode_for_pointer(pointer)
	var target: Object
	if _controller_pointer_down != null and _pressed_target != null:
		target = _pressed_target
		_set_target_feedback(target, feedback_mode, pointer if feedback_mode == "controllers" else null)
		if target.update_pointer_from_ray(ray_origin, ray_direction):
			_set_hover_target(target)
		else:
			_set_hover_target(null)
			target = null
	else:
		target = _target_from_ray(ray_origin, ray_direction, feedback_mode, pointer if feedback_mode == "controllers" else null)
	if target != null:
		_show_ui_pointer_visual(ray_origin, ray_direction, target, _controller_pointer_down != null)
	else:
		_show_idle_ui_pointer_visual(ray_origin, ray_direction)


func _update_hand_pointer() -> void:
	if _controller_pointer_down:
		_release_pressed_target()
		_controller_pointer_down = null

	var tracker := _tracked_hand(RIGHT_HAND_TRACKER)
	if tracker == null:
		tracker = _tracked_hand(LEFT_HAND_TRACKER)
	if tracker == null or origin == null:
		if _hand_pointer_down:
			_release_pressed_target()
			_hand_pointer_down = false
		_set_hover_target(null)
		_hide_ui_pointer_visual()
		_reset_hand_state()
		return

	var hand_ray := _hand_pointer_ray()
	if hand_ray.is_empty():
		if _hand_pointer_down:
			_release_pressed_target()
			_hand_pointer_down = false
		_set_hover_target(null)
		_hide_ui_pointer_visual()
		_reset_hand_state()
		return

	var ray_origin: Vector3 = hand_ray.get("origin", Vector3.ZERO)
	var ray_direction: Vector3 = hand_ray.get("direction", Vector3.ZERO)
	var has_intersection := false
	var target: Object
	if ray_direction.length_squared() > 0.000001:
		if _pressed_target != null:
			target = _pressed_target
			_set_target_feedback(target, "hands")
			has_intersection = target.update_pointer_from_ray(ray_origin, ray_direction)
			if has_intersection:
				_set_hover_target(target)
			else:
				_set_hover_target(null)
		else:
			target = _target_from_ray(ray_origin, ray_direction, "hands")
			has_intersection = target != null
	var pinch_active := _hand_pinch_active(hand_ray)
	var can_press_target := target != null and (has_intersection or _pressed_target != null)
	var pressed := pinch_active and can_press_target
	if has_intersection and target != null:
		_show_ui_pointer_visual(ray_origin, ray_direction, target, pressed)
	elif ray_direction.length_squared() > 0.000001:
		_show_idle_ui_pointer_visual(ray_origin, ray_direction)
	else:
		_hide_ui_pointer_visual()
	if pressed != _hand_pointer_down:
		_hand_pointer_down = pressed
		if pressed:
			_press_target(target)
		else:
			_release_pressed_target()


func _on_controller_button_pressed(action: StringName, pointer: XRController3D) -> void:
	if interaction_mode == "hands":
		return
	var action_name := String(action)
	if not click_actions.has(action_name):
		return
	_press_from_controller(pointer)


func _on_controller_button_released(action: StringName, pointer: XRController3D) -> void:
	if interaction_mode == "hands":
		return
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
	if pointer == null:
		return
	var feedback_mode := _feedback_mode_for_pointer(pointer)
	var target := _target_from_ray(
			pointer.global_transform.origin,
			-pointer.global_transform.basis.z,
			feedback_mode,
			pointer if feedback_mode == "controllers" else null
	)
	if target == null:
		return
	_controller_pointer_down = pointer
	_show_ui_pointer_visual(pointer.global_transform.origin, -pointer.global_transform.basis.z, target, true)
	_press_target(target)


func _press_target(target: Object) -> void:
	if _pressed_target != null and _pressed_target != target:
		_pressed_target.set_pointer_pressed(false)
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
	# OpenXR composition layers are blended on top of the 3D scene by the XR
	# runtime's compositor, so any 3D cursor mesh placed at the hit point
	# would render BEHIND the panel no matter what (no_depth_test /
	# render_priority only affect 3D-pass ordering). Composition-layer panels
	# have their own in-viewport 2D cursor — suppress our 3D sphere in that
	# case and let the laser carry the directional cue.
	var suppress_target := target is OpenXRCompositionLayer
	ui_pointer_visual.show_ray(ray_origin, ray_direction, hit_point, pressed, suppress_target)


func _show_idle_ui_pointer_visual(ray_origin: Vector3, ray_direction: Vector3) -> void:
	if ui_pointer_visual == null:
		return
	if ui_pointer_visual.has_method("show_idle_ray"):
		ui_pointer_visual.show_idle_ray(ray_origin, ray_direction)
	elif ui_pointer_visual.has_method("clear"):
		ui_pointer_visual.clear()


func _target_from_ray(
		ray_origin: Vector3,
		ray_direction: Vector3,
		mode: String,
		controller: XRController3D = null
) -> Object:
	for target in _candidate_targets():
		_set_target_feedback(target, mode, controller)
		if target.update_pointer_from_ray(ray_origin, ray_direction):
			_set_hover_target(target)
			return target
	_set_hover_target(null)
	return null


func _set_hover_target(target: Object) -> void:
	if target == _hover_target:
		return
	if _hover_target != null and _hover_target != _pressed_target and _hover_target.has_method("clear_pointer"):
		_hover_target.clear_pointer()
	_hover_target = target


func _set_target_feedback(target: Object, mode: String, controller: XRController3D = null) -> void:
	if target != null and target.has_method("set_feedback_input_mode"):
		target.set_feedback_input_mode(mode, controller)


func _hand_pointer_ray() -> Dictionary:
	if origin == null:
		return {}

	if not _active_hand_side.is_empty():
		var active_ray := _hand_ray_for_side(_active_hand_side)
		if not active_ray.is_empty():
			return _activate_hand_ray(active_ray)
		if _within_active_hand_grace():
			return _stale_active_hand_ray()

	for side in _hand_side_order():
		var hand_ray := _hand_ray_for_side(side)
		if not hand_ray.is_empty():
			return _activate_hand_ray(hand_ray)

	return {}


func _hand_side_order() -> Array[String]:
	var order: Array[String] = []
	if _active_hand_side == "left":
		order.append("left")
	else:
		order.append("right")
	if order[0] == "right":
		order.append("left")
	else:
		order.append("right")
	return order


func _hand_ray_for_side(side: String) -> Dictionary:
	var pointer := right_pointer
	var tracker_name := RIGHT_HAND_TRACKER
	if side == "left":
		pointer = left_pointer
		tracker_name = LEFT_HAND_TRACKER

	var aim_ray := _hand_aim_ray(pointer, tracker_name, side)
	if not aim_ray.is_empty():
		return aim_ray
	return _hand_joint_ray(tracker_name, side)


func _activate_hand_ray(ray: Dictionary) -> Dictionary:
	var side := String(ray.get("side", ""))
	if side.is_empty():
		var source := String(ray.get("source", ""))
		side = "left" if source.ends_with("_left") else "right"
	_active_hand_side = side
	_active_hand_seen_msec = Time.get_ticks_msec()
	return _smooth_hand_ray(ray)


func _within_active_hand_grace() -> bool:
	if _active_hand_side.is_empty():
		return false
	if _hand_ray_direction.length_squared() < 0.000001:
		return false
	return Time.get_ticks_msec() - _active_hand_seen_msec <= HAND_ACTIVE_SWITCH_GRACE_MS


func _stale_active_hand_ray() -> Dictionary:
	return {
		"source": _hand_ray_source,
		"side": _active_hand_side,
		"origin": _hand_ray_origin,
		"direction": _hand_ray_direction,
		"pinch_value_valid": false,
		"pinch_value": 0.0,
		"pinch_valid": false,
		"pinch_distance": 999.0,
	}


func _hand_aim_ray(pointer: XRController3D, tracker_name: StringName, side: String) -> Dictionary:
	if pointer == null or not _has_tracking(pointer):
		return {}
	if pointer.pose != &"aim" and pointer.name.to_lower().find("aim") == -1:
		return {}
	if _feedback_mode_for_pointer(pointer) != "hands":
		return {}
	var tracker := _tracked_hand(tracker_name)
	if tracker == null:
		return {}
	var ray_direction := -pointer.global_transform.basis.z
	if ray_direction.length_squared() < 0.000001:
		return {}
	var index_tip := _hand_joint_transform(tracker, HAND_JOINT_INDEX_FINGER_TIP)
	var thumb_tip := _hand_joint_transform(tracker, HAND_JOINT_THUMB_TIP)
	var pinch_distance := _pinch_distance_from_joints(index_tip, thumb_tip)
	var pinch_state := _hand_interaction_pinch(pointer)
	return {
		"source": "aim_%s" % side,
		"side": side,
		"origin": pointer.global_transform.origin,
		"direction": ray_direction.normalized(),
		"index_tip": _joint_position_or(index_tip, Vector3.ZERO),
		"thumb_tip": _joint_position_or(thumb_tip, Vector3.ZERO),
		"pinch_value_valid": bool(pinch_state.get("valid", false)),
		"pinch_value": float(pinch_state.get("value", 0.0)),
		"pinch_ready": bool(pinch_state.get("ready", false)),
		"pinch_valid": pinch_distance >= 0.0,
		"pinch_distance": pinch_distance,
	}


func _hand_joint_ray(tracker_name: StringName, side: String) -> Dictionary:
	var tracker := _tracked_hand(tracker_name)
	if tracker == null:
		return {}

	var palm_joint := _hand_joint_transform(tracker, HAND_JOINT_PALM)
	if palm_joint.is_empty():
		return {}
	var wrist_joint := _hand_joint_transform(tracker, HAND_JOINT_WRIST)
	var index_proximal_joint := _hand_joint_transform(tracker, HAND_JOINT_INDEX_FINGER_PROXIMAL)
	var middle_proximal_joint := _hand_joint_transform(tracker, HAND_JOINT_MIDDLE_FINGER_PROXIMAL)
	var index_tip_joint := _hand_joint_transform(tracker, HAND_JOINT_INDEX_FINGER_TIP)
	var middle_tip_joint := _hand_joint_transform(tracker, HAND_JOINT_MIDDLE_FINGER_TIP)
	var thumb_tip_joint := _hand_joint_transform(tracker, HAND_JOINT_THUMB_TIP)

	var palm := _joint_position_or(palm_joint, Vector3.ZERO)
	var wrist := _joint_position_or(wrist_joint, palm)
	var index_proximal := _joint_position_or(index_proximal_joint, palm)
	var middle_proximal := _joint_position_or(middle_proximal_joint, index_proximal)
	var index_tip := _joint_position_or(index_tip_joint, index_proximal)
	var middle_tip := _joint_position_or(middle_tip_joint, middle_proximal)
	var thumb_tip := _joint_position_or(thumb_tip_joint, palm)
	var palm_basis: Basis = palm_joint.get("basis", Basis.IDENTITY)
	var pinch_distance := _pinch_distance_from_joints(index_tip_joint, thumb_tip_joint)

	var ray_direction := _stable_hand_ray_direction(
			palm_basis,
			palm,
			wrist,
			index_proximal,
			middle_proximal,
			index_tip,
			middle_tip,
			pinch_distance
	)
	if ray_direction.length_squared() < 0.000001:
		return {}
	ray_direction = ray_direction.normalized()

	var knuckle_center := (index_proximal + middle_proximal) * 0.5
	var ray_origin := palm
	if ray_origin.distance_squared_to(wrist) < 0.000001:
		ray_origin = knuckle_center.lerp(wrist, 0.35)
	ray_origin += ray_direction * HAND_RAY_PALM_FORWARD_OFFSET_M

	return {
		"source": "joint_%s" % side,
		"side": side,
		"origin": ray_origin,
		"direction": ray_direction,
		"index_tip": index_tip,
		"thumb_tip": thumb_tip,
		"pinch_value_valid": false,
		"pinch_value": 0.0,
		"pinch_valid": pinch_distance >= 0.0,
		"pinch_distance": pinch_distance,
	}


func _stable_hand_ray_direction(
		palm_basis: Basis,
		palm: Vector3,
		wrist: Vector3,
		index_proximal: Vector3,
		middle_proximal: Vector3,
		index_tip: Vector3,
		middle_tip: Vector3,
		pinch_distance: float
) -> Vector3:
	var candidates: Array[Vector3] = []
	_append_ray_candidate(candidates, -palm_basis.z)
	_append_ray_candidate(candidates, palm_basis.z)
	_append_ray_candidate(candidates, palm_basis.y)
	_append_ray_candidate(candidates, -palm_basis.y)
	_append_ray_candidate(candidates, palm_basis.x)
	_append_ray_candidate(candidates, -palm_basis.x)

	var knuckle_center := (index_proximal + middle_proximal) * 0.5
	var proximal_axis := knuckle_center - wrist
	if proximal_axis.length_squared() > 0.000001:
		proximal_axis = proximal_axis.normalized()
		_append_ray_candidate(candidates, proximal_axis)
		var across := index_proximal - middle_proximal
		if across.length_squared() > 0.000001:
			var palm_normal := proximal_axis.cross(across.normalized())
			_append_ray_candidate(candidates, palm_normal)
			_append_ray_candidate(candidates, -palm_normal)

	var ray_direction := _best_hand_ray_candidate(candidates, palm, proximal_axis)
	var fingertip_center := (index_tip + middle_tip) * 0.5
	var finger_direction := fingertip_center - knuckle_center
	if finger_direction.length_squared() > 0.000001:
		finger_direction = finger_direction.normalized()

	if ray_direction.length_squared() < 0.000001:
		ray_direction = finger_direction
	if ray_direction.length_squared() < 0.000001 and hmd_camera != null:
		ray_direction = -hmd_camera.global_transform.basis.z
	if ray_direction.length_squared() < 0.000001:
		return Vector3.ZERO

	if finger_direction.length_squared() > 0.000001 and ray_direction.normalized().dot(finger_direction) > 0.2:
		var blend := _hand_finger_blend(pinch_distance)
		ray_direction = ray_direction.normalized().lerp(finger_direction, blend).normalized()
	return ray_direction.normalized()


func _append_ray_candidate(candidates: Array[Vector3], candidate: Vector3) -> void:
	if candidate.length_squared() < 0.000001:
		return
	candidates.append(candidate.normalized())


func _best_hand_ray_candidate(candidates: Array[Vector3], palm: Vector3, finger_axis: Vector3) -> Vector3:
	var away_from_head := Vector3.ZERO
	var camera_forward := Vector3.ZERO
	if hmd_camera != null:
		away_from_head = palm - hmd_camera.global_position
		if away_from_head.length_squared() > 0.000001:
			away_from_head = away_from_head.normalized()
		camera_forward = -hmd_camera.global_transform.basis.z
		if camera_forward.length_squared() > 0.000001:
			camera_forward = camera_forward.normalized()
	if finger_axis.length_squared() > 0.000001:
		finger_axis = finger_axis.normalized()

	var best := Vector3.ZERO
	var best_score := -9999.0
	for candidate in candidates:
		var score := 0.0
		if away_from_head.length_squared() > 0.000001:
			var away_dot := candidate.dot(away_from_head)
			score += away_dot
			if away_dot < -0.12:
				score -= 3.0
		if camera_forward.length_squared() > 0.000001:
			score += candidate.dot(camera_forward) * 0.45
		if finger_axis.length_squared() > 0.000001:
			score += maxf(candidate.dot(finger_axis), 0.0) * 0.12
		if score > best_score:
			best_score = score
			best = candidate
	return best


func _hand_finger_blend(pinch_distance: float) -> float:
	if pinch_distance < 0.0:
		return 0.0
	if pinch_distance <= HAND_PINCH_RELEASE_DISTANCE_M:
		return 0.0
	var t := (pinch_distance - HAND_PINCH_RELEASE_DISTANCE_M) \
			/ (HAND_PINCH_OPEN_DISTANCE_M - HAND_PINCH_RELEASE_DISTANCE_M)
	return clampf(t, 0.0, 1.0) * HAND_RAY_MAX_FINGER_BLEND


func _hand_pinch_active(ray: Dictionary) -> bool:
	if bool(ray.get("pinch_value_valid", false)):
		var pinch_value := float(ray.get("pinch_value", 0.0))
		var value_threshold := HAND_PINCH_RELEASE_VALUE if _hand_pointer_down else HAND_PINCH_PRESS_VALUE
		return pinch_value >= value_threshold
	if not bool(ray.get("pinch_valid", false)):
		return false
	var pinch_distance := float(ray.get("pinch_distance", 999.0))
	if pinch_distance < 0.0:
		return false
	var threshold := HAND_PINCH_RELEASE_DISTANCE_M if _hand_pointer_down else HAND_PINCH_PRESS_DISTANCE_M
	return pinch_distance <= threshold


func _hand_interaction_pinch(pointer: XRController3D) -> Dictionary:
	if pointer == null:
		return {"valid": false, "value": 0.0, "ready": false}
	var value := clampf(pointer.get_float(hand_pinch_action), 0.0, 1.0)
	var ready := false
	if hand_pinch_ready_action != &"" and pointer.has_method("is_button_pressed"):
		ready = pointer.is_button_pressed(hand_pinch_ready_action)
	return {
		"valid": ready or value > 0.001,
		"value": value,
		"ready": ready,
	}


func _pinch_distance_from_joints(index_tip: Dictionary, thumb_tip: Dictionary) -> float:
	if index_tip.is_empty() or thumb_tip.is_empty():
		return -1.0
	return _joint_position_or(index_tip, Vector3.ZERO).distance_to(_joint_position_or(thumb_tip, Vector3.ZERO))


func _joint_position_or(joint: Dictionary, fallback: Vector3) -> Vector3:
	if joint.is_empty():
		return fallback
	return joint.get("position", fallback)


func _hand_joint_transform(tracker: XRHandTracker, joint: int) -> Dictionary:
	if origin == null:
		return {}
	var local_transform := tracker.get_hand_joint_transform(joint)
	if tracker.get_hand_joint_flags(joint) == 0 and local_transform.origin.length_squared() < 0.000001:
		return {}
	var joint_transform := origin.global_transform * local_transform
	return {
		"position": joint_transform.origin,
		"basis": joint_transform.basis,
	}


func _smooth_hand_ray(ray: Dictionary) -> Dictionary:
	var source := String(ray.get("source", ""))
	var raw_origin: Vector3 = ray.get("origin", Vector3.ZERO)
	var raw_direction: Vector3 = ray.get("direction", Vector3.ZERO)
	if raw_direction.length_squared() < 0.000001:
		return {}
	raw_direction = raw_direction.normalized()

	if source != _hand_ray_source or _hand_ray_direction.length_squared() < 0.000001:
		_hand_ray_source = source
		_hand_ray_origin = raw_origin
		_hand_ray_direction = raw_direction
	else:
		_hand_ray_origin = _hand_ray_origin.lerp(raw_origin, HAND_RAY_SMOOTH_ALPHA)
		_hand_ray_direction = _hand_ray_direction.lerp(raw_direction, HAND_RAY_SMOOTH_ALPHA).normalized()

	ray["origin"] = _hand_ray_origin
	ray["direction"] = _hand_ray_direction
	return ray


func _reset_hand_ray_smoothing() -> void:
	_hand_ray_source = ""
	_hand_ray_origin = Vector3.ZERO
	_hand_ray_direction = Vector3.ZERO


func _reset_hand_state() -> void:
	_active_hand_side = ""
	_active_hand_seen_msec = 0
	_reset_hand_ray_smoothing()


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
