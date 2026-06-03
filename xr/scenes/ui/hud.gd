extends Node3D
## In-VR HUD overlay rendered as a "cockpit strip" of compact status badges.
##
## 外部 API (保持不变):
##   set_status(text)         — 主连接/状态文本
##   set_platform(platform)   — 平台名
##   set_tracking_mode(mode)  — 追踪模式描述
##   get_fps() -> float

# -----------------------------------------------------------------------------
# 配色常量
# -----------------------------------------------------------------------------
const COLOR_BG: Color = Color(0.05, 0.06, 0.08, 0.6)
const COLOR_TEXT: Color = Color(0.92, 0.94, 0.96, 1.0)
const COLOR_OK: Color = Color(0.55, 0.80, 0.66)
const COLOR_WARN: Color = Color(0.95, 0.78, 0.30)
const COLOR_BAD: Color = Color(0.85, 0.36, 0.36)
const COLOR_GRAY: Color = Color(0.40, 0.42, 0.45)


# =============================================================================
# 内部 Control 子类
# =============================================================================

## 心跳点：根据连接状态以不同频率脉动 alpha
class HeartbeatDot:
	extends Control

	var color: Color = Color(0.55, 0.80, 0.66)
	var frequency: float = 1.0  # Hz
	var _alpha: float = 1.0

	func _ready() -> void:
		custom_minimum_size = Vector2(24, 24)

	func _process(_delta: float) -> void:
		var t: float = float(Time.get_ticks_msec()) / 1000.0
		# sin -> [-1, 1] -> [0, 1] -> [0.4, 1.0]
		var s: float = (sin(t * TAU * frequency) + 1.0) * 0.5
		_alpha = lerp(0.4, 1.0, s)
		queue_redraw()

	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var r: float = min(size.x, size.y) * 0.35
		# 外层光晕
		var glow: Color = color
		glow.a = _alpha * 0.25
		draw_circle(c, r * 1.7, glow)
		# 主点
		var main_c: Color = color
		main_c.a = _alpha
		draw_circle(c, r, main_c)


## FPS 柱状图图标：三条递增高度的小竖条
class FpsIcon:
	extends Control

	var color: Color = Color(0.92, 0.94, 0.96, 1.0)

	func _ready() -> void:
		custom_minimum_size = Vector2(24, 24)

	func set_tint(c: Color) -> void:
		color = c
		queue_redraw()

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		var bar_w: float = w * 0.18
		var gap: float = (w - bar_w * 3.0) * 0.5
		var heights: Array = [0.4, 0.65, 0.95]
		var x: float = gap * 0.5
		for i in range(3):
			var bh: float = h * float(heights[i])
			var y: float = h - bh - h * 0.05
			draw_rect(Rect2(Vector2(x, y), Vector2(bar_w, bh)), color, true)
			x += bar_w + gap * 0.5


## 平台图标：圆角矩形 (类设备/手机轮廓)
class PlatformIcon:
	extends Control

	var color: Color = Color(0.92, 0.94, 0.96, 1.0)

	func _ready() -> void:
		custom_minimum_size = Vector2(24, 24)

	func _draw() -> void:
		var pad: float = size.x * 0.18
		var rect: Rect2 = Rect2(Vector2(pad, pad * 0.6),
				Vector2(size.x - pad * 2.0, size.y - pad * 1.2))
		# 描边圆角矩形 (无原生圆角，用多段组合简化为粗描边矩形)
		draw_rect(rect, color, false, 2.0)
		# 顶部听筒条
		var ear_w: float = rect.size.x * 0.35
		var ear: Rect2 = Rect2(
				Vector2(rect.position.x + (rect.size.x - ear_w) * 0.5,
						rect.position.y + 3.0),
				Vector2(ear_w, 2.0))
		draw_rect(ear, color, true)
		# 底部 home 点
		var dot_c: Vector2 = Vector2(
				rect.position.x + rect.size.x * 0.5,
				rect.position.y + rect.size.y - 3.0)
		draw_circle(dot_c, 1.5, color)


## 追踪指示器：三段 H / L / R 横条，绿色=正常 灰色=丢失
class TrackingIcon:
	extends Control

	# 内部类无法访问脚本级常量, 这里复制一份
	const _C_OK: Color = Color(0.55, 0.80, 0.66)
	const _C_GRAY: Color = Color(0.40, 0.42, 0.45)

	var head_ok: bool = true
	var left_ok: bool = true
	var right_ok: bool = true

	func _ready() -> void:
		custom_minimum_size = Vector2(54, 24)

	func set_state(h: bool, l: bool, r: bool) -> void:
		head_ok = h
		left_ok = l
		right_ok = r
		queue_redraw()

	func _draw() -> void:
		var labels: Array = ["H", "L", "R"]
		var states: Array = [head_ok, left_ok, right_ok]
		var col_w: float = size.x / 3.0
		var seg_h: float = size.y * 0.28
		var font: Font = get_theme_default_font()
		var font_size: int = 10
		for i in range(3):
			var col: Color = _C_OK if states[i] else _C_GRAY
			var cx: float = col_w * (float(i) + 0.5)
			# 横条
			var bar_w: float = col_w * 0.7
			var bar: Rect2 = Rect2(
					Vector2(cx - bar_w * 0.5, size.y * 0.18),
					Vector2(bar_w, seg_h))
			draw_rect(bar, col, true)
			# 字母标签
			if font:
				var s: String = labels[i]
				var text_size: Vector2 = font.get_string_size(s,
						HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
				var pos: Vector2 = Vector2(
						cx - text_size.x * 0.5,
						size.y - 2.0)
				draw_string(font, pos, s,
						HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, col)


# =============================================================================
# HUD 状态
# =============================================================================

## FPS 计算
var _frame_count: int = 0
var _fps_timer: float = 0.0
var _current_fps: float = 0.0

## 文本状态
var _status_text: String = ""
var _platform_text: String = ""
var _tracking_text: String = ""

## 子控件引用 (运行时构建)
var _root_panel: PanelContainer = null
var _heartbeat: HeartbeatDot = null
var _status_label: Label = null
var _fps_icon: FpsIcon = null
var _fps_label: Label = null
var _platform_icon: PlatformIcon = null
var _platform_label: Label = null
var _tracking_icon: TrackingIcon = null

## 离线检测正则 (大小写不敏感)
var _offline_regex: RegEx = null


func _ready() -> void:
	_status_text = tr("UI_INITIALIZING")
	_platform_text = tr("UI_PLATFORM_DETECTING")
	_tracking_text = tr("UI_TRACKING_UNKNOWN")

	_offline_regex = RegEx.new()
	# 任一关键字命中即视为离线/初始化状态
	_offline_regex.compile("(?i)disconnect|未连接|链路中断|^Not |init")

	_build_ui()
	_apply_status(_status_text)
	_apply_platform(_platform_text)
	_apply_tracking(_tracking_text)
	_apply_fps(_current_fps)


func _process(delta: float) -> void:
	# FPS 计数
	_frame_count += 1
	_fps_timer += delta
	if _fps_timer >= 1.0:
		_current_fps = float(_frame_count) / _fps_timer
		_frame_count = 0
		_fps_timer = 0.0
		_apply_fps(_current_fps)


# -----------------------------------------------------------------------------
# 公共 API (保持签名)
# -----------------------------------------------------------------------------

## Set the main status text.
func set_status(text: String) -> void:
	_status_text = text
	_apply_status(text)


## Set the platform name.
func set_platform(platform: String) -> void:
	_platform_text = platform
	_apply_platform(platform)


## Set the tracking mode description.
func set_tracking_mode(mode: String) -> void:
	_tracking_text = mode
	_apply_tracking(mode)


## Get current FPS.
func get_fps() -> float:
	return _current_fps


# -----------------------------------------------------------------------------
# UI 构建
# -----------------------------------------------------------------------------

func _build_ui() -> void:
	var viewport: SubViewport = $SubViewport

	# 圆角半透明背景
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = COLOR_BG
	style.corner_radius_top_left = 18
	style.corner_radius_top_right = 18
	style.corner_radius_bottom_left = 18
	style.corner_radius_bottom_right = 18
	style.border_width_left = 0
	style.border_width_right = 0
	style.border_width_top = 0
	style.border_width_bottom = 0
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10

	_root_panel = PanelContainer.new()
	_root_panel.name = "CockpitPanel"
	_root_panel.add_theme_stylebox_override("panel", style)
	_root_panel.anchor_right = 1.0
	_root_panel.anchor_bottom = 1.0
	_root_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	viewport.add_child(_root_panel)

	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 20)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_root_panel.add_child(hbox)

	# --- 连接徽章 ---
	var badge_conn: HBoxContainer = _make_badge_row()
	_heartbeat = HeartbeatDot.new()
	_heartbeat.color = COLOR_OK
	badge_conn.add_child(_heartbeat)
	_status_label = _make_label()
	badge_conn.add_child(_status_label)
	hbox.add_child(badge_conn)

	hbox.add_child(_make_separator())

	# --- FPS 徽章 ---
	var badge_fps: HBoxContainer = _make_badge_row()
	_fps_icon = FpsIcon.new()
	badge_fps.add_child(_fps_icon)
	_fps_label = _make_label()
	badge_fps.add_child(_fps_label)
	hbox.add_child(badge_fps)

	hbox.add_child(_make_separator())

	# --- 平台徽章 ---
	var badge_plat: HBoxContainer = _make_badge_row()
	_platform_icon = PlatformIcon.new()
	badge_plat.add_child(_platform_icon)
	_platform_label = _make_label()
	badge_plat.add_child(_platform_label)
	hbox.add_child(badge_plat)

	hbox.add_child(_make_separator())

	# --- 追踪徽章 (无独立文本, 三段彩条自带 H/L/R 标签) ---
	var badge_track: HBoxContainer = _make_badge_row()
	_tracking_icon = TrackingIcon.new()
	badge_track.add_child(_tracking_icon)
	hbox.add_child(badge_track)


func _make_badge_row() -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	return row


func _make_label() -> Label:
	var lbl: Label = Label.new()
	lbl.add_theme_color_override("font_color", COLOR_TEXT)
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


func _make_separator() -> Control:
	# 细竖线分隔, 仅作视觉用
	var sep: ColorRect = ColorRect.new()
	sep.color = Color(1, 1, 1, 0.12)
	sep.custom_minimum_size = Vector2(1, 22)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return sep


# -----------------------------------------------------------------------------
# 状态 -> UI 同步
# -----------------------------------------------------------------------------

func _apply_status(text: String) -> void:
	if _status_label:
		_status_label.text = text
	if _heartbeat:
		var offline: bool = _is_offline(text)
		_heartbeat.color = COLOR_BAD if offline else COLOR_OK
		_heartbeat.frequency = 0.4 if offline else 1.0


func _apply_platform(platform: String) -> void:
	if _platform_label:
		_platform_label.text = platform


func _apply_tracking(mode: String) -> void:
	if not _tracking_icon:
		return
	var lower: String = mode.to_lower()
	var head_ok: bool = true
	var left_ok: bool = true
	var right_ok: bool = true
	if mode.is_empty() \
			or lower.find("lost") != -1 \
			or mode.find("丢失") != -1 \
			or lower.find("unknown") != -1 \
			or mode.find("未知") != -1:
		head_ok = false
		left_ok = false
		right_ok = false
	elif lower.find("head only") != -1:
		head_ok = true
		left_ok = false
		right_ok = false
	elif lower.find("left lost") != -1:
		head_ok = true
		left_ok = false
		right_ok = true
	elif lower.find("right lost") != -1:
		head_ok = true
		left_ok = true
		right_ok = false
	_tracking_icon.set_state(head_ok, left_ok, right_ok)


func _apply_fps(fps: float) -> void:
	if not _fps_label:
		return
	# 优先用 i18n key, 缺失则回退到字面量
	var fmt: String = tr("UI_FPS_VALUE")
	if fmt == "UI_FPS_VALUE":
		fmt = "%.0f FPS"
	_fps_label.text = fmt % fps

	var color: Color = COLOR_OK
	if fps < 60.0:
		color = COLOR_BAD
	elif fps < 72.0:
		color = COLOR_WARN
	_fps_label.add_theme_color_override("font_color", color)
	if _fps_icon:
		_fps_icon.set_tint(color)


# -----------------------------------------------------------------------------
# 辅助
# -----------------------------------------------------------------------------

func _is_offline(text: String) -> bool:
	if text.is_empty():
		return true
	if _offline_regex == null:
		return false
	return _offline_regex.search(text) != null
