extends OpenXRCompositionLayerQuad
class_name ViewLockedStatusPopup

const VIEWPORT_SIZE := Vector2i(720, 220)

var _viewport: SubViewport
var _title_label: Label
var _path_label: Label
var _hide_seconds := 0.0


func _init() -> void:
	quad_size = Vector2(0.56, 0.171)
	alpha_blend = true
	sort_order = 4
	visible = false
	_build_viewport()


func _process(delta: float) -> void:
	if not visible:
		return
	_hide_seconds -= delta
	if _hide_seconds <= 0.0:
		visible = false


func show_saved_path(path: String, duration_seconds: float = 2.0) -> void:
	_title_label.text = tr("UI_RECORDING_SAVED")
	_path_label.text = path
	_hide_seconds = duration_seconds
	visible = true


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "StatusPopupViewport"
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	layer_viewport = _viewport

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.067, 0.08, 0.96)
	panel_style.border_color = Color(0.28, 0.32, 0.36, 0.90)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", panel_style)
	_viewport.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)

	_title_label = Label.new()
	_title_label.text = tr("UI_RECORDING_SAVED")
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 30)
	_title_label.add_theme_color_override("font_color", Color(0.94, 0.96, 0.98))
	content.add_child(_title_label)

	_path_label = Label.new()
	_path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_path_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_path_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_path_label.add_theme_font_size_override("font_size", 22)
	_path_label.add_theme_color_override("font_color", Color(0.90, 0.93, 0.94))
	content.add_child(_path_label)
