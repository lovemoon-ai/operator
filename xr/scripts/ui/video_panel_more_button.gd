extends "res://scripts/ui/composition_viewport_ui.gd"
class_name VideoPanelMoreButton

signal pressed

const VideoControlIconScript := preload("res://scripts/ui/video_control_icon.gd")
const VIEWPORT_SIZE := Vector2i(128, 128)
const QUAD_SIZE := Vector2(0.16, 0.16)
const BUTTON_SIZE := Vector2(104, 104)

var _button: Button
var _expanded := false


func _init() -> void:
	interaction_priority = 65
	var viewport := _setup_viewport_layer(
		"VideoPanelMoreButtonViewport", VIEWPORT_SIZE, QUAD_SIZE, 4, 10.0
	)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(root)

	_button = Button.new()
	_button.text = ""
	_button.position = (Vector2(VIEWPORT_SIZE) - BUTTON_SIZE) * 0.5
	_button.size = BUTTON_SIZE
	_button.focus_mode = Control.FOCUS_NONE
	_button.tooltip_text = tr("UI_VIDEO_MORE_CONTROLS")
	_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_button.mouse_entered.connect(func() -> void: _play_feedback("hover", -5.0, self))
	_button.pressed.connect(_on_pressed)
	root.add_child(_button)
	var icon: Control = VideoControlIconScript.new()
	icon.call("set_kind", VideoControlIconScript.Kind.MORE)
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_button.add_child(icon)
	_refresh_style()
	visible = false


func captures_teleop_input() -> bool:
	return true


func captures_teleop_scroll() -> bool:
	return false


func set_expanded(value: bool) -> void:
	_expanded = value
	_refresh_style()


func _on_pressed() -> void:
	_play_feedback("click", 0.0, self)
	pressed.emit()


func _refresh_style() -> void:
	if _button == null:
		return
	_button.add_theme_stylebox_override(
		"normal", _button_style(Color(0.28, 0.13, 0.05, 0.96) if _expanded else Color(0.02, 0.03, 0.04, 0.78))
	)
	_button.add_theme_stylebox_override("hover", _button_style(Color(0.18, 0.10, 0.05, 0.96)))
	_button.add_theme_stylebox_override("pressed", _button_style(Color(0.34, 0.16, 0.06, 1.0)))


func _button_style(background: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = Color(1.0, 0.647, 0.169, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(22)
	return style
