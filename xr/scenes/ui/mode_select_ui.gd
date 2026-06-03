extends Control

signal teleop_selected
signal ego_selected

const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_MUTED := Color(0.65, 0.70, 0.75)
const COL_ACCENT := Color(1.0, 0.647, 0.169, 0.98)
const COL_CARD_BORDER := Color(0.24, 0.28, 0.32, 1.0)

# 卡片悬浮时的颜色与缩放参数
const HOVER_SCALE := Vector2(1.08, 1.08)
const NORMAL_SCALE := Vector2(1.0, 1.0)
const HOVER_Y_OFFSET := -8.0
const HOVER_TWEEN_DURATION := 0.15
const HOVER_MODULATE := Color(1.15, 1.10, 0.95)
const DIM_MODULATE := Color(1.0, 1.0, 1.0, 0.55)
const NORMAL_MODULATE := Color(1.0, 1.0, 1.0, 1.0)

var _status_label: Label
var _teleop_card: Button
var _ego_card: Button
var _teleop_tween: Tween
var _ego_tween: Tween
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

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)

	# 背景流光层：覆盖整个面板，绘制水平移动的高光条
	var light_bar := _LightBar.new()
	light_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	light_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(light_bar)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 38)
	margin.add_theme_constant_override("margin_right", 38)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 24)
	margin.add_child(content)

	var title := Label.new()
	title.text = tr("UI_MODE_SELECT_TITLE")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", COL_TITLE)
	content.add_child(title)

	# 卡片容器：水平排列两张卡片
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 32)
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(cards)

	# 遥操卡片
	_teleop_card = _build_card(
		tr("UI_TELEOP_MODE"),
		_IconKind.TELEOP,
	)
	_teleop_card.pressed.connect(func() -> void:
		_play_ui_sound("click")
		teleop_selected.emit()
	)
	_teleop_card.mouse_entered.connect(func() -> void: _on_card_hover_enter(_teleop_card, _ego_card))
	_teleop_card.mouse_exited.connect(func() -> void: _on_card_hover_exit(_teleop_card, _ego_card))
	cards.add_child(_teleop_card)

	# Ego 卡片
	_ego_card = _build_card(
		tr("UI_EGO_MODE"),
		_IconKind.EGO,
	)
	_ego_card.pressed.connect(func() -> void:
		_play_ui_sound("click")
		ego_selected.emit()
	)
	_ego_card.mouse_entered.connect(func() -> void: _on_card_hover_enter(_ego_card, _teleop_card))
	_ego_card.mouse_exited.connect(func() -> void: _on_card_hover_exit(_ego_card, _teleop_card))
	cards.add_child(_ego_card)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.visible = false
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 20)
	_status_label.add_theme_color_override("font_color", COL_MUTED)
	content.add_child(_status_label)


# 构造一张卡片：Button 作为根（保留 pressed 行为），内部 VBox 容纳图标/标题
func _build_card(title_text: String, icon_kind: int) -> Button:
	var card := Button.new()
	card.flat = true
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = Vector2(320, 280)
	card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	card.clip_text = false
	# 文字置空，所有可视内容来自子节点
	card.text = ""
	card.add_theme_stylebox_override("normal", _card_style(false))
	card.add_theme_stylebox_override("hover", _card_style(true))
	card.add_theme_stylebox_override("pressed", _card_style(true))
	card.add_theme_stylebox_override("focus", _card_style(true))
	# 关键：缩放需要绕中心，pivot 在 _notification(RESIZED) 中更新
	card.pivot_offset = card.custom_minimum_size * 0.5
	card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	# 图标：自定义 Control，使用 _draw 绘制
	var icon := _CardIcon.new()
	icon.kind = icon_kind
	icon.custom_minimum_size = Vector2(80, 80)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(icon)

	var title_label := Label.new()
	title_label.text = title_text
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 34)
	title_label.add_theme_color_override("font_color", COL_TITLE)
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title_label)

	return card


# 悬浮进入：放大目标卡，淡化另一张
func _on_card_hover_enter(target: Button, other: Button) -> void:
	_play_ui_sound("hover")
	_animate_card(target, true)
	_animate_card_modulate(other, DIM_MODULATE)
	target.modulate = HOVER_MODULATE


# 悬浮退出：恢复两张卡片
func _on_card_hover_exit(target: Button, other: Button) -> void:
	_animate_card(target, false)
	_animate_card_modulate(other, NORMAL_MODULATE)
	target.modulate = NORMAL_MODULATE


# 单卡缩放与 Y 位移动画
func _animate_card(card: Button, hovered: bool) -> void:
	var is_teleop := card == _teleop_card
	var prev: Tween = _teleop_tween if is_teleop else _ego_tween
	if prev and prev.is_running():
		prev.kill()
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_BACK)
	tween.set_ease(Tween.EASE_OUT)
	var target_scale := HOVER_SCALE if hovered else NORMAL_SCALE
	var target_y := HOVER_Y_OFFSET if hovered else 0.0
	tween.tween_property(card, "scale", target_scale, HOVER_TWEEN_DURATION)
	tween.tween_property(card, "position:y", target_y, HOVER_TWEEN_DURATION)
	if is_teleop:
		_teleop_tween = tween
	else:
		_ego_tween = tween


# 简单的透明度补间，用于淡化另一张卡片
func _animate_card_modulate(card: Button, target: Color) -> void:
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_BACK)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "modulate", target, HOVER_TWEEN_DURATION)


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


# 卡片样式：悬浮时边框转为强调色
func _card_style(highlighted: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL_BG
	style.border_color = COL_ACCENT if highlighted else COL_CARD_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	return style


# -----------------------------------------------------------------------------
# 内部类：卡片图标，用 _draw 程序化绘制
# -----------------------------------------------------------------------------
enum _IconKind { TELEOP, EGO }


class _CardIcon:
	extends Control

	var kind: int = 0

	func _draw() -> void:
		var accent := Color(1.0, 0.647, 0.169, 0.98)
		var area := size
		var cx := area.x * 0.5
		var cy := area.y * 0.5
		var half := 40.0
		# 以中心为基准的 80x80 绘制区域
		var left := cx - half
		var right := cx + half
		var top := cy - half
		var bottom := cy + half
		if kind == 0:
			# Teleop：Z 形机械臂——左下 → 右中 → 左上 → 末端小圆
			var p0 := Vector2(left + 8.0, bottom - 8.0)
			var p1 := Vector2(right - 8.0, cy)
			var p2 := Vector2(left + 10.0, top + 14.0)
			var p3 := Vector2(left + 22.0, top + 4.0)
			draw_line(p0, p1, accent, 6.0, true)
			draw_line(p1, p2, accent, 6.0, true)
			draw_line(p2, p3, accent, 6.0, true)
			draw_circle(p3, 6.5, accent)
			# 关节小圆点，增强机械感
			draw_circle(p1, 3.5, accent)
		else:
			# Ego：相机机身 + 镜头 + 高光
			var body_rect := Rect2(
				Vector2(left + 6.0, top + 18.0),
				Vector2(area.x - 12.0 - (area.x - 80.0), 56.0),
			)
			# 以 80x80 内部计算，避免控件实际尺寸不同
			body_rect = Rect2(Vector2(left + 6.0, top + 18.0), Vector2(68.0, 56.0))
			_draw_rounded_rect_outline(body_rect, 10.0, accent, 6.0)
			# 顶部取景器凸起
			var viewfinder := Rect2(Vector2(left + 22.0, top + 8.0), Vector2(20.0, 12.0))
			_draw_rounded_rect_outline(viewfinder, 4.0, accent, 5.0)
			# 镜头
			var lens_center := Vector2(cx, cy + 6.0)
			draw_arc(lens_center, 14.0, 0.0, TAU, 32, accent, 5.0, true)
			# 高光
			draw_circle(lens_center + Vector2(-4.0, -4.0), 3.0, accent)

	# 用 4 条线模拟圆角矩形轮廓
	func _draw_rounded_rect_outline(rect: Rect2, _radius: float, color: Color, width: float) -> void:
		var x0 := rect.position.x
		var y0 := rect.position.y
		var x1 := rect.position.x + rect.size.x
		var y1 := rect.position.y + rect.size.y
		var r := minf(_radius, minf(rect.size.x, rect.size.y) * 0.5)
		draw_line(Vector2(x0 + r, y0), Vector2(x1 - r, y0), color, width, true)
		draw_line(Vector2(x1, y0 + r), Vector2(x1, y1 - r), color, width, true)
		draw_line(Vector2(x0 + r, y1), Vector2(x1 - r, y1), color, width, true)
		draw_line(Vector2(x0, y0 + r), Vector2(x0, y1 - r), color, width, true)
		# 圆角弧线
		draw_arc(Vector2(x0 + r, y0 + r), r, PI, PI * 1.5, 8, color, width, true)
		draw_arc(Vector2(x1 - r, y0 + r), r, PI * 1.5, TAU, 8, color, width, true)
		draw_arc(Vector2(x1 - r, y1 - r), r, 0.0, PI * 0.5, 8, color, width, true)
		draw_arc(Vector2(x0 + r, y1 - r), r, PI * 0.5, PI, 8, color, width, true)


# -----------------------------------------------------------------------------
# 内部类：背景流光条——水平移动的细高光，3 秒循环
# -----------------------------------------------------------------------------
class _LightBar:
	extends Control

	const LOOP_SECONDS := 3.0
	const BAR_WIDTH := 120.0
	const BAR_HEIGHT := 3.0
	const BAR_COLOR := Color(1.0, 0.647, 0.169, 0.22)

	var _t: float = 0.0

	func _process(delta: float) -> void:
		_t = fmod(_t + delta, LOOP_SECONDS)
		queue_redraw()

	func _draw() -> void:
		if size.x <= 0.0 or size.y <= 0.0:
			return
		var progress := _t / LOOP_SECONDS
		var travel := size.x + BAR_WIDTH
		var x := -BAR_WIDTH + travel * progress
		var y := size.y * 0.5 - BAR_HEIGHT * 0.5
		var rect := Rect2(Vector2(x, y), Vector2(BAR_WIDTH, BAR_HEIGHT))
		# 三段渐变近似：左右淡出，中间最亮
		var seg := BAR_WIDTH / 6.0
		var fade_l := BAR_COLOR
		fade_l.a = BAR_COLOR.a * 0.15
		var fade_m := BAR_COLOR
		var fade_r := BAR_COLOR
		fade_r.a = BAR_COLOR.a * 0.15
		draw_rect(Rect2(rect.position, Vector2(seg, BAR_HEIGHT)), fade_l, true)
		draw_rect(Rect2(rect.position + Vector2(seg, 0.0), Vector2(BAR_WIDTH - seg * 2.0, BAR_HEIGHT)), fade_m, true)
		draw_rect(Rect2(rect.position + Vector2(BAR_WIDTH - seg, 0.0), Vector2(seg, BAR_HEIGHT)), fade_r, true)
