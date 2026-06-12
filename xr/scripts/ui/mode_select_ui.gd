extends Control

## Single-card UI used by the 3D launcher (scripts/app/launcher/mode_select.gd).
##
## Each launcher card is its own Viewport2DIn3D quad floating in front of the
## user, so this Control renders exactly one card (icon + title + subtitle).
## The 2-row grid that used to live here moved up into the launcher script, which
## now positions one of these scenes per mode. `selected` fires when the
## operator clicks the card; the launcher script maps that to the scene
## change (or app quit for the EXIT kind).

signal selected

enum Kind {
	TELEOP,
	EGO_CAPTURE,
	LIVE_FEED,
	VR,
	EXIT,
}

const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_MUTED := Color(0.65, 0.70, 0.75)
const COL_ACCENT := Color(1.0, 0.647, 0.169, 0.98)
const COL_DANGER := Color(0.96, 0.36, 0.30, 0.98)
const COL_CARD_BORDER := Color(0.24, 0.28, 0.32, 1.0)

const HOVER_SCALE := Vector2(1.045, 1.045)
const NORMAL_SCALE := Vector2.ONE
const HOVER_Y_OFFSET := -4.0
const HOVER_TWEEN_DURATION := 0.13
const HOVER_MODULATE := Color(1.12, 1.08, 0.96)
const NORMAL_MODULATE := Color.WHITE

var _kind: int = Kind.TELEOP
var _accent: Color = COL_ACCENT
var _card: Button
var _icon: _CardIcon
var _title_label: Label
var _subtitle_label: Label
var _status_label: Label
var _card_tween: Tween
var _feedback_input_mode := "controllers"
var _feedback_controller: XRController3D
var _built := false


func _ready() -> void:
	_ensure_built()


func configure(kind: int, title_text: String, subtitle_text: String) -> void:
	_ensure_built()
	_kind = kind
	_accent = COL_DANGER if kind == Kind.EXIT else COL_ACCENT
	if _icon != null:
		_icon.kind = kind
		_icon.accent = _accent
		_icon.queue_redraw()
	if _title_label != null:
		_title_label.text = title_text
	if _subtitle_label != null:
		_subtitle_label.text = subtitle_text
	if _card != null:
		_card.add_theme_stylebox_override("normal", _card_style(false))
		_card.add_theme_stylebox_override("hover", _card_style(true))
		_card.add_theme_stylebox_override("pressed", _card_style(true))
		_card.add_theme_stylebox_override("focus", _card_style(true))


func set_status(text: String) -> void:
	_ensure_built()
	if _status_label:
		_status_label.text = text
		_status_label.visible = not text.is_empty()


func set_feedback_input_mode(mode: String, controller: XRController3D = null) -> void:
	_feedback_input_mode = mode
	_feedback_controller = controller


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_build_ui()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)

	var light_bar := _LightBar.new()
	light_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	light_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(light_bar)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	_card = Button.new()
	_card.flat = true
	_card.focus_mode = Control.FOCUS_NONE
	_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_card.clip_text = false
	_card.text = ""
	_card.add_theme_stylebox_override("normal", _card_style(false))
	_card.add_theme_stylebox_override("hover", _card_style(true))
	_card.add_theme_stylebox_override("pressed", _card_style(true))
	_card.add_theme_stylebox_override("focus", _card_style(true))
	_card.pressed.connect(_on_card_pressed)
	_card.mouse_entered.connect(_on_card_hover_enter)
	_card.mouse_exited.connect(_on_card_hover_exit)
	_card.resized.connect(func() -> void: _card.pivot_offset = _card.size * 0.5)
	margin.add_child(_card)

	var card_margin := MarginContainer.new()
	card_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card_margin.add_theme_constant_override("margin_left", 22)
	card_margin.add_theme_constant_override("margin_right", 22)
	card_margin.add_theme_constant_override("margin_top", 22)
	card_margin.add_theme_constant_override("margin_bottom", 22)
	card_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(card_margin)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 14)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_margin.add_child(column)

	_icon = _CardIcon.new()
	_icon.kind = _kind
	_icon.accent = _accent
	_icon.custom_minimum_size = Vector2(96, 96)
	_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_icon)

	_title_label = Label.new()
	_title_label.text = ""
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 32)
	_title_label.add_theme_color_override("font_color", COL_TITLE)
	_title_label.clip_text = false
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.text = ""
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle_label.add_theme_font_size_override("font_size", 18)
	_subtitle_label.add_theme_color_override("font_color", COL_MUTED)
	_subtitle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_subtitle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_subtitle_label)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.visible = false
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", COL_MUTED)
	column.add_child(_status_label)


func _on_card_pressed() -> void:
	_play_ui_sound("click")
	emit_signal("selected")


func _on_card_hover_enter() -> void:
	_play_ui_sound("hover")
	if _card == null:
		return
	_animate_card(true)
	_animate_card_modulate(HOVER_MODULATE)


func _on_card_hover_exit() -> void:
	if _card == null:
		return
	_animate_card(false)
	_animate_card_modulate(NORMAL_MODULATE)


func _animate_card(hovered: bool) -> void:
	if _card == null:
		return
	if _card_tween != null and _card_tween.is_running():
		_card_tween.kill()
	_card_tween = create_tween()
	_card_tween.set_parallel(true)
	_card_tween.set_trans(Tween.TRANS_BACK)
	_card_tween.set_ease(Tween.EASE_OUT)
	_card_tween.tween_property(_card, "scale", HOVER_SCALE if hovered else NORMAL_SCALE, HOVER_TWEEN_DURATION)
	_card_tween.tween_property(_card, "position:y", HOVER_Y_OFFSET if hovered else 0.0, HOVER_TWEEN_DURATION)


func _animate_card_modulate(target: Color) -> void:
	if _card == null:
		return
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(_card, "modulate", target, HOVER_TWEEN_DURATION)


func _play_ui_sound(action: String, volume_db: float = 0.0) -> void:
	# Launcher feedback policy: always play the UI tone so the operator
	# hears the click / hover beep even when the XR pointer is being
	# driven by a controller. If a controller is hovering, ALSO fire its
	# haptic pulse — audio + haptic together is the right feel for a
	# transient menu where each card press also triggers a scene swap.
	# (The capture / teleop in-mode panels still use the haptic-vs-sound
	# mutex via BaseSettingsPanel; that's intentional because those panels
	# are dense with toggles and the audio chirps would get noisy.)
	var sound_bus := _get_ui_sound_bus()
	if sound_bus != null and sound_bus.has_method("play"):
		sound_bus.call("play", action, volume_db)
	if _feedback_input_mode == "controllers" and _feedback_controller != null:
		var haptics := _get_haptics_bus()
		if haptics != null and haptics.has_method("fire_ui_event"):
			haptics.call("fire_ui_event", action, _feedback_controller)


func _get_ui_sound_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("UISoundBus")


func _get_haptics_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Haptics")


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL_BG
	style.border_color = COL_PANEL_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	return style


func _card_style(highlighted: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL_BG
	style.border_color = _accent if highlighted else COL_CARD_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 14
	return style


class _CardIcon:
	extends Control

	var kind: int = 0
	var accent: Color = Color(1.0, 0.647, 0.169, 0.98)

	func _draw() -> void:
		var area := size
		var cx := area.x * 0.5
		var cy := area.y * 0.5
		var left := cx - 38.0
		var right := cx + 38.0
		var top := cy - 38.0
		var bottom := cy + 38.0
		match kind:
			0:
				_draw_robot_arm(left, right, top, bottom, accent)
			1:
				_draw_eye_capture(cx, cy, left, right, top, bottom, accent)
			2:
				_draw_camera(cx, cy, left, top, accent)
			3:
				_draw_vr_headset(cx, cy, left, right, top, bottom, accent)
			_:
				_draw_exit(cx, cy, left, right, top, bottom, accent)

	func _draw_robot_arm(left: float, right: float, top: float, bottom: float, color: Color) -> void:
		var p0 := Vector2(left + 5.0, bottom - 8.0)
		var p1 := Vector2(right - 10.0, _cy_mid(top, bottom))
		var p2 := Vector2(left + 18.0, top + 12.0)
		var p3 := Vector2(left + 34.0, top + 4.0)
		draw_line(p0, p1, color, 6.0, true)
		draw_line(p1, p2, color, 6.0, true)
		draw_line(p2, p3, color, 6.0, true)
		draw_circle(p0, 5.0, color)
		draw_circle(p1, 6.5, color)
		draw_circle(p3, 6.5, color)

	func _draw_eye_capture(cx: float, cy: float, left: float, right: float, _top: float, _bottom: float, color: Color) -> void:
		var points := PackedVector2Array([
			Vector2(left + 2.0, cy),
			Vector2(cx - 22.0, cy - 22.0),
			Vector2(cx, cy - 26.0),
			Vector2(cx + 22.0, cy - 22.0),
			Vector2(right - 2.0, cy),
			Vector2(cx + 22.0, cy + 22.0),
			Vector2(cx, cy + 26.0),
			Vector2(cx - 22.0, cy + 22.0),
			Vector2(left + 2.0, cy)
		])
		draw_polyline(points, color, 5.0, true)
		draw_arc(Vector2(cx, cy), 12.0, 0.0, TAU, 30, color, 4.5, true)
		draw_circle(Vector2(cx, cy), 5.0, color)

	func _draw_camera(cx: float, cy: float, left: float, top: float, color: Color) -> void:
		var body_rect := Rect2(Vector2(left + 5.0, top + 20.0), Vector2(66.0, 46.0))
		_draw_rounded_rect_outline(body_rect, 9.0, color, 5.5)
		var viewfinder := Rect2(Vector2(left + 19.0, top + 9.0), Vector2(22.0, 12.0))
		_draw_rounded_rect_outline(viewfinder, 3.0, color, 4.5)
		var lens_center := Vector2(cx, cy + 8.0)
		draw_arc(lens_center, 13.5, 0.0, TAU, 28, color, 5.0, true)
		draw_circle(lens_center + Vector2(-3.5, -3.5), 3.0, color)

	func _draw_vr_headset(cx: float, cy: float, left: float, right: float, top: float, bottom: float, color: Color) -> void:
		var visor := Rect2(Vector2(left + 5.0, top + 20.0), Vector2(66.0, 38.0))
		_draw_rounded_rect_outline(visor, 10.0, color, 5.5)
		draw_line(Vector2(left + 5.0, cy + 5.0), Vector2(left - 5.0, cy + 16.0), color, 4.5, true)
		draw_line(Vector2(right - 5.0, cy + 5.0), Vector2(right + 5.0, cy + 16.0), color, 4.5, true)
		draw_line(Vector2(cx - 11.0, bottom - 10.0), Vector2(cx + 11.0, bottom - 10.0), color, 4.5, true)
		draw_circle(Vector2(cx - 14.0, cy), 3.0, color)
		draw_circle(Vector2(cx + 14.0, cy), 3.0, color)

	# Exit icon: a doorway + outward arrow. Uses the danger (red) accent
	# so the operator visually distinguishes it from the mode entries.
	func _draw_exit(cx: float, cy: float, left: float, right: float, top: float, bottom: float, color: Color) -> void:
		var door := Rect2(Vector2(left + 4.0, top + 4.0), Vector2(36.0, bottom - top - 8.0))
		_draw_rounded_rect_outline(door, 4.0, color, 5.0)
		# Door handle
		draw_circle(Vector2(left + 30.0, cy + 2.0), 3.0, color)
		# Arrow pointing right (out of the door)
		var arrow_start := Vector2(left + 44.0, cy)
		var arrow_end := Vector2(right - 4.0, cy)
		draw_line(arrow_start, arrow_end, color, 5.0, true)
		var head := arrow_end
		draw_line(head, head + Vector2(-12.0, -10.0), color, 5.0, true)
		draw_line(head, head + Vector2(-12.0, 10.0), color, 5.0, true)

	func _cy_mid(top: float, bottom: float) -> float:
		return (top + bottom) * 0.5

	func _draw_rounded_rect_outline(rect: Rect2, radius: float, color: Color, width: float) -> void:
		var x0 := rect.position.x
		var y0 := rect.position.y
		var x1 := rect.position.x + rect.size.x
		var y1 := rect.position.y + rect.size.y
		var r := minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
		draw_line(Vector2(x0 + r, y0), Vector2(x1 - r, y0), color, width, true)
		draw_line(Vector2(x1, y0 + r), Vector2(x1, y1 - r), color, width, true)
		draw_line(Vector2(x1 - r, y1), Vector2(x0 + r, y1), color, width, true)
		draw_line(Vector2(x0, y1 - r), Vector2(x0, y0 + r), color, width, true)
		draw_arc(Vector2(x0 + r, y0 + r), r, PI, PI * 1.5, 10, color, width, true)
		draw_arc(Vector2(x1 - r, y0 + r), r, PI * 1.5, TAU, 10, color, width, true)
		draw_arc(Vector2(x1 - r, y1 - r), r, 0.0, PI * 0.5, 10, color, width, true)
		draw_arc(Vector2(x0 + r, y1 - r), r, PI * 0.5, PI, 10, color, width, true)


class _LightBar:
	extends Control

	var _offset := 0.0

	func _ready() -> void:
		set_process(true)

	func _process(delta: float) -> void:
		_offset = fmod(_offset + delta * 0.18, 1.0)
		queue_redraw()

	func _draw() -> void:
		if size.x <= 1.0 or size.y <= 1.0:
			return
		var y := size.y * (0.12 + 0.08 * sin(_offset * TAU))
		var x := -size.x * 0.25 + size.x * 1.5 * _offset
		var color := Color(1.0, 0.647, 0.169, 0.06)
		draw_line(Vector2(x - 100.0, y), Vector2(x + 160.0, y + 24.0), color, 12.0, true)
