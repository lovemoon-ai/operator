extends "res://scripts/ui/composition_viewport_ui.gd"
class_name SettingsLauncherButton

signal pressed

const VIEWPORT_SIZE := Vector2i(160, 160)
const BUTTON_DIAMETER := 132.0

var _button: Button


func _init() -> void:
	interaction_priority = 30
	var viewport := _setup_viewport_layer("SettingsButtonViewport", VIEWPORT_SIZE, Vector2(0.08, 0.08), 3, 10.0)
	_build_button(viewport)
	visible = false


func _build_button(viewport: SubViewport) -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(root)

	_button = Button.new()
	_button.text = "⚙"
	_button.position = Vector2((VIEWPORT_SIZE.x - BUTTON_DIAMETER) * 0.5, (VIEWPORT_SIZE.y - BUTTON_DIAMETER) * 0.5)
	_button.size = Vector2(BUTTON_DIAMETER, BUTTON_DIAMETER)
	_button.custom_minimum_size = Vector2(BUTTON_DIAMETER, BUTTON_DIAMETER)
	_button.add_theme_font_size_override("font_size", 64)
	_button.add_theme_color_override("font_color", COL_ACCENT)
	_button.add_theme_color_override("font_hover_color", Color(1.0, 0.78, 0.38, 1.0))
	_button.add_theme_color_override("font_pressed_color", Color(1.0, 0.78, 0.38, 1.0))
	_button.add_theme_stylebox_override("normal", _button_style(Color(0.055, 0.067, 0.08, 0.86)))
	_button.add_theme_stylebox_override("hover", _button_style(Color(0.075, 0.088, 0.10, 0.92)))
	_button.add_theme_stylebox_override("pressed", _button_style(Color(0.095, 0.112, 0.13, 0.98)))
	_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_button.mouse_entered.connect(func() -> void: _play_feedback("hover", -5.0, self))
	_button.pressed.connect(_on_pressed)
	root.add_child(_button)


func _button_style(bg_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.border_color = Color(1.0, 0.647, 0.169, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(int(BUTTON_DIAMETER * 0.5))
	return style


func _on_pressed() -> void:
	_play_feedback("click", 0.0, self)
	pressed.emit()
