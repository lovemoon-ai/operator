extends OpenXRCompositionLayerQuad
class_name ViewLockedRecordControl

signal start_requested
signal stop_requested
signal settings_requested

const VIEWPORT_SIZE := Vector2i(250, 330)
const START_HOLD_SECONDS := 1.0
const LONG_HOLD_SECONDS := 2.0
const PRIMARY_DIAMETER := 122.0
const SETTINGS_DIAMETER := 76.0
const NO_POINTER := Vector2(-1.0, -1.0)

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
				Color(0.18, 0.88, 1.0, 0.98),
				6.0,
				true
			)

var _viewport: SubViewport
var _primary_button: Button
var _settings_button: Button
var _timer_label: Label
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

func _init() -> void:
	quad_size = Vector2(0.18, 0.238)
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

func clear_pointer() -> void:
	if _pointer_pressed:
		set_pointer_pressed(false)
	_pointer_position = NO_POINTER
	_cursor.visible = false

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
	_timer_label.add_theme_color_override("font_color", Color(0.30, 0.88, 0.64, 0.94))
	content.add_child(_timer_label)

	var primary_slot := _make_slot(PRIMARY_DIAMETER)
	content.add_child(primary_slot)
	_primary_button = _make_circle_button(primary_slot, PRIMARY_DIAMETER, "START", 20)
	_primary_button.button_down.connect(_on_primary_button_down)
	_primary_button.button_up.connect(_on_primary_button_up)
	_primary_button.mouse_exited.connect(_on_primary_mouse_exited)
	_primary_button.pressed.connect(_on_primary_pressed)
	_primary_ring = _make_ring(primary_slot, PRIMARY_DIAMETER)

	var settings_slot := _make_slot(SETTINGS_DIAMETER)
	content.add_child(settings_slot)
	_settings_button = _make_circle_button(settings_slot, SETTINGS_DIAMETER, "SET", 16)
	_settings_button.button_down.connect(_on_settings_button_down)
	_settings_button.button_up.connect(_on_settings_button_up)
	_settings_button.mouse_exited.connect(_on_settings_mouse_exited)
	_settings_button.pressed.connect(_on_settings_pressed)
	_settings_ring = _make_ring(settings_slot, SETTINGS_DIAMETER)

	_cursor = Panel.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.size = Vector2(10.0, 10.0)
	var cursor_style := StyleBoxFlat.new()
	cursor_style.bg_color = Color(0.20, 0.86, 1.0, 0.78)
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
	_primary_button.text = "STOP" if _recording else "START"

func _requires_hold(action: String) -> bool:
	return action == "start" or action == "stop" or (action == "settings" and _mode == "hands")

func _hold_duration(action: String) -> float:
	return START_HOLD_SECONDS if action == "start" else LONG_HOLD_SECONDS

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
		_begin_hold(action)

func _on_primary_button_up() -> void:
	if _hold_action == "start" or _hold_action == "stop":
		_cancel_hold()

func _on_primary_mouse_exited() -> void:
	if _hold_action == "start" or _hold_action == "stop":
		_cancel_hold()

func _on_primary_pressed() -> void:
	if _suppress_primary_pressed:
		_suppress_primary_pressed = false
		return
	if not _recording and not _requires_hold("start"):
		emit_signal("start_requested")

func _on_settings_button_down() -> void:
	if not _recording and _requires_hold("settings"):
		_begin_hold("settings")

func _on_settings_button_up() -> void:
	if _hold_action == "settings":
		_cancel_hold()

func _on_settings_mouse_exited() -> void:
	if _hold_action == "settings":
		_cancel_hold()

func _on_settings_pressed() -> void:
	if not _recording and not _requires_hold("settings"):
		emit_signal("settings_requested")
