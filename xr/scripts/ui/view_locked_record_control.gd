extends OpenXRCompositionLayerQuad
class_name ViewLockedRecordControl

signal start_requested
signal stop_requested
signal settings_requested

const VIEWPORT_SIZE := Vector2i(250, 370)
const START_HOLD_SECONDS := 1.0
const STOP_HOLD_SECONDS := 0.75
const LONG_HOLD_SECONDS := 2.0
const PRIMARY_DIAMETER := 122.0
const SETTINGS_DIAMETER := 76.0
const NO_POINTER := Vector2(-1.0, -1.0)
const TARGET_GROUP := "operator_interaction_target"
const COL_ACCENT := Color(1.0, 0.647, 0.169, 0.98)
const COL_ACCENT_MUTED := Color(1.0, 0.647, 0.169, 0.78)

class HoldRing:
	extends Control

	var progress := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_progress(value: float) -> void:
		progress = clamp(value, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		var radius := (minf(size.x, size.y) * 0.5) - 5.0
		draw_arc(center, radius, 0.0, TAU, 72, Color(0.23, 0.27, 0.29, 0.32), 3.0, true)
		if progress > 0.0:
			draw_arc(
				center,
				radius,
				-PI * 0.5,
				(-PI * 0.5) + (TAU * progress),
				72,
				Color(1.0, 0.647, 0.169, 0.98),
				6.0,
				true
			)

var _viewport: SubViewport
var _primary_button: Button
var _settings_button: Button
var _timer_label: Label
var _upload_status_label: Label
var _primary_ring: HoldRing
var _settings_ring: HoldRing
var _cursor: Panel
var _mode := "controllers"
var _recording := false
var _hold_action := ""
var _hold_seconds := 0.0
var _suppress_primary_pressed := false
var _pointer_position := NO_POINTER
var _pointer_pressed := false
var _feedback_input_mode := "controllers"
var _feedback_controller: XRController3D
var interaction_priority := 40

func _init() -> void:
	add_to_group(TARGET_GROUP)
	# Aspect kept ~ viewport ratio (370/250 ≈ 1.48). Bumped from
	# 0.238 → 0.266 to make room for the upload status row.
	quad_size = Vector2(0.18, 0.266)
	alpha_blend = true
	sort_order = 3
	visible = false
	_build_viewport()

func _process(delta: float) -> void:
	if _hold_action.is_empty():
		return
	var required_seconds := _hold_duration(_hold_action)
	_hold_seconds = minf(_hold_seconds + delta, required_seconds)
	_set_hold_progress(_hold_seconds / required_seconds)
	if _hold_seconds < required_seconds:
		return
	var completed_action := _hold_action
	_cancel_hold()
	if completed_action == "stop":
		# 倒计时已完成，立即截断持续音，避免和 confirm 三连音重叠。
		_stop_feedback("stop_countdown")
	_play_feedback("confirm")
	match completed_action:
		"start":
			_suppress_primary_pressed = true
			emit_signal("start_requested")
		"stop":
			_suppress_primary_pressed = true
			emit_signal("stop_requested")
		"settings":
			emit_signal("settings_requested")

func show_for_mode(mode: String) -> void:
	_mode = mode
	_cancel_hold()
	visible = true
	_update_controls()

func hide_control() -> void:
	_cancel_hold()
	clear_pointer()
	visible = false

func set_recording(recording: bool) -> void:
	_recording = recording
	_cancel_hold()
	if recording:
		visible = true
	_update_controls()

func update_elapsed_seconds(seconds: float) -> void:
	if not _recording:
		return
	var total_seconds := int(seconds)
	_timer_label.text = "%02d:%02d" % [total_seconds / 60, total_seconds % 60]


# Show an upload progress / status message under the timer. Pass an
# empty string (or call clear_upload_status) to hide it. Color hints:
#   normal = blue, warning = amber, success = green, error = red.
func set_upload_status(text: String, level: String = "normal", _progress: float = -1.0) -> void:
	if _upload_status_label == null:
		return
	if text.is_empty():
		_upload_status_label.visible = false
		_upload_status_label.text = ""
		return
	_upload_status_label.text = text
	_upload_status_label.visible = true
	# Force visible even when not recording so the operator can watch
	# uploads drain after the recording stopped.
	visible = true
	var color := Color(0.55, 0.80, 0.98, 0.94)   # normal: cyan-blue
	match level:
		"success":
			color = Color(0.30, 0.88, 0.64, 0.96)
		"warning":
			color = Color(1.00, 0.78, 0.36, 0.96)
		"error":
			color = Color(1.00, 0.46, 0.42, 0.98)
	_upload_status_label.add_theme_color_override("font_color", color)


func clear_upload_status() -> void:
	set_upload_status("", "normal")

func update_pointer_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	var uv: Vector2 = intersects_ray(ray_origin, ray_direction)
	if uv.x < 0.0 or uv.y < 0.0:
		clear_pointer()
		return false
	var next_position := Vector2(uv.x * VIEWPORT_SIZE.x, uv.y * VIEWPORT_SIZE.y)
	if next_position != _pointer_position:
		var motion := InputEventMouseMotion.new()
		motion.position = next_position
		motion.global_position = next_position
		_viewport.push_input(motion)
	_pointer_position = next_position
	_cursor.position = next_position - (_cursor.size * 0.5)
	_cursor.visible = true
	return true

func set_pointer_pressed(pressed: bool) -> void:
	if pressed == _pointer_pressed:
		return
	if pressed and _pointer_position == NO_POINTER:
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


func clear_pointer() -> void:
	if _pointer_pressed:
		set_pointer_pressed(false)
	_pointer_position = NO_POINTER
	_cursor.visible = false


func get_interaction_priority() -> int:
	return interaction_priority


func is_interaction_target_visible() -> bool:
	return is_inside_tree() and visible


func get_ray_hit_point(ray_origin: Vector3, ray_direction: Vector3) -> Vector3:
	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		return ray_origin
	var normal := global_transform.basis.z.normalized()
	var denominator := normal.dot(direction)
	if absf(denominator) < 0.0001:
		return ray_origin + direction * 0.25
	var distance_m := normal.dot(global_transform.origin - ray_origin) / denominator
	return ray_origin + direction * maxf(distance_m, 0.001)


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "RecordControlViewport"
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	layer_viewport = _viewport

	var content := VBoxContainer.new()
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 10)
	_viewport.add_child(content)

	_timer_label = Label.new()
	_timer_label.text = "00:00"
	_timer_label.visible = false
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.custom_minimum_size = Vector2(VIEWPORT_SIZE.x, 38.0)
	_timer_label.add_theme_font_size_override("font_size", 32)
	_timer_label.add_theme_color_override("font_color", COL_ACCENT)
	content.add_child(_timer_label)

	# Upload status line — hidden until EgoUploader emits its first signal.
	# Driven from capture_app.gd via set_upload_status() / clear_upload_status().
	_upload_status_label = Label.new()
	_upload_status_label.text = ""
	_upload_status_label.visible = false
	_upload_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_upload_status_label.custom_minimum_size = Vector2(VIEWPORT_SIZE.x, 22.0)
	_upload_status_label.add_theme_font_size_override("font_size", 16)
	_upload_status_label.add_theme_color_override("font_color", Color(0.55, 0.80, 0.98, 0.92))
	_upload_status_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	content.add_child(_upload_status_label)

	var primary_slot := _make_slot(PRIMARY_DIAMETER)
	content.add_child(primary_slot)
	_primary_button = _make_circle_button(primary_slot, PRIMARY_DIAMETER, tr("UI_START"), 20)
	_primary_button.button_down.connect(_on_primary_button_down)
	_primary_button.button_up.connect(_on_primary_button_up)
	_primary_button.mouse_entered.connect(_on_primary_mouse_entered)
	_primary_button.mouse_exited.connect(_on_primary_mouse_exited)
	_primary_button.pressed.connect(_on_primary_pressed)
	_primary_ring = _make_ring(primary_slot, PRIMARY_DIAMETER)

	var settings_slot := _make_slot(SETTINGS_DIAMETER)
	content.add_child(settings_slot)
	_settings_button = _make_circle_button(settings_slot, SETTINGS_DIAMETER, tr("UI_SET"), 16)
	_settings_button.button_down.connect(_on_settings_button_down)
	_settings_button.button_up.connect(_on_settings_button_up)
	_settings_button.mouse_entered.connect(_on_settings_mouse_entered)
	_settings_button.mouse_exited.connect(_on_settings_mouse_exited)
	_settings_button.pressed.connect(_on_settings_pressed)
	_settings_ring = _make_ring(settings_slot, SETTINGS_DIAMETER)

	_cursor = Panel.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.size = Vector2(10.0, 10.0)
	var cursor_style := StyleBoxFlat.new()
	cursor_style.bg_color = COL_ACCENT_MUTED
	cursor_style.set_corner_radius_all(5)
	_cursor.add_theme_stylebox_override("panel", cursor_style)
	_viewport.add_child(_cursor)

func _make_slot(diameter: float) -> Control:
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(VIEWPORT_SIZE.x, diameter + 12.0)
	return slot

func _make_circle_button(slot: Control, diameter: float, text: String, font_size: int) -> Button:
	var button := Button.new()
	button.text = text
	button.position = Vector2((VIEWPORT_SIZE.x - diameter) * 0.5, 6.0)
	button.size = Vector2(diameter, diameter)
	button.custom_minimum_size = Vector2(diameter, diameter)
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_color_override("font_color", Color(0.94, 0.96, 0.96, 0.92))
	button.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0, 1.0))
	button.add_theme_color_override("font_pressed_color", Color(1.0, 1.0, 1.0, 1.0))
	button.add_theme_stylebox_override("normal", _circle_style(diameter, Color(0.06, 0.08, 0.09, 0.46)))
	button.add_theme_stylebox_override("hover", _circle_style(diameter, Color(0.08, 0.11, 0.12, 0.64)))
	button.add_theme_stylebox_override("pressed", _circle_style(diameter, Color(0.10, 0.14, 0.15, 0.78)))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# NOTE: hover 音效由调用方在 _build_viewport 中显式连接，方便针对
	# 录制中的 stop 按钮抑制 hover 反馈。
	slot.add_child(button)
	return button

func _circle_style(diameter: float, color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color(0.28, 0.33, 0.34, 0.48)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(diameter * 0.5))
	return style

func _make_ring(slot: Control, diameter: float) -> HoldRing:
	var ring := HoldRing.new()
	ring.position = Vector2((VIEWPORT_SIZE.x - diameter) * 0.5 - 6.0, 0.0)
	ring.size = Vector2(diameter + 12.0, diameter + 12.0)
	slot.add_child(ring)
	return ring

func _update_controls() -> void:
	_timer_label.visible = _recording
	_settings_button.get_parent().visible = not _recording
	_primary_button.get_parent().visible = _mode != "head"
	_primary_button.text = tr("UI_STOP") if _recording else tr("UI_START")
	if _primary_ring != null:
		_primary_ring.visible = _recording and _mode != "head"
	if _settings_ring != null:
		_settings_ring.visible = false

func _requires_hold(action: String) -> bool:
	return action == "stop"

func _hold_duration(action: String) -> float:
	match action:
		"start":
			return START_HOLD_SECONDS
		"stop":
			return STOP_HOLD_SECONDS
	return LONG_HOLD_SECONDS

func _begin_hold(action: String) -> void:
	_cancel_hold()
	_hold_action = action
	_hold_seconds = 0.0
	_set_hold_progress(0.0)

func _cancel_hold() -> void:
	_hold_action = ""
	_hold_seconds = 0.0
	if _primary_ring:
		_primary_ring.set_progress(0.0)
	if _settings_ring:
		_settings_ring.set_progress(0.0)

func _set_hold_progress(progress: float) -> void:
	if _hold_action == "settings":
		_settings_ring.set_progress(progress)
	else:
		_primary_ring.set_progress(progress)

func _on_primary_button_down() -> void:
	if _suppress_primary_pressed:
		_suppress_primary_pressed = false
	var action := "stop" if _recording else "start"
	if _requires_hold(action):
		# 仅在用户真正按住停止采集时，播放与按住时长同步的持续倒计时音效。
		_play_feedback("stop_countdown", -4.0)
		_begin_hold(action)

func _on_primary_button_up() -> void:
	if _hold_action == "stop":
		_cancel_hold()
		_stop_feedback("stop_countdown")

func _on_primary_mouse_entered() -> void:
	# 录制中（射线 hover 到 stop button）时不播 hover 音；
	# 只有按住才播 stop_countdown 倒计时反馈。
	if _recording:
		return
	_play_feedback("hover", -5.0)

func _on_primary_mouse_exited() -> void:
	if _hold_action == "stop":
		_cancel_hold()
		_stop_feedback("stop_countdown")

func _on_primary_pressed() -> void:
	if _suppress_primary_pressed:
		_suppress_primary_pressed = false
		return
	if not _recording and not _requires_hold("start"):
		_play_feedback("click")
		emit_signal("start_requested")

func _on_settings_button_down() -> void:
	if not _recording and _requires_hold("settings"):
		_play_feedback("exit_charging", -4.0)
		_begin_hold("settings")

func _on_settings_button_up() -> void:
	if _hold_action == "settings":
		_cancel_hold()

func _on_settings_mouse_entered() -> void:
	_play_feedback("hover", -5.0)

func _on_settings_mouse_exited() -> void:
	if _hold_action == "settings":
		_cancel_hold()

func _on_settings_pressed() -> void:
	if not _recording and not _requires_hold("settings"):
		_play_feedback("click")
		emit_signal("settings_requested")


func _play_feedback(action: String, volume_db: float = 0.0) -> void:
	if _feedback_input_mode == "hands":
		var sound_bus := _get_ui_sound_bus()
		if sound_bus != null and sound_bus.has_method("play"):
			sound_bus.call("play", action, volume_db)
	elif _feedback_input_mode == "controllers":
		var haptics := _get_haptics_bus()
		var use_haptics := _feedback_controller != null
		if haptics != null and haptics.has_method("should_use_controller_feedback"):
			use_haptics = bool(haptics.call("should_use_controller_feedback", _feedback_controller))
		if use_haptics and haptics != null and haptics.has_method("fire_ui_event"):
			haptics.call("fire_ui_event", action, _feedback_controller)
		else:
			var sound_bus := _get_ui_sound_bus()
			if sound_bus != null and sound_bus.has_method("play"):
				sound_bus.call("play", action, volume_db)


func _stop_feedback(action: String) -> void:
	# 提前松开/移开时，立即中止持续型音效（如 stop_countdown）。
	var sound_bus := _get_ui_sound_bus()
	if sound_bus != null and sound_bus.has_method("stop"):
		sound_bus.call("stop", action)


func _get_ui_sound_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("UISoundBus")


func _get_haptics_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Haptics")
