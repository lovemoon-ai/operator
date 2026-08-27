extends "res://scripts/ui/composition_viewport_ui.gd"
class_name VideoPanelSidecar

signal reset_requested

const RESET_ICON := preload("res://assets/icons/reset.svg")
const VIEWPORT_SIZE := Vector2i(1280, 180)
const PANEL_SIZE := Vector2(3.2, 0.45)
const COL_BACKGROUND := Color(0.025, 0.032, 0.040, 0.94)
const COL_BORDER := Color(1.0, 0.647, 0.169, 0.92)
const COL_TEXT := Color(0.94, 0.96, 0.98, 1.0)

var _performance_label: Label
var _reset_button: Button


func _init() -> void:
	interaction_priority = 60
	var viewport := _setup_viewport_layer(
		"VideoPanelSidecarViewport", VIEWPORT_SIZE, PANEL_SIZE, 3, 16.0
	)
	_build_content(viewport)
	# CompositionViewportUI creates the pointer before panel content. Keep it
	# above the opaque sidecar background so Reset remains easy to target.
	if _cursor != null:
		_cursor.move_to_front()
	visible = false


func set_performance_text(text: String) -> void:
	if _performance_label == null:
		return
	_performance_label.text = text.replace("\n", "    ")


func captures_teleop_input() -> bool:
	return true


func scroll_by_pixels(delta_pixels: float) -> void:
	var host := get_parent()
	if host != null and host.has_method("adjust_panel_distance_from_scroll"):
		host.call("adjust_panel_distance_from_scroll", delta_pixels)


func _build_content(viewport: SubViewport) -> void:
	var background := PanelContainer.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.add_theme_stylebox_override("panel", _panel_style())
	viewport.add_child(background)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 18)
	background.add_child(margin)

	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	margin.add_child(content)

	var performance_background := PanelContainer.new()
	performance_background.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	performance_background.size_flags_vertical = Control.SIZE_EXPAND_FILL
	performance_background.add_theme_stylebox_override(
		"panel", _performance_style()
	)
	content.add_child(performance_background)

	var performance_margin := MarginContainer.new()
	performance_margin.add_theme_constant_override("margin_left", 18)
	performance_margin.add_theme_constant_override("margin_top", 16)
	performance_margin.add_theme_constant_override("margin_right", 18)
	performance_margin.add_theme_constant_override("margin_bottom", 16)
	performance_background.add_child(performance_margin)

	_performance_label = _make_performance_label()
	_performance_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	performance_margin.add_child(_performance_label)

	var reset_container := CenterContainer.new()
	reset_container.custom_minimum_size.x = 104
	reset_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(reset_container)

	_reset_button = Button.new()
	_reset_button.text = ""
	_reset_button.icon = RESET_ICON
	_reset_button.expand_icon = true
	_reset_button.icon_max_width = 48
	_reset_button.tooltip_text = tr("UI_VIDEO_RESET_POSITION")
	_reset_button.focus_mode = Control.FOCUS_NONE
	_reset_button.custom_minimum_size = Vector2(92, 92)
	_reset_button.add_theme_stylebox_override(
		"normal", _button_style(Color(0.10, 0.12, 0.14, 0.98))
	)
	_reset_button.add_theme_stylebox_override(
		"hover", _button_style(Color(0.16, 0.18, 0.20, 1.0))
	)
	_reset_button.add_theme_stylebox_override(
		"pressed", _button_style(Color(0.22, 0.20, 0.14, 1.0))
	)
	_reset_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_reset_button.mouse_entered.connect(func() -> void: _play_feedback("hover", -5.0, self))
	_reset_button.pressed.connect(_on_reset_pressed)
	reset_container.add_child(_reset_button)


func _make_performance_label() -> Label:
	var label := Label.new()
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.add_theme_font_size_override("font_size", 28)
	label.add_theme_color_override("font_color", COL_TEXT)
	return label


func _on_reset_pressed() -> void:
	_play_feedback("click", 0.0, self)
	reset_requested.emit()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_BACKGROUND
	style.border_color = COL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(18)
	return style


func _button_style(background: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = COL_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	return style


func _performance_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.72)
	style.border_color = Color(1.0, 1.0, 1.0, 0.12)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	return style
