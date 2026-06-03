extends "res://scripts/ui/composition_viewport_ui.gd"
class_name BaseSettingsPanel

signal confirmed
signal exit_requested

const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_SECTION := Color(0.65, 0.70, 0.75)
const COL_STATUS := Color(0.55, 0.80, 0.66)
const EXIT_HOLD_SECONDS := 2.0
const ACTION_BUTTON_HEIGHT := 68
const ACTION_BUTTON_MIN_WIDTH := 260
const ICON_PATH := "res://assets/icons/%s.svg"

class HoldIndicator:
	extends Control

	# 橙色到红色渐变 + 完成时的白色闪光
	const COL_ORANGE := Color(1.0, 0.647, 0.169)
	const COL_RED := Color(1.0, 0.30, 0.20)
	const FLASH_DURATION := 0.08

	var progress := 0.0
	# 闪光衰减计时，>0 时绘制白色填充圆
	var _flash_remaining := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 默认关闭 _process，仅在闪光时启用以节省开销
		set_process(false)

	func set_progress(value: float) -> void:
		var prev := progress
		progress = clampf(value, 0.0, 1.0)
		# 进度刚好达到 1.0 时触发一帧闪光
		if progress >= 0.999 and prev < 0.999:
			_flash_remaining = FLASH_DURATION
			set_process(true)
		queue_redraw()

	func _process(delta: float) -> void:
		# 闪光衰减：到 0 后关闭 _process 并刷新
		if _flash_remaining <= 0.0:
			set_process(false)
			return
		_flash_remaining -= delta
		if _flash_remaining <= 0.0:
			_flash_remaining = 0.0
			set_process(false)
		queue_redraw()

	func _draw() -> void:
		if progress <= 0.0 and _flash_remaining <= 0.0:
			return
		# 环形进度几何
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.42
		# 底环：暗淡的橙色作为背景
		var base_color := Color(COL_ORANGE.r, COL_ORANGE.g, COL_ORANGE.b, 0.22)
		draw_arc(center, radius, 0.0, TAU, 64, base_color, 3.0, true)
		# 进度弧：从顶部 (-PI/2) 顺时针填充
		if progress > 0.0:
			var prog_color := COL_ORANGE.lerp(COL_RED, progress)
			var start_angle := -PI * 0.5
			var end_angle := start_angle + TAU * progress
			draw_arc(center, radius, start_angle, end_angle, 64, prog_color, 4.5, true)
		# 完成闪光：白色填充圆
		if _flash_remaining > 0.0:
			draw_circle(center, radius * 0.55, Color(1.0, 1.0, 1.0, 0.85))

var _content: VBoxContainer
var _highlighted_slot: PanelContainer
var _exit_indicator: HoldIndicator
var _exit_holding := false
var _exit_hold_seconds := 0.0
# 内部 PanelContainer，用于 open/close 缩放与淡入淡出动效
var _panel: PanelContainer
# 当前激活的开/关补间，避免并发冲突
var _panel_tween: Tween
var _icon_cache: Dictionary = {}


func _setup_settings_panel(
		viewport_size: Vector2i,
		quad_size_m: Vector2,
		title_key: String,
		confirm_key: String,
		layer_sort_order: int = 2,
		initial_visible: bool = true
) -> void:
	var viewport := _setup_viewport_layer("SettingsViewport", viewport_size, quad_size_m, layer_sort_order, 18.0)
	_build_panel(viewport, title_key, confirm_key)
	visible = initial_visible


func _process(delta: float) -> void:
	if not _exit_holding:
		return
	_exit_hold_seconds = minf(_exit_hold_seconds + delta, EXIT_HOLD_SECONDS)
	var hold_ratio := _exit_hold_seconds / EXIT_HOLD_SECONDS
	if _exit_indicator:
		_exit_indicator.set_progress(hold_ratio)
	if _exit_hold_seconds < EXIT_HOLD_SECONDS:
		return
	_play_ui_sound("confirm")
	_cancel_exit_hold()
	exit_requested.emit()


func open() -> void:
	# 开启面板：缩放 + 淡入
	visible = true
	_play_ui_sound("hover")
	if _panel == null:
		return
	# 取消上一次进行中的补间
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
	# pivot 需要在面板尺寸就绪后再设置，故延迟一帧执行
	call_deferred("_play_open_tween")


func close() -> void:
	clear_pointer()
	if _panel == null:
		visible = false
		return
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
	_apply_pivot()
	_panel_tween = _panel.create_tween()
	_panel_tween.set_parallel(true)
	_panel_tween.set_trans(Tween.TRANS_BACK)
	_panel_tween.set_ease(Tween.EASE_IN)
	_panel_tween.tween_property(_panel, "scale", Vector2(0.9, 0.9), 0.15)
	_panel_tween.tween_property(_panel, "modulate:a", 0.0, 0.15)
	_panel_tween.chain().tween_callback(Callable(self, "_on_close_tween_finished"))


func _play_open_tween() -> void:
	# 在面板布局完成后再启动开启补间
	if _panel == null:
		return
	_apply_pivot()
	_panel.scale = Vector2(0.9, 0.9)
	_panel.modulate.a = 0.0
	_panel_tween = _panel.create_tween()
	_panel_tween.set_parallel(true)
	_panel_tween.set_trans(Tween.TRANS_BACK)
	_panel_tween.set_ease(Tween.EASE_OUT)
	_panel_tween.tween_property(_panel, "scale", Vector2(1.0, 1.0), 0.25)
	_panel_tween.tween_property(_panel, "modulate:a", 1.0, 0.25)


func _apply_pivot() -> void:
	# pivot 必须设为面板中心，否则缩放会从左上角发生
	if _panel == null:
		return
	_panel.pivot_offset = _panel.size * 0.5


func _on_close_tween_finished() -> void:
	visible = false


func add_section_label(text_key: String) -> Label:
	var lbl := Label.new()
	lbl.text = tr(text_key)
	lbl.add_theme_font_size_override("font_size", 21)
	lbl.add_theme_color_override("font_color", COL_SECTION)
	_content.add_child(lbl)
	return lbl


func add_status_label(initial_text: String = "") -> Label:
	var lbl := Label.new()
	lbl.text = initial_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COL_STATUS)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(lbl)
	return lbl


func add_interactive(parent: Container, control: Control) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.add_theme_stylebox_override("panel", _interactive_style(false))
	control.mouse_entered.connect(_on_interactive_mouse_entered.bind(slot))
	control.mouse_exited.connect(_on_interactive_mouse_exited.bind(slot))
	if control is CheckButton:
		(control as CheckButton).toggled.connect(func(enabled: bool) -> void:
			_play_ui_sound("toggle_on" if enabled else "toggle_off")
		)
	elif control is Button:
		(control as Button).pressed.connect(func() -> void: _play_ui_sound("click"))
	slot.add_child(control)
	parent.add_child(slot)
	return slot


func add_toggle(parent: Container, label: String, default_on: bool = true, font_size: int = 23) -> CheckButton:
	var toggle := CheckButton.new()
	toggle.text = label
	toggle.button_pressed = default_on
	toggle.custom_minimum_size.y = 47
	toggle.add_theme_font_size_override("font_size", font_size)
	add_interactive(parent, toggle)
	return toggle


func _build_settings_content(_parent: VBoxContainer) -> void:
	pass


func _on_confirm_requested() -> void:
	confirmed.emit()


func _on_pointer_cleared() -> void:
	_cancel_exit_hold()
	_set_highlighted_slot(null)


func _build_panel(viewport: SubViewport, title_key: String, confirm_key: String) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 保存引用以便 open/close 做缩放与淡入淡出动效
	_panel = panel
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = COL_PANEL_BG
	panel_style.border_color = COL_PANEL_BORDER
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", panel_style)
	viewport.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 38)
	margin.add_theme_constant_override("margin_right", 38)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	panel.add_child(margin)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 14)
	margin.add_child(_content)

	var title := Label.new()
	title.text = tr(title_key)
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", COL_TITLE)
	_content.add_child(title)

	_build_settings_content(_content)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(spacer)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 14)
	actions.custom_minimum_size.y = ACTION_BUTTON_HEIGHT
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(actions)

	var confirm_button := Button.new()
	confirm_button.text = tr(confirm_key)
	_apply_button_icon(confirm_button, "check")
	confirm_button.clip_text = true
	confirm_button.custom_minimum_size = Vector2(ACTION_BUTTON_MIN_WIDTH, ACTION_BUTTON_HEIGHT)
	confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_button.add_theme_font_size_override("font_size", 28)
	confirm_button.pressed.connect(_on_confirm_button_pressed)
	_configure_action_slot(add_interactive(actions, confirm_button))

	var exit_button := Button.new()
	exit_button.text = tr("UI_EXIT")
	_apply_button_icon(exit_button, "power")
	exit_button.clip_text = true
	exit_button.custom_minimum_size = Vector2(ACTION_BUTTON_MIN_WIDTH, ACTION_BUTTON_HEIGHT)
	exit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exit_button.add_theme_font_size_override("font_size", 28)
	exit_button.button_down.connect(_on_exit_button_down)
	exit_button.button_up.connect(_on_exit_button_up)
	exit_button.mouse_exited.connect(_on_exit_mouse_exited)
	var exit_slot := add_interactive(actions, exit_button)
	_configure_action_slot(exit_slot)
	_exit_indicator = HoldIndicator.new()
	_exit_indicator.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	exit_slot.add_child(_exit_indicator)


func _configure_action_slot(slot: PanelContainer) -> void:
	slot.custom_minimum_size = Vector2(ACTION_BUTTON_MIN_WIDTH, ACTION_BUTTON_HEIGHT)
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.size_flags_stretch_ratio = 1.0


func _on_confirm_button_pressed() -> void:
	_play_ui_sound("confirm")
	_cancel_exit_hold()
	_on_confirm_requested()


func _on_exit_button_down() -> void:
	_cancel_exit_hold()
	_play_ui_sound("exit_charging", -4.0)
	_exit_holding = true


func _on_exit_button_up() -> void:
	_cancel_exit_hold()


func _on_exit_mouse_exited() -> void:
	_cancel_exit_hold()


func _cancel_exit_hold() -> void:
	_exit_holding = false
	_exit_hold_seconds = 0.0
	if _exit_indicator:
		_exit_indicator.set_progress(0.0)


func _on_interactive_mouse_entered(slot: PanelContainer) -> void:
	_play_ui_sound("hover", -5.0)
	_set_highlighted_slot(slot)


func _on_interactive_mouse_exited(slot: PanelContainer) -> void:
	if _highlighted_slot == slot:
		_set_highlighted_slot(null)


func _set_highlighted_slot(slot: PanelContainer) -> void:
	if _highlighted_slot == slot:
		return
	if _highlighted_slot != null:
		_highlighted_slot.add_theme_stylebox_override("panel", _interactive_style(false))
	_highlighted_slot = slot
	if _highlighted_slot != null:
		_highlighted_slot.add_theme_stylebox_override("panel", _interactive_style(true))


func _interactive_style(highlighted: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	style.border_color = COL_ACCENT if highlighted else Color.TRANSPARENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	return style


func _apply_button_icon(button: Button, icon_name: String) -> void:
	button.icon = _load_icon(icon_name)
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_constant_override("icon_max_width", 30)


func _load_icon(icon_name: String) -> Texture2D:
	if _icon_cache.has(icon_name):
		return _icon_cache[icon_name]
	var texture: Texture2D = null
	var path := ICON_PATH % icon_name
	if FileAccess.file_exists(path):
		var svg := FileAccess.get_file_as_string(path)
		var image := Image.new()
		if image.load_svg_from_string(svg, 1.0) == OK:
			texture = ImageTexture.create_from_image(image)
	_icon_cache[icon_name] = texture
	return texture


func _play_ui_sound(action: String, volume_db: float = 0.0) -> void:
	_play_feedback(action, volume_db, self)
