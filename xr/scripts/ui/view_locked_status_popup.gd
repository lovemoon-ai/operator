extends "res://scripts/ui/composition_viewport_ui.gd"
class_name ViewLockedStatusPopup

signal cancel_requested

const VIEWPORT_SIZE := Vector2i(720, 270)

var _title_label: Label
var _path_label: Label
var _panel_style: StyleBoxFlat
var _progress_bar: ProgressBar
var _cancel_button: Button
var _hide_seconds := 0.0


func _init() -> void:
	_setup_viewport_layer("StatusPopupViewport", VIEWPORT_SIZE, Vector2(0.56, 0.21), 4, 14.0)
	visible = false
	_build_viewport()


func _process(delta: float) -> void:
	if not visible:
		return
	if _hide_seconds < 0.0:
		return
	_hide_seconds -= delta
	if _hide_seconds <= 0.0:
		visible = false


func show_saved_path(path: String, duration_seconds: float = 2.0) -> void:
	_panel_style.bg_color = Color(0.055, 0.067, 0.08, 0.96)
	_panel_style.border_color = Color(0.28, 0.32, 0.36, 0.90)
	_title_label.text = tr("UI_RECORDING_SAVED")
	_path_label.text = path
	_path_label.add_theme_color_override("font_color", Color(0.90, 0.93, 0.94))
	if _progress_bar:
		_progress_bar.visible = false
		_progress_bar.value = 0.0
	if _cancel_button:
		_cancel_button.visible = false
	_hide_seconds = duration_seconds
	visible = true


func show_error(message: String, duration_seconds: float = 4.0) -> void:
	_panel_style.bg_color = Color(0.15, 0.045, 0.04, 0.96)
	_panel_style.border_color = Color(0.72, 0.16, 0.12, 0.92)
	_title_label.text = tr("UI_RECORDING_SAVE_FAILED")
	_path_label.text = message
	_path_label.add_theme_color_override("font_color", Color(1.00, 0.46, 0.42, 0.98))
	if _progress_bar:
		_progress_bar.visible = false
		_progress_bar.value = 0.0
	if _cancel_button:
		_cancel_button.visible = false
	_hide_seconds = duration_seconds
	visible = true


func show_upload_progress(title: String, detail: String, progress: float, level: String = "normal", duration_seconds: float = 0.0, cancelable: bool = false) -> void:
	_panel_style.bg_color = Color(0.055, 0.067, 0.08, 0.96)
	_panel_style.border_color = Color(0.28, 0.32, 0.36, 0.90)
	_title_label.text = title
	_path_label.text = detail
	var color := Color(0.55, 0.80, 0.98, 0.94)
	match level:
		"success":
			color = Color(0.30, 0.88, 0.64, 0.96)
		"warning":
			color = Color(1.00, 0.78, 0.36, 0.96)
		"error":
			color = Color(1.00, 0.46, 0.42, 0.98)
	_path_label.add_theme_color_override("font_color", color)
	if _progress_bar:
		_progress_bar.visible = progress >= 0.0
		_progress_bar.value = clampf(progress, 0.0, 1.0) * 100.0
	if _cancel_button:
		_cancel_button.visible = cancelable
	_hide_seconds = duration_seconds if duration_seconds > 0.0 else -1.0
	visible = true


func accepts_pointer() -> bool:
	return _cancel_button != null and _cancel_button.visible


func _build_viewport() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel_style = StyleBoxFlat.new()
	_panel_style.bg_color = Color(0.055, 0.067, 0.08, 0.96)
	_panel_style.border_color = Color(0.28, 0.32, 0.36, 0.90)
	_panel_style.set_border_width_all(2)
	_panel_style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", _panel_style)
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

	_progress_bar = ProgressBar.new()
	_progress_bar.visible = false
	_progress_bar.show_percentage = true
	_progress_bar.custom_minimum_size = Vector2(VIEWPORT_SIZE.x - 80.0, 24.0)
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	content.add_child(_progress_bar)

	_cancel_button = Button.new()
	_cancel_button.text = tr("UI_CANCEL_UPLOAD")
	_cancel_button.custom_minimum_size = Vector2(180, 46)
	_cancel_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cancel_button.add_theme_font_size_override("font_size", 20)
	_cancel_button.visible = false
	_cancel_button.pressed.connect(_on_cancel_pressed)
	content.add_child(_cancel_button)
	if _cursor:
		_cursor.move_to_front()


func _on_cancel_pressed() -> void:
	_play_feedback("click")
	cancel_requested.emit()
