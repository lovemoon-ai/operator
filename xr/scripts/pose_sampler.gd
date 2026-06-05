extends Node
class_name PoseSampler

const LEFT_HAND_TRACKER := &"/user/hand_tracker/left"
const RIGHT_HAND_TRACKER := &"/user/hand_tracker/right"

# Per-category JSONL write throttles. Head still goes to the mp4 `mett` stream
# every sample() call (cheap JNI Enqueue), but the GDScript-side JSONL writes
# are far more expensive (Dictionary build + JSON.stringify +
# FileAccess.store_line per record). Capping them at ~30 Hz / 60 Hz keeps the
# main thread fast enough for 72 Hz UI rendering without losing meaningful
# offline-analysis fidelity for controllers / hands.
const HEAD_JSONL_INTERVAL_US := 16667        # 60 Hz
const CONTROLLER_JSONL_INTERVAL_US := 33333  # 30 Hz
const HAND_JSONL_INTERVAL_US := 33333        # 30 Hz
const INPUT_PACKET_SNAPSHOT := 1
const INPUT_PACKET_EVENT := 2
const INPUT_ANALOG_EPSILON := 0.01

const INPUT_TRIGGER_CLICK := 1 << 0
const INPUT_TRIGGER_TOUCH := 1 << 1
const INPUT_GRIP_CLICK := 1 << 2
const INPUT_THUMBSTICK_CLICK := 1 << 3
const INPUT_THUMBSTICK_TOUCH := 1 << 4
const INPUT_A_CLICK := 1 << 5
const INPUT_A_TOUCH := 1 << 6
const INPUT_B_CLICK := 1 << 7
const INPUT_B_TOUCH := 1 << 8
const INPUT_X_CLICK := 1 << 9
const INPUT_X_TOUCH := 1 << 10
const INPUT_Y_CLICK := 1 << 11
const INPUT_Y_TOUCH := 1 << 12
const INPUT_MENU_CLICK := 1 << 13
const INPUT_SYSTEM_CLICK := 1 << 14
const INPUT_THUMBREST_TOUCH := 1 << 15
const INPUT_TRACKPAD_CLICK := 1 << 16
const INPUT_TRACKPAD_TOUCH := 1 << 17

var writer: Object
var hmd_camera: XRCamera3D
var left_controller: XRController3D
var right_controller: XRController3D
var _record_head_pose := true
var _record_controller_pose := true
var _record_controller_input := true
var _record_hand_data := true
var _last_head_jsonl_us := 0
var _last_controller_jsonl_us := 0
var _last_hand_jsonl_us := 0
var _xr_display_time_provider: Object
var _capture_provider: Object
var _xr_display_time_supported := true
var _xr_time_offset_ns := 0
var _xr_time_offset_resolved := false
# 1Hz metrics surface: capture_app's metrics ticker reads-and-resets these
# so the per-sub-system rates align on the same wall-clock second.
var _sample_count := 0
var _head_count := 0
var _controller_count := 0
var _controller_input_count := 0
var _hand_count := 0
var _hand_joint_count := 0
var _controller_input_states := {}


func pop_metrics() -> Dictionary:
	var metrics := {
		"samples": _sample_count,
		"head_writes": _head_count,
		"controller_writes": _controller_count,
		"controller_input_writes": _controller_input_count,
		"hand_writes": _hand_count,
		"hand_joints": _hand_joint_count
	}
	_sample_count = 0
	_head_count = 0
	_controller_count = 0
	_controller_input_count = 0
	_hand_count = 0
	_hand_joint_count = 0
	return metrics


func configure(
	p_writer: Object,
	p_hmd_camera: XRCamera3D,
	p_left_controller: XRController3D,
	p_right_controller: XRController3D,
	p_capture_provider: Object = null
) -> void:
	writer = p_writer
	hmd_camera = p_hmd_camera
	left_controller = p_left_controller
	right_controller = p_right_controller
	_capture_provider = p_capture_provider
	_connect_controller_input_signals(left_controller, "left_controller")
	_connect_controller_input_signals(right_controller, "right_controller")
	_xr_display_time_provider = null
	_xr_display_time_supported = true
	for singleton_name in [
		"OpenXRMetaEnvironmentDepthExtensionWrapper",
		"OpenXRMetaEnvironmentDepthExtension"
	]:
		if Engine.has_singleton(singleton_name):
			var candidate := Engine.get_singleton(singleton_name)
			if candidate != null and candidate.has_method("get_predicted_display_time_ns"):
				_xr_display_time_provider = candidate
				break


func resolve_pose_timestamp_ns(default_ticks_ns: int) -> int:
	# Prefer the OpenXR-predicted display time (XrTime, ns) when the patched
	# Vendors wrapper exposes it, so pose, depth, and RGB share the same XR
	# time origin. XrTime is CLOCK_MONOTONIC ns since boot; the Android
	# plugin's captured offset moves it into the Godot-ticks-ns domain used
	# everywhere else in the live mux pipeline.
	if _xr_display_time_provider != null and _xr_display_time_supported:
		var raw: Variant = _xr_display_time_provider.call("get_predicted_display_time_ns")
		if raw != null:
			var value := int(raw)
			if value > 0:
				return value + _resolve_xr_time_offset_ns()
	return default_ticks_ns


func _resolve_xr_time_offset_ns() -> int:
	if _xr_time_offset_resolved:
		return _xr_time_offset_ns
	var plugin := _capture_provider
	if plugin == null and Engine.has_singleton("QuestCapturePlugin"):
		plugin = Engine.get_singleton("QuestCapturePlugin")
	if plugin == null:
		return 0
	# Same caveat as DepthSampler: Android singleton `has_method` is unreliable
	# for Kotlin `@UsedByGodot` getters, so we call directly and accept either
	# the value or 0 if the bridge has not captured its anchors yet.
	var raw: Variant = plugin.call("getXrTimeToGodotTicksOffsetNs")
	if raw == null:
		return 0
	var value := int(raw)
	if value == 0:
		return 0
	_xr_time_offset_ns = value
	_xr_time_offset_resolved = true
	return _xr_time_offset_ns


func set_capture_options(options: Dictionary) -> void:
	_record_head_pose = bool(options.get("record_head_pose", true))
	_record_controller_pose = bool(options.get("record_controller_pose", true))
	_record_controller_input = bool(options.get("record_controller_input", _record_controller_pose))
	_record_hand_data = bool(options.get("record_hand_data", true))
	_controller_input_states.clear()


func sample(timestamp_ns: int) -> void:
	if writer == null:
		return

	_sample_count += 1
	var resolved_ts := resolve_pose_timestamp_ns(timestamp_ns)
	var now_us := Time.get_ticks_usec()

	if _record_head_pose and hmd_camera:
		# mp4 mett stream gets every sample (cheap JNI). JSONL is throttled
		# so GDScript JSON.stringify does not dominate the main thread.
		var head_jsonl: bool = (now_us - _last_head_jsonl_us) >= HEAD_JSONL_INTERVAL_US
		writer.write_head_pose(resolved_ts, hmd_camera.global_transform, true, head_jsonl)
		_head_count += 1
		if head_jsonl:
			_last_head_jsonl_us = now_us

	var controller_jsonl: bool = (now_us - _last_controller_jsonl_us) >= CONTROLLER_JSONL_INTERVAL_US
	if _record_controller_pose and left_controller and controller_jsonl:
		writer.write_controller_pose(
			"left_controller",
			resolved_ts,
			left_controller.global_transform,
			left_controller.get_has_tracking_data()
		)
		_controller_count += 1

	if _record_controller_pose and right_controller and controller_jsonl:
		writer.write_controller_pose(
			"right_controller",
			resolved_ts,
			right_controller.global_transform,
			right_controller.get_has_tracking_data()
		)
		_controller_count += 1
	if controller_jsonl and _record_controller_pose:
		_last_controller_jsonl_us = now_us

	if _record_controller_input and left_controller:
		_sample_controller_input("left_controller", left_controller, resolved_ts)
	if _record_controller_input and right_controller:
		_sample_controller_input("right_controller", right_controller, resolved_ts)

	if _record_hand_data:
		var hand_jsonl: bool = (now_us - _last_hand_jsonl_us) >= HAND_JSONL_INTERVAL_US
		if hand_jsonl:
			_sample_hand("left", LEFT_HAND_TRACKER, resolved_ts)
			_sample_hand("right", RIGHT_HAND_TRACKER, resolved_ts)
			_last_hand_jsonl_us = now_us


func _sample_hand(hand: String, tracker_name: StringName, timestamp_ns: int) -> void:
	var tracker := XRServer.get_tracker(tracker_name)
	if tracker == null or not (tracker is XRHandTracker):
		return

	var hand_tracker := tracker as XRHandTracker
	if not hand_tracker.has_tracking_data:
		return

	var joints: Array = []
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		var transform := hand_tracker.get_hand_joint_transform(joint)
		var q := transform.basis.get_rotation_quaternion()
		var p := transform.origin
		joints.append({
			"joint": joint,
			"flags": hand_tracker.get_hand_joint_flags(joint),
			"radius_m": hand_tracker.get_hand_joint_radius(joint),
			"position": {"x": p.x, "y": p.y, "z": p.z},
			"rotation": {"x": q.x, "y": q.y, "z": q.z, "w": q.w}
		})

	writer.write_hand_joints(hand, timestamp_ns, joints)
	_hand_count += 1
	_hand_joint_count += joints.size()


func _connect_controller_input_signals(controller: XRController3D, source: String) -> void:
	if controller == null:
		return
	if controller.has_signal("button_pressed"):
		controller.button_pressed.connect(_on_controller_button_input_changed.bind(source, controller))
	if controller.has_signal("button_released"):
		controller.button_released.connect(_on_controller_button_input_changed.bind(source, controller))
	if controller.has_signal("input_float_changed"):
		controller.input_float_changed.connect(_on_controller_float_input_changed.bind(source, controller))
	if controller.has_signal("input_vector2_changed"):
		controller.input_vector2_changed.connect(_on_controller_vector2_input_changed.bind(source, controller))


func _on_controller_button_input_changed(_action: StringName, source: String, controller: XRController3D) -> void:
	_sample_controller_input(source, controller, resolve_pose_timestamp_ns(Time.get_ticks_usec() * 1000))


func _on_controller_float_input_changed(_action: StringName, _value: float, source: String, controller: XRController3D) -> void:
	_sample_controller_input(source, controller, resolve_pose_timestamp_ns(Time.get_ticks_usec() * 1000))


func _on_controller_vector2_input_changed(_action: StringName, _value: Vector2, source: String, controller: XRController3D) -> void:
	_sample_controller_input(source, controller, resolve_pose_timestamp_ns(Time.get_ticks_usec() * 1000))


func _sample_controller_input(source: String, controller: XRController3D, timestamp_ns: int) -> void:
	if writer == null or not _record_controller_input:
		return
	var state := _read_controller_input_state(source, controller)
	var previous: Variant = _controller_input_states.get(source)
	if previous == null:
		if _write_controller_input_state(source, timestamp_ns, INPUT_PACKET_SNAPSHOT, state, 0):
			_controller_input_states[source] = state
		return

	var previous_state := previous as Dictionary
	var changed_mask := int(previous_state.get("pressed_mask", 0)) ^ int(state.get("pressed_mask", 0))
	changed_mask |= int(previous_state.get("touched_mask", 0)) ^ int(state.get("touched_mask", 0))
	if changed_mask == 0 and not _analog_input_changed(previous_state, state):
		return

	var wrote_event := _write_controller_input_state(source, timestamp_ns, INPUT_PACKET_EVENT, state, changed_mask)
	var wrote_snapshot := _write_controller_input_state(source, timestamp_ns, INPUT_PACKET_SNAPSHOT, state, 0)
	if wrote_event and wrote_snapshot:
		_controller_input_states[source] = state


func _read_controller_input_state(source: String, controller: XRController3D) -> Dictionary:
	var is_left := source.begins_with("left")
	var available_mask := INPUT_TRIGGER_CLICK | INPUT_TRIGGER_TOUCH | INPUT_GRIP_CLICK
	available_mask |= INPUT_THUMBSTICK_CLICK | INPUT_THUMBSTICK_TOUCH
	available_mask |= INPUT_MENU_CLICK | INPUT_SYSTEM_CLICK
	if is_left:
		available_mask |= INPUT_X_CLICK | INPUT_X_TOUCH | INPUT_Y_CLICK | INPUT_Y_TOUCH
	else:
		available_mask |= INPUT_A_CLICK | INPUT_A_TOUCH | INPUT_B_CLICK | INPUT_B_TOUCH

	var pressed_mask := 0
	var touched_mask := 0
	if _controller_button(controller, "trigger_click"):
		pressed_mask |= INPUT_TRIGGER_CLICK
	if _controller_button(controller, "trigger_touch"):
		touched_mask |= INPUT_TRIGGER_TOUCH
	if _controller_button(controller, "grip_click"):
		pressed_mask |= INPUT_GRIP_CLICK
	if _controller_button(controller, "primary_click"):
		pressed_mask |= INPUT_THUMBSTICK_CLICK
	if _controller_button(controller, "primary_touch"):
		touched_mask |= INPUT_THUMBSTICK_TOUCH
	if _controller_button(controller, "menu_button"):
		pressed_mask |= INPUT_MENU_CLICK
	if _controller_button(controller, "select_button"):
		pressed_mask |= INPUT_SYSTEM_CLICK

	if is_left:
		if _controller_button(controller, "ax_button"):
			pressed_mask |= INPUT_X_CLICK
		if _controller_button(controller, "ax_touch"):
			touched_mask |= INPUT_X_TOUCH
		if _controller_button(controller, "by_button"):
			pressed_mask |= INPUT_Y_CLICK
		if _controller_button(controller, "by_touch"):
			touched_mask |= INPUT_Y_TOUCH
	else:
		if _controller_button(controller, "ax_button"):
			pressed_mask |= INPUT_A_CLICK
		if _controller_button(controller, "ax_touch"):
			touched_mask |= INPUT_A_TOUCH
		if _controller_button(controller, "by_button"):
			pressed_mask |= INPUT_B_CLICK
		if _controller_button(controller, "by_touch"):
			touched_mask |= INPUT_B_TOUCH

	var trackpad := _controller_vector2(controller, "secondary")
	if _controller_button(controller, "secondary_click"):
		available_mask |= INPUT_TRACKPAD_CLICK
		pressed_mask |= INPUT_TRACKPAD_CLICK
	if _controller_button(controller, "secondary_touch"):
		available_mask |= INPUT_TRACKPAD_TOUCH
		touched_mask |= INPUT_TRACKPAD_TOUCH
	if trackpad.length_squared() > 0.0001:
		available_mask |= INPUT_TRACKPAD_CLICK | INPUT_TRACKPAD_TOUCH

	return {
		"available_mask": available_mask,
		"pressed_mask": pressed_mask,
		"touched_mask": touched_mask,
		"trigger_value": _controller_float(controller, "trigger"),
		"grip_value": maxf(_controller_float(controller, "grip"), _controller_float(controller, "grip_force")),
		"thumbstick": _controller_vector2(controller, "primary"),
		"trackpad": trackpad
	}


func _write_controller_input_state(source: String, timestamp_ns: int, packet_type: int, state: Dictionary, changed_mask: int) -> bool:
	var ok: bool = bool(writer.write_controller_input(
		source,
		timestamp_ns,
		packet_type,
		int(state.get("available_mask", 0)),
		int(state.get("pressed_mask", 0)),
		int(state.get("touched_mask", 0)),
		changed_mask,
		float(state.get("trigger_value", 0.0)),
		float(state.get("grip_value", 0.0)),
		state.get("thumbstick", Vector2.ZERO) as Vector2,
		state.get("trackpad", Vector2.ZERO) as Vector2
	))
	if ok:
		_controller_input_count += 1
	return ok


func _analog_input_changed(previous: Dictionary, current: Dictionary) -> bool:
	if absf(float(previous.get("trigger_value", 0.0)) - float(current.get("trigger_value", 0.0))) > INPUT_ANALOG_EPSILON:
		return true
	if absf(float(previous.get("grip_value", 0.0)) - float(current.get("grip_value", 0.0))) > INPUT_ANALOG_EPSILON:
		return true
	var prev_thumb := previous.get("thumbstick", Vector2.ZERO) as Vector2
	var curr_thumb := current.get("thumbstick", Vector2.ZERO) as Vector2
	if prev_thumb.distance_to(curr_thumb) > INPUT_ANALOG_EPSILON:
		return true
	var prev_trackpad := previous.get("trackpad", Vector2.ZERO) as Vector2
	var curr_trackpad := current.get("trackpad", Vector2.ZERO) as Vector2
	return prev_trackpad.distance_to(curr_trackpad) > INPUT_ANALOG_EPSILON


func _controller_button(controller: XRController3D, action: String) -> bool:
	if controller == null or not controller.has_method("is_button_pressed"):
		return false
	return bool(controller.call("is_button_pressed", StringName(action)))


func _controller_float(controller: XRController3D, action: String) -> float:
	if controller == null or not controller.has_method("get_float"):
		return 0.0
	return clampf(float(controller.call("get_float", StringName(action))), 0.0, 1.0)


func _controller_vector2(controller: XRController3D, action: String) -> Vector2:
	if controller == null or not controller.has_method("get_vector2"):
		return Vector2.ZERO
	var raw: Variant = controller.call("get_vector2", StringName(action))
	if raw is Vector2:
		var value := raw as Vector2
		return Vector2(clampf(value.x, -1.0, 1.0), clampf(value.y, -1.0, 1.0))
	return Vector2.ZERO
