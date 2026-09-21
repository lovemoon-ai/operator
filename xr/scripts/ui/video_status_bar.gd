extends "res://scripts/ui/composition_viewport_ui.gd"
class_name VideoStatusBar

const VIEWPORT_SIZE := Vector2i(1280, 92)
const PANEL_SIZE := Vector2(3.2, 0.23)

var _label: Label
var _panel_style: StyleBoxFlat
var _recording_dot: Panel
var _blink_elapsed := 0.0


func _init() -> void:
	interaction_priority = 5
	var viewport := _setup_viewport_layer(
		"VideoStatusBarViewport", VIEWPORT_SIZE, PANEL_SIZE, 3, 0.0
	)
	_build_content(viewport)
	visible = false


func set_status(state: String, message: String) -> void:
	if _label == null:
		return
	var normalized := state.strip_edges().to_lower()
	var title := normalized.replace("_", " ").to_upper()
	_label.text = (title + "  ·  " if not title.is_empty() else "") + message
	var recording := normalized == "recording"
	_recording_dot.visible = recording
	_blink_elapsed = 0.0
	_recording_dot.modulate.a = 1.0
	set_process(recording)
	var color := Color(0.35, 0.78, 1.0, 0.98)
	match normalized:
		"ready":
			color = Color(0.28, 0.90, 0.56, 0.98)
		"recording":
			color = Color(1.0, 0.28, 0.25, 0.98)
		"finishing":
			color = Color(1.0, 0.68, 0.20, 0.98)
		"finished":
			color = Color(0.30, 0.92, 0.68, 0.98)
		"error":
			color = Color(1.0, 0.34, 0.30, 0.98)
	_label.add_theme_color_override("font_color", color)
	_panel_style.border_color = Color(color.r, color.g, color.b, 0.88)


func is_interaction_target_visible() -> bool:
	return false


func captures_teleop_input() -> bool:
	return false


func _process(delta: float) -> void:
	_blink_elapsed = fmod(_blink_elapsed + delta, 1.0)
	_recording_dot.modulate.a = 1.0 if _blink_elapsed < 0.5 else 0.18


func _build_content(viewport: SubViewport) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel_style = StyleBoxFlat.new()
	_panel_style.bg_color = Color(0.025, 0.032, 0.040, 0.94)
	_panel_style.border_color = Color(0.35, 0.78, 1.0, 0.88)
	_panel_style.set_border_width_all(2)
	_panel_style.set_corner_radius_all(14)
	panel.add_theme_stylebox_override("panel", _panel_style)
	viewport.add_child(panel)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(center)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	center.add_child(row)

	_recording_dot = Panel.new()
	_recording_dot.custom_minimum_size = Vector2(22, 22)
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = Color(1.0, 0.08, 0.06, 1.0)
	dot_style.set_corner_radius_all(11)
	_recording_dot.add_theme_stylebox_override("panel", dot_style)
	_recording_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_recording_dot.visible = false
	row.add_child(_recording_dot)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 25)
	_label.add_theme_color_override("font_color", Color(0.35, 0.78, 1.0, 0.98))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_label)
	set_process(false)
