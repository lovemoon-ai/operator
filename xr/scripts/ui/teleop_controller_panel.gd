extends "res://scripts/ui/composition_viewport_ui.gd"
class_name TeleopControllerPanel

const VIEWPORT_SIZE := Vector2i(540, 248)
const QUAD_SIZE_M := Vector2(0.245, 0.112)
const GRIP_ACTIVE_THRESHOLD := 0.5
const GRIP_RELEASE_GRACE_MSEC := 100

const COL_BG := Color(0.055, 0.067, 0.08, 0.88)
const COL_BORDER := Color(0.18, 0.22, 0.26, 0.95)
const COL_TEXT := Color(0.76, 0.80, 0.84, 1.0)
const COL_KEY := Color(1.0, 0.647, 0.169, 0.96)
const COL_ACTIVE := Color(0.14, 0.82, 0.45, 1.0)
const COL_WAITING := Color(1.0, 0.72, 0.18, 1.0)
const COL_DISCONNECTED := Color(0.43, 0.46, 0.50, 1.0)

var _enabled_for_device := false
var _bridge_connected := false
var _grip_pressed := false
var _grip_hold_until_msec := 0

var _lamp: Panel
var _status_label: Label


func _init() -> void:
	var viewport := _setup_viewport_layer("TeleopControllerPanelViewport", VIEWPORT_SIZE, QUAD_SIZE_M, 4, 1.0)
	_build_panel(viewport)
	visible = false


func configure_for_device(descriptor: Dictionary) -> void:
	_enabled_for_device = _has_controller_teleop_mapping(descriptor)
	visible = _enabled_for_device
	_refresh()


func set_bridge_connected(connected: bool) -> void:
	if _bridge_connected == connected:
		return
	_bridge_connected = connected
	_refresh()


func set_grip_value(value: float) -> void:
	var now_msec := Time.get_ticks_msec()
	if value >= GRIP_ACTIVE_THRESHOLD:
		_grip_hold_until_msec = now_msec + GRIP_RELEASE_GRACE_MSEC
	var pressed := now_msec <= _grip_hold_until_msec
	if _grip_pressed == pressed:
		return
	_grip_pressed = pressed
	_refresh()


func _build_panel(viewport: SubViewport) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _panel_style())
	viewport.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 10)
	content.add_child(status_row)

	_lamp = Panel.new()
	_lamp.custom_minimum_size = Vector2(24, 24)
	status_row.add_child(_lamp)

	_status_label = Label.new()
	_status_label.text = tr("UI_TELEOP_WAITING")
	_status_label.add_theme_font_size_override("font_size", 24)
	_status_label.add_theme_color_override("font_color", COL_WAITING)
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)

	content.add_child(_hint_row("GRIP", tr("UI_TELEOP_GRIP_HINT")))
	content.add_child(_hint_row("TRIGGER", tr("UI_TELEOP_TRIGGER_HINT")))
	_refresh()


func _hint_row(key_text: String, hint_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var key := Label.new()
	key.text = key_text
	key.custom_minimum_size = Vector2(118, 30)
	key.add_theme_font_size_override("font_size", 22)
	key.add_theme_color_override("font_color", COL_KEY)
	key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(key)

	var hint := Label.new()
	hint.text = hint_text
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", COL_TEXT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(hint)

	return row


func _refresh() -> void:
	if not _enabled_for_device:
		visible = false
		return

	if not _bridge_connected:
		_set_status(tr("UI_TELEOP_DISCONNECTED"), COL_DISCONNECTED)
	elif _grip_pressed:
		_set_status(tr("UI_TELEOP_ACTIVE"), COL_ACTIVE)
	else:
		_set_status(tr("UI_TELEOP_WAITING"), COL_WAITING)


func _set_status(text: String, color: Color) -> void:
	if _status_label:
		_status_label.text = text
		_status_label.add_theme_color_override("font_color", color)
	if _lamp:
		_lamp.add_theme_stylebox_override("panel", _lamp_style(color))


func _has_controller_teleop_mapping(descriptor: Dictionary) -> bool:
	var has_enable_button := false
	var schema: Dictionary = descriptor.get("control_schema", {})
	for button_def in schema.get("buttons", []):
		if button_def is Dictionary and String(button_def.get("name", "")) == "enable":
			has_enable_button = true
			break
	if not has_enable_button:
		return false

	var has_enable_mapping := false
	for mapping in descriptor.get("input_mapping", []):
		if not mapping is Dictionary:
			continue
		if String(mapping.get("target", "")) == "enable":
			has_enable_mapping = true
			break
	return has_enable_mapping


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_BG
	style.border_color = COL_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	return style


func _lamp_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color(color.r, color.g, color.b, 0.42)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	return style
