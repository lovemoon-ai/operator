extends Node
class_name PoseSampler

# Per-category JSONL write throttles. Head still goes to the mp4 `mett` stream
# every sample() call (cheap JNI Enqueue), but the GDScript-side JSONL writes
# are far more expensive (Dictionary build + JSON.stringify +
# FileAccess.store_line per record). Capping them at ~30 Hz / 60 Hz keeps the
# main thread fast enough for 72 Hz UI rendering without losing meaningful
# offline-analysis fidelity for controllers.
#
# Hands are NOT sampled in GDScript at all: the hand_capture GDExtension
# owns the entire hand pipeline in C++. NativeOpenXRHandCapture writes MP4
# HJNT and the optional hands.jsonl on an independent 60 Hz clock;
# NativeHandSampler keeps only live push render-driven and off GDScript. Hand capture
# therefore requires the extension (Android arm64); there is no hand-tracking
# runtime in the desktop editor anyway.
const HEAD_JSONL_INTERVAL_US := 16667        # 60 Hz
const CONTROLLER_JSONL_INTERVAL_US := 33333  # 30 Hz
# Controller-input capture is event-driven: XRController3D's button/float/
# vector2 signals (connected in configure) call _sample_controller_input the
# moment anything changes. The periodic poll below is only a snapshot
# fallback for missed edges, so it runs at 10 Hz instead of the old
# unconditional 90 Hz sweep (~20 button reads + a state Dictionary per
# controller per call — ~3,600 engine polls/s saved on the main thread).
const CONTROLLER_INPUT_SNAPSHOT_INTERVAL_US := 100000  # 10 Hz
const NATIVE_HAND_SAMPLER_CLASS := &"NativeHandSampler"
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
# WP4: canonical-frame sink. Samples are emitted as SensorFrames and routed
# through this sink (default: FrameWriterShim bound to `writer`, which calls
# the legacy writer methods with identical args). Injectable for tests/WP5.
var _frame_sink: Object
var hmd_camera: XRCamera3D
var xr_origin: XROrigin3D
var left_controller: XRController3D
var right_controller: XRController3D
var _record_head_pose := true
var _record_controller_pose := true
var _record_controller_input := true
var _record_hand_data := true
var _last_head_jsonl_us := 0
var _last_controller_jsonl_us := 0
var _last_controller_input_poll_us := 0
var _xr_display_time_provider: Object
var _capture_provider: Object
var _platform: Object
var _xr_display_time_supported := true
var _xr_time_offset_ns := 0
var _xr_time_offset_resolved := false
# 1Hz metrics surface: capture_app's metrics ticker reads-and-resets these
# so the per-sub-system rates align on the same wall-clock second.
var _sample_count := 0
var _head_count := 0
var _controller_count := 0
var _controller_input_count := 0
var _controller_input_states := {}
# hand_capture GDExtension instance (NativeHandSampler) — the only hand
# capture path (full XR frame rate, all serialization in C++). Null when the
# extension is absent, in which case hands are not recorded.
var _native_hand_sampler: Object = null
var _native_hand_warned := false
var _last_capture_options := {}
var _coordinate_space := OpenXRExportSpace.coordinate_space_id(OpenXRExportSpace.DEFAULT)


func pop_metrics() -> Dictionary:
	var metrics := {
		"samples": _sample_count,
		"head_writes": _head_count,
		"controller_writes": _controller_count,
		"controller_input_writes": _controller_input_count,
		"hand_writes": 0,
		"hand_joints": 0
	}
	if _native_hand_sampler != null:
		var native: Dictionary = _native_hand_sampler.pop_metrics()
		metrics["hand_writes"] = int(native.get("hand_writes", 0))
		metrics["hand_joints"] = int(native.get("hand_joints", 0))
		metrics["hand_live_writes"] = int(native.get("live_writes", 0))
		metrics["hand_jsonl_lines"] = int(native.get("jsonl_lines", 0))
		metrics["hand_jsonl_dropped"] = int(native.get("jsonl_dropped", 0))
	_sample_count = 0
	_head_count = 0
	_controller_count = 0
	_controller_input_count = 0
	return metrics


func configure(
	p_writer: Object,
	p_hmd_camera: XRCamera3D,
	p_left_controller: XRController3D,
	p_right_controller: XRController3D,
	p_capture_provider: Object = null,
	p_platform: Object = null
) -> void:
	writer = p_writer
	_frame_sink = FrameWriterShim.new(writer) if writer != null else null
	hmd_camera = p_hmd_camera
	xr_origin = null
	if hmd_camera != null and hmd_camera.get_parent() is XROrigin3D:
		xr_origin = hmd_camera.get_parent() as XROrigin3D
	left_controller = p_left_controller
	right_controller = p_right_controller
	_capture_provider = p_capture_provider
	# WP2: vendor singleton probing moved to the platform layer. An injected
	# platform object (PlatformRegistry-compatible) is preferred; the shared
	# registry preserves the legacy default behavior.
	_platform = p_platform if p_platform != null else PlatformRegistry.shared()
	_connect_controller_input_signals(left_controller, "left_controller")
	_connect_controller_input_signals(right_controller, "right_controller")
	_xr_display_time_provider = _platform.depth_time_extension()
	_xr_display_time_supported = true


func set_frame_sink(sink: Object) -> void:
	_frame_sink = sink


## Wires the native hand pipeline (hand_capture GDExtension) to this mode's
## write targets. Call after configure(). Ego capture passes the muxer
## plugin; live modes pass the live server plugin (writeHandJointsJson wire,
## rate-limited in C++ to the legacy 30 Hz network cadence). Either may be
## null. Returns true when the native sampler is active.
func enable_native_hand_capture(muxer_plugin: Object, live_plugin: Object = null) -> bool:
	if muxer_plugin == null and live_plugin == null:
		return false
	if not ClassDB.class_exists(NATIVE_HAND_SAMPLER_CLASS):
		if _record_hand_data and not _native_hand_warned:
			_native_hand_warned = true
			push_warning("hand_capture GDExtension missing — hand joints will not be recorded")
		return false
	if _native_hand_sampler == null:
		_native_hand_sampler = ClassDB.instantiate(NATIVE_HAND_SAMPLER_CLASS)
	if _native_hand_sampler == null:
		return false
	_native_hand_sampler.configure(muxer_plugin, live_plugin, xr_origin)
	return true


func has_native_hand_capture() -> bool:
	return _native_hand_sampler != null


## The shared Quest/PICO OpenXR worker writes the MP4 hand tracks at 60 Hz.
## Keep this render-driven sampler alive for live JSON,
## but do not let it duplicate packets into the same MP4 tracks.
func set_native_hand_muxer_writes_enabled(enabled: bool) -> void:
	if _native_hand_sampler != null and _native_hand_sampler.has_method("set_muxer_writes_enabled"):
		_native_hand_sampler.set_muxer_writes_enabled(enabled)


## Live/fallback lifecycle for the native hands.jsonl sidecar. Ego recording
## delegates it to NativeOpenXRHandCapture so the sidecar shares the same
## independent 60 Hz clock as the MP4 hand tracks.
func on_session_started(session_dir: String, defer_hand_jsonl_to_openxr_worker := false) -> void:
	if _native_hand_sampler == null or session_dir.is_empty():
		return
	if defer_hand_jsonl_to_openxr_worker:
		_native_hand_sampler.end_jsonl()
		return
	if not bool(_last_capture_options.get("save_controller_hand_sidecar", false)):
		return
	if not bool(_last_capture_options.get("record_hand_data", true)):
		return
	_native_hand_sampler.begin_jsonl(
		ProjectSettings.globalize_path(session_dir.path_join(SessionLayout.HANDS_JSONL)))


func on_session_stopped() -> void:
	if _native_hand_sampler != null:
		_native_hand_sampler.end_jsonl()


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
	if plugin == null and _platform != null:
		plugin = _platform.fallback_capture_provider()
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
	_coordinate_space = OpenXRExportSpace.coordinate_space_id(
		options.get("export_coordinate_space", OpenXRExportSpace.DEFAULT))
	_last_capture_options = options.duplicate(true)
	_controller_input_states.clear()


func sample(timestamp_ns: int) -> void:
	if _frame_sink == null:
		return

	_sample_count += 1
	var resolved_ts := resolve_pose_timestamp_ns(timestamp_ns)
	var now_us := Time.get_ticks_usec()

	if _record_head_pose and hmd_camera:
		# mp4 mett stream gets every sample (cheap JNI). JSONL is throttled
		# so GDScript JSON.stringify does not dominate the main thread.
		var head_pose := _head_openxr_pose()
		if head_pose != null:
			var head_jsonl: bool = (now_us - _last_head_jsonl_us) >= HEAD_JSONL_INTERVAL_US
			_frame_sink.on_frame(PoseFrame.build(
				resolved_ts,
				head_pose.get_transform(),
				head_pose.get_has_tracking_data(),
				head_jsonl,
				_coordinate_space
			))
			_head_count += 1
			if head_jsonl:
				_last_head_jsonl_us = now_us

	var controller_jsonl: bool = (now_us - _last_controller_jsonl_us) >= CONTROLLER_JSONL_INTERVAL_US
	if _record_controller_pose and left_controller and controller_jsonl:
		var left_pose := left_controller.get_pose()
		if left_pose != null:
			_frame_sink.on_frame(ControllerFrame.build_pose(
				"left_controller",
				resolved_ts,
				left_pose.get_transform(),
				left_pose.get_has_tracking_data(),
				_coordinate_space
			))
			_controller_count += 1

	if _record_controller_pose and right_controller and controller_jsonl:
		var right_pose := right_controller.get_pose()
		if right_pose != null:
			_frame_sink.on_frame(ControllerFrame.build_pose(
				"right_controller",
				resolved_ts,
				right_pose.get_transform(),
				right_pose.get_has_tracking_data(),
				_coordinate_space
			))
			_controller_count += 1
	if controller_jsonl and _record_controller_pose:
		_last_controller_jsonl_us = now_us

	# Event path (signals) carries input changes immediately; this is only
	# the low-rate snapshot fallback for anything the signals missed.
	if _record_controller_input \
			and (now_us - _last_controller_input_poll_us) >= CONTROLLER_INPUT_SNAPSHOT_INTERVAL_US:
		_last_controller_input_poll_us = now_us
		if left_controller:
			_sample_controller_input("left_controller", left_controller, resolved_ts)
		if right_controller:
			_sample_controller_input("right_controller", right_controller, resolved_ts)

	if _record_hand_data and _native_hand_sampler != null:
		# Render-driven live/fallback capture in C++. MP4 and ego-sidecar writes on this sampler
		# are disabled while the independent 60 Hz OpenXR recorder is active.
		# NativeHandSampler dedupes extra pose-loop iterations per process frame.
		_native_hand_sampler.sample(resolved_ts)


## XRCamera3D applies XRPose.get_adjusted_transform() to its Node3D transform,
## which includes XRServer.reference_frame and world_scale. Recording needs the
## unadjusted pose: Godot's OpenXR backend populated it from
## xrLocateSpace(VIEW, play_space, predictedDisplayTime).
func _head_openxr_pose() -> XRPose:
	var tracker := XRServer.get_tracker(&"head") as XRPositionalTracker
	if tracker == null or not tracker.has_pose(&"default"):
		return null
	return tracker.get_pose(&"default")


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
	if _frame_sink == null or not _record_controller_input:
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
	var ok: bool = bool(_frame_sink.on_frame(
		ControllerFrame.build_input(source, timestamp_ns, packet_type, state, changed_mask)
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
