extends Control

signal teleop_selected
signal ego_selected

const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_MUTED := Color(0.65, 0.70, 0.75)
const COL_ACCENT := Color(0.20, 0.86, 1.0, 0.98)

var _status_label: Label


func _ready() -> void:
	_build_ui()


func set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 38)
	margin.add_theme_constant_override("margin_right", 38)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	margin.add_child(content)

	var title := Label.new()
	title.text = "选择模式"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", COL_TITLE)
	content.add_child(title)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 18)
	buttons.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(buttons)

	var teleop_button := _mode_button("遥操模式")
	teleop_button.pressed.connect(func(): teleop_selected.emit())
	buttons.add_child(teleop_button)

	var ego_button := _mode_button("Ego 模式")
	ego_button.pressed.connect(func(): ego_selected.emit())
	buttons.add_child(ego_button)

	_status_label = Label.new()
	_status_label.text = "Operator"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 20)
	_status_label.add_theme_color_override("font_color", COL_MUTED)
	content.add_child(_status_label)


func _mode_button(label: String) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(250, 156)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.size_flags_vertical = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 32)
	button.add_theme_color_override("font_color", COL_TITLE)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_stylebox_override("normal", _button_style(false))
	button.add_theme_stylebox_override("hover", _button_style(true))
	button.add_theme_stylebox_override("pressed", _button_style(true))
	button.add_theme_stylebox_override("focus", _button_style(true))
	return button


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL_BG
	style.border_color = COL_PANEL_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	return style


func _button_style(highlighted: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.12, 0.14, 0.92)
	style.border_color = COL_ACCENT if highlighted else Color(0.24, 0.28, 0.32, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	return style
