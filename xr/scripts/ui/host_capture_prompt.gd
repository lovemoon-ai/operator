extends "res://scripts/ui/composition_viewport_ui.gd"
class_name HostCapturePrompt
## Headset-local permission UI for host-declared capture streams. One instance
## asks the user once for a host's whole camera declaration (Allow / Deny);
## another stays up as the "streaming to <host>" indicator with a one-tap
## Stop that revokes the grant. Both follow the head.

signal decided(allowed: bool)
signal revoke_requested

const REQUEST_SIZE := Vector2i(760, 360)
const REQUEST_QUAD := Vector2(0.60, 0.284)
const INDICATOR_SIZE := Vector2i(640, 96)
const INDICATOR_QUAD := Vector2(0.40, 0.06)
const REQUEST_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.02, -0.9))
const INDICATOR_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.26, -0.95))

## Head node the prompt follows (the XRCamera3D).
var head: Node3D
var _indicator := false
var _title_label: Label
var _detail_label: Label
var _allow_button: Button
var _deny_button: Button
var _stop_button: Button


func _init(indicator: bool = false) -> void:
	_indicator = indicator
	if _indicator:
		_setup_viewport_layer("HostCaptureIndicatorViewport", INDICATOR_SIZE, INDICATOR_QUAD, 6, 12.0)
	else:
		_setup_viewport_layer("HostCapturePromptViewport", REQUEST_SIZE, REQUEST_QUAD, 7, 16.0)
	visible = false
	_build_viewport()


func _process(_delta: float) -> void:
	if visible and head != null:
		transform = head.transform * (INDICATOR_OFFSET if _indicator else REQUEST_OFFSET)


## Asks for a host's camera declaration. `lines` describe the requested streams
## and local tasks, one per line.
func show_request(host: String, lines: Array) -> void:
	_title_label.text = tr("UI_HOST_CAPTURE_REQUEST_TITLE") % host
	_detail_label.text = "\n".join(PackedStringArray(lines))
	visible = true


## The persistent indicator while a host receives headset media.
func show_indicator(text: String) -> void:
	_title_label.text = text
	visible = true


func dismiss() -> void:
	visible = false
	clear_pointer()


## Settings-like surfaces capture teleop input so a click here cannot also
## drive the robot. The indicator is small and never blocks teleop.
func captures_teleop_input() -> bool:
	return visible and not _indicator


func captures_teleop_scroll() -> bool:
	return false


func accepts_pointer() -> bool:
	return visible


func _build_viewport() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.067, 0.08, 0.96)
	style.border_color = COL_ACCENT_MUTED if not _indicator else Color(0.86, 0.22, 0.18, 0.92)
	style.set_border_width_all(2)
	style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", style)
	_viewport.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 24)
	for side in ["margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10 if _indicator else 20)
	panel.add_child(margin)

	if _indicator:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		margin.add_child(row)
		_title_label = _label(22, Color(1.0, 0.55, 0.50))
		_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_title_label.clip_text = true
		row.add_child(_title_label)
		_stop_button = _button(tr("UI_HOST_CAPTURE_STOP"))
		_stop_button.pressed.connect(_on_stop_pressed)
		row.add_child(_stop_button)
	else:
		var content := VBoxContainer.new()
		content.add_theme_constant_override("separation", 12)
		margin.add_child(content)
		_title_label = _label(26, Color(0.94, 0.96, 0.98))
		_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.add_child(_title_label)
		_detail_label = _label(20, Color(0.80, 0.85, 0.90))
		_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_detail_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.add_child(_detail_label)
		var buttons := HBoxContainer.new()
		buttons.alignment = BoxContainer.ALIGNMENT_CENTER
		buttons.add_theme_constant_override("separation", 24)
		content.add_child(buttons)
		_deny_button = _button(tr("UI_HOST_CAPTURE_DENY"))
		_deny_button.pressed.connect(_on_decided.bind(false))
		buttons.add_child(_deny_button)
		_allow_button = _button(tr("UI_HOST_CAPTURE_ALLOW"))
		_allow_button.pressed.connect(_on_decided.bind(true))
		buttons.add_child(_allow_button)
	if _cursor:
		_cursor.move_to_front()


func _label(font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(170, 52 if not _indicator else 60)
	button.add_theme_font_size_override("font_size", 21)
	return button


func _on_decided(allowed: bool) -> void:
	_play_feedback("click")
	dismiss()
	decided.emit(allowed)


func _on_stop_pressed() -> void:
	_play_feedback("click")
	revoke_requested.emit()
