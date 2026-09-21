extends "res://scripts/ui/composition_viewport_ui.gd"
class_name VideoPerformancePanel

const VIEWPORT_SIZE := Vector2i(1280, 180)
const PANEL_SIZE := Vector2(3.2, 0.45)
const COL_TEXT := Color(0.94, 0.96, 0.98, 1.0)

var _performance_label: Label


func _init() -> void:
	interaction_priority = 5
	var viewport := _setup_viewport_layer(
		"VideoPerformanceViewport", VIEWPORT_SIZE, PANEL_SIZE, 3, 0.0
	)
	_build_content(viewport)
	visible = false


func set_performance_text(text: String) -> void:
	if _performance_label != null:
		_performance_label.text = text


func is_interaction_target_visible() -> bool:
	return false


func captures_teleop_input() -> bool:
	return false


func _build_content(viewport: SubViewport) -> void:
	var background := PanelContainer.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.add_theme_stylebox_override("panel", _panel_style())
	viewport.add_child(background)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 16)
	background.add_child(margin)

	_performance_label = Label.new()
	_performance_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_performance_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_performance_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_performance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_performance_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_performance_label.add_theme_font_size_override("font_size", 24)
	_performance_label.add_theme_color_override("font_color", COL_TEXT)
	margin.add_child(_performance_label)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.78)
	style.border_color = Color(1.0, 0.647, 0.169, 0.72)
	style.set_border_width_all(2)
	style.set_corner_radius_all(16)
	return style
