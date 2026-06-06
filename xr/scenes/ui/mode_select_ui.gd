extends Control

signal teleop_selected
signal ego_capture_selected
signal live_feed_selected
signal vr_selected

const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_MUTED := Color(0.65, 0.70, 0.75)
const COL_ACCENT := Color(1.0, 0.647, 0.169, 0.98)
const COL_CARD_BORDER := Color(0.24, 0.28, 0.32, 1.0)

const CARD_SIZE := Vector2(300, 138)
const HOVER_SCALE := Vector2(1.045, 1.045)
const NORMAL_SCALE := Vector2.ONE
const HOVER_Y_OFFSET := -4.0
const HOVER_TWEEN_DURATION := 0.13
const HOVER_MODULATE := Color(1.12, 1.08, 0.96)
const DIM_MODULATE := Color(1.0, 1.0, 1.0, 0.62)
const NORMAL_MODULATE := Color.WHITE

var _status_label: Label
var _cards := []
var _card_tweens := {}
var _feedback_input_mode := "controllers"
var _feedback_controller: XRController3D


func _ready() -> void:
	_build_ui()


func set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text
		_status_label.visible = not text.is_empty()


func set_feedback_input_mode(mode: String, controller: XRController3D = null) -> void:
	_feedback_input_mode = mode
	_feedback_controller = controller


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
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	content.add_theme_constant_override("separation", 16)
	margin.add_child(content)

	var title := Label.new()
	title.text = tr("UI_MODE_SELECT_TITLE")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", COL_TITLE)
	content.add_child(title)

	var card_center := CenterContainer.new()
	card_center.mouse_filter = Control.MOUSE_FILTER_PASS
	card_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(card_center)

	var card_rows := VBoxContainer.new()
	card_rows.mouse_filter = Control.MOUSE_FILTER_PASS
	card_rows.alignment = BoxContainer.ALIGNMENT_CENTER
	card_rows.add_theme_constant_override("separation", 16)
	card_center.add_child(card_rows)

	var top_row := _build_card_row()
	card_rows.add_child(top_row)
	var bottom_row := _build_card_row()
	card_rows.add_child(bottom_row)

	_add_mode_card(top_row, tr("UI_TELEOP_MODE"), tr("UI_TELEOP_MODE_SUB"), _IconKind.TELEOP, func() -> void: teleop_selected.emit())
	_add_mode_card(top_row, tr("UI_EGO_MODE"), tr("UI_EGO_MODE_SUB"), _IconKind.EGO, func() -> void: ego_capture_selected.emit())
	_add_mode_card(bottom_row, tr("UI_LIVE_FEED_MODE"), tr("UI_LIVE_FEED_MODE_SUB"), _IconKind.LIVE_FEED, func() -> void: live_feed_selected.emit())
	_add_mode_card(bottom_row, tr("UI_VR_MODE"), tr("UI_VR_MODE_SUB"), _IconKind.VR, func() -> void: vr_selected.emit())

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.visible = false
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.add_theme_color_override("font_color", COL_MUTED)
	content.add_child(_status_label)


func _build_card_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	return row


func _add_mode_card(parent: Container, title_text: String, subtitle_text: String, icon_kind: int, selected: Callable) -> Button:
	var card := _build_card(title_text, subtitle_text, icon_kind)
	card.pressed.connect(func() -> void:
		_play_ui_sound("click")
		selected.call()
	)
	card.mouse_entered.connect(func() -> void: _on_card_hover_enter(card))
	card.mouse_exited.connect(func() -> void: _on_card_hover_exit())
	parent.add_child(card)
	_cards.append(card)
	return card


func _build_card(title_text: String, subtitle_text: String, icon_kind: int) -> Button:
	var card := Button.new()
	card.flat = true
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = CARD_SIZE
	card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	card.clip_text = false
	card.text = ""
	card.add_theme_stylebox_override("normal", _card_style(false))
	card.add_theme_stylebox_override("hover", _card_style(true))
	card.add_theme_stylebox_override("pressed", _card_style(true))
	card.add_theme_stylebox_override("focus", _card_style(true))
	card.pivot_offset = CARD_SIZE * 0.5
	card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(margin)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	var icon := _CardIcon.new()
	icon.kind = icon_kind
	icon.custom_minimum_size = Vector2(54, 54)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var text_box := VBoxContainer.new()
	text_box.alignment = BoxContainer.ALIGNMENT_CENTER
	text_box.add_theme_constant_override("separation", 6)
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text_box)

	var title_label := Label.new()
	title_label.text = title_text
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title_label.add_theme_font_size_override("font_size", 22)
	title_label.add_theme_color_override("font_color", COL_TITLE)
	title_label.clip_text = true
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_child(title_label)

	var subtitle_label := Label.new()
	subtitle_label.text = subtitle_text
	subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle_label.add_theme_font_size_override("font_size", 13)
	subtitle_label.add_theme_color_override("font_color", COL_MUTED)
	subtitle_label.custom_minimum_size.y = 38
	subtitle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subtitle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_box.add_child(subtitle_label)

	return card


func _on_card_hover_enter(target: Button) -> void:
	_play_ui_sound("hover")
	for card in _cards:
		if card == target:
			_animate_card(card, true)
			_animate_card_modulate(card, HOVER_MODULATE)
		else:
			_animate_card(card, false)
			_animate_card_modulate(card, DIM_MODULATE)


func _on_card_hover_exit() -> void:
	for card in _cards:
		_animate_card(card, false)
		_animate_card_modulate(card, NORMAL_MODULATE)


func _animate_card(card: Button, hovered: bool) -> void:
	_kill_card_tween(card)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_BACK)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", HOVER_SCALE if hovered else NORMAL_SCALE, HOVER_TWEEN_DURATION)
	tween.tween_property(card, "position:y", HOVER_Y_OFFSET if hovered else 0.0, HOVER_TWEEN_DURATION)
	_card_tweens[card] = tween


func _animate_card_modulate(card: Button, target: Color) -> void:
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "modulate", target, HOVER_TWEEN_DURATION)


func _kill_card_tween(card: Button) -> void:
	if not _card_tweens.has(card):
		return
	var tween: Tween = _card_tweens[card]
	if tween != null and tween.is_running():
		tween.kill()


func _play_ui_sound(action: String, volume_db: float = 0.0) -> void:
	if _feedback_input_mode == "hands":
		var sound_bus := _get_ui_sound_bus()
		if sound_bus != null and sound_bus.has_method("play"):
			sound_bus.call("play", action, volume_db)
	elif _feedback_input_mode == "controllers":
		var haptics := _get_haptics_bus()
		var use_haptics := _feedback_controller != null
		if haptics != null and haptics.has_method("should_use_controller_feedback"):
			use_haptics = bool(haptics.call("should_use_controller_feedback", _feedback_controller))
		if use_haptics and haptics != null and haptics.has_method("fire_ui_event"):
			haptics.call("fire_ui_event", action, _feedback_controller)
		else:
			var sound_bus := _get_ui_sound_bus()
			if sound_bus != null and sound_bus.has_method("play"):
				sound_bus.call("play", action, volume_db)


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
	style.set_corner_radius_all(10)
	return style


func _card_style(highlighted: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL_BG
	style.border_color = COL_ACCENT if highlighted else COL_CARD_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 14
	return style


enum _IconKind { TELEOP, EGO, LIVE_FEED, VR }


class _CardIcon:
	extends Control

	var kind: int = 0

	func _draw() -> void:
		var accent := Color(1.0, 0.647, 0.169, 0.98)
		var area := size
		var cx := area.x * 0.5
		var cy := area.y * 0.5
		var left := cx - 31.0
		var right := cx + 31.0
		var top := cy - 31.0
		var bottom := cy + 31.0
		match kind:
			0:
				_draw_robot_arm(left, right, top, bottom, accent)
			1:
				_draw_eye_capture(cx, cy, left, right, top, bottom, accent)
			2:
				_draw_camera(cx, cy, left, top, accent)
			_:
				_draw_vr_headset(cx, cy, left, right, top, bottom, accent)

	func _draw_robot_arm(left: float, right: float, top: float, bottom: float, color: Color) -> void:
		var p0 := Vector2(left + 4.0, bottom - 6.0)
		var p1 := Vector2(right - 8.0, cy_mid(top, bottom))
		var p2 := Vector2(left + 14.0, top + 10.0)
		var p3 := Vector2(left + 28.0, top + 2.0)
		draw_line(p0, p1, color, 5.5, true)
		draw_line(p1, p2, color, 5.5, true)
		draw_line(p2, p3, color, 5.5, true)
		draw_circle(p0, 4.0, color)
		draw_circle(p1, 5.5, color)
		draw_circle(p3, 5.5, color)

	func _draw_eye_capture(cx: float, cy: float, left: float, right: float, _top: float, _bottom: float, color: Color) -> void:
		var points := PackedVector2Array([
			Vector2(left + 2.0, cy),
			Vector2(cx - 18.0, cy - 18.0),
			Vector2(cx, cy - 22.0),
			Vector2(cx + 18.0, cy - 18.0),
			Vector2(right - 2.0, cy),
			Vector2(cx + 18.0, cy + 18.0),
			Vector2(cx, cy + 22.0),
			Vector2(cx - 18.0, cy + 18.0),
			Vector2(left + 2.0, cy)
		])
		draw_polyline(points, color, 4.5, true)
		draw_arc(Vector2(cx, cy), 10.0, 0.0, TAU, 30, color, 4.0, true)
		draw_circle(Vector2(cx, cy), 4.0, color)

	func _draw_camera(cx: float, cy: float, left: float, top: float, color: Color) -> void:
		var body_rect := Rect2(Vector2(left + 4.0, top + 16.0), Vector2(54.0, 38.0))
		_draw_rounded_rect_outline(body_rect, 8.0, color, 5.0)
		var viewfinder := Rect2(Vector2(left + 16.0, top + 7.0), Vector2(18.0, 10.0))
		_draw_rounded_rect_outline(viewfinder, 3.0, color, 4.0)
		var lens_center := Vector2(cx, cy + 6.0)
		draw_arc(lens_center, 11.5, 0.0, TAU, 28, color, 4.5, true)
		draw_circle(lens_center + Vector2(-3.0, -3.0), 2.8, color)

	func _draw_vr_headset(cx: float, cy: float, left: float, right: float, top: float, bottom: float, color: Color) -> void:
		var visor := Rect2(Vector2(left + 4.0, top + 16.0), Vector2(54.0, 32.0))
		_draw_rounded_rect_outline(visor, 9.0, color, 5.0)
		draw_line(Vector2(left + 4.0, cy + 4.0), Vector2(left - 4.0, cy + 13.0), color, 4.0, true)
		draw_line(Vector2(right - 4.0, cy + 4.0), Vector2(right + 4.0, cy + 13.0), color, 4.0, true)
		draw_line(Vector2(cx - 9.0, bottom - 8.0), Vector2(cx + 9.0, bottom - 8.0), color, 4.0, true)
		draw_circle(Vector2(cx - 12.0, cy), 2.5, color)
		draw_circle(Vector2(cx + 12.0, cy), 2.5, color)

	func cy_mid(top: float, bottom: float) -> float:
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
		draw_line(Vector2(x - 140.0, y), Vector2(x + 220.0, y + 34.0), color, 16.0, true)
