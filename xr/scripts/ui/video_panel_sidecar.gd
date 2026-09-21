extends "res://scripts/ui/composition_viewport_ui.gd"
class_name VideoPanelSidecar

signal reset_requested
signal distance_lock_changed(locked: bool)

const RESET_ICON := preload("res://assets/icons/reset.svg")
const VideoControlIconScript := preload("res://scripts/ui/video_control_icon.gd")
const VIEWPORT_SIZE := Vector2i(360, 156)
const PANEL_SIZE := Vector2(0.9, 0.39)
const COL_BACKGROUND := Color(0.025, 0.032, 0.040, 0.94)
const COL_BORDER := Color(1.0, 0.647, 0.169, 0.92)

var _reset_button: Button
var _lock_button: Button
var _lock_icon: Control
var _distance_locked := true


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


func captures_teleop_input() -> bool:
	return true


func captures_teleop_scroll() -> bool:
	return not _distance_locked


func scroll_by_pixels(delta_pixels: float) -> void:
	if _distance_locked:
		return
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
	content.add_theme_constant_override("separation", 24)
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(content)

	var reset_container := CenterContainer.new()
	reset_container.custom_minimum_size.x = 132
	reset_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(reset_container)

	_reset_button = Button.new()
	_reset_button.text = ""
	_reset_button.icon = RESET_ICON
	_reset_button.expand_icon = true
	_reset_button.icon_max_width = 58
	_reset_button.tooltip_text = tr("UI_VIDEO_RESET_POSITION")
	_reset_button.focus_mode = Control.FOCUS_NONE
	_reset_button.custom_minimum_size = Vector2(124, 104)
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

	var lock_container := CenterContainer.new()
	lock_container.custom_minimum_size.x = 132
	lock_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(lock_container)

	_lock_button = Button.new()
	_lock_button.text = ""
	_lock_button.focus_mode = Control.FOCUS_NONE
	_lock_button.custom_minimum_size = Vector2(124, 104)
	_lock_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_lock_button.mouse_entered.connect(func() -> void: _play_feedback("hover", -5.0, self))
	_lock_button.pressed.connect(_on_lock_pressed)
	lock_container.add_child(_lock_button)
	_lock_icon = VideoControlIconScript.new()
	_lock_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lock_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lock_button.add_child(_lock_icon)
	_refresh_lock_button()


func _on_reset_pressed() -> void:
	_play_feedback("click", 0.0, self)
	reset_requested.emit()


func set_distance_locked(locked: bool) -> void:
	_distance_locked = locked
	_refresh_lock_button()


func is_distance_locked() -> bool:
	return _distance_locked


func _on_lock_pressed() -> void:
	_play_feedback("click", 0.0, self)
	set_distance_locked(not _distance_locked)
	distance_lock_changed.emit(_distance_locked)


func _refresh_lock_button() -> void:
	if _lock_button == null:
		return
	_lock_button.text = ""
	if _lock_icon != null:
		_lock_icon.call(
			"set_kind",
			VideoControlIconScript.Kind.LOCKED
			if _distance_locked
			else VideoControlIconScript.Kind.UNLOCKED,
		)
	_lock_button.tooltip_text = tr("UI_VIDEO_UNLOCK_DISTANCE") if _distance_locked \
		else tr("UI_VIDEO_LOCK_DISTANCE")
	var normal_color := Color(0.32, 0.13, 0.08, 0.98) if _distance_locked \
		else Color(0.10, 0.12, 0.14, 0.98)
	_lock_button.add_theme_stylebox_override("normal", _button_style(normal_color))
	_lock_button.add_theme_stylebox_override(
		"hover", _button_style(Color(0.38, 0.18, 0.10, 1.0) if _distance_locked \
		else Color(0.16, 0.18, 0.20, 1.0))
	)
	_lock_button.add_theme_stylebox_override(
		"pressed", _button_style(Color(0.22, 0.20, 0.14, 1.0))
	)


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
