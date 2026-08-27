extends "res://scripts/ui/composition_viewport_ui.gd"
class_name HandUnlockButton

signal toggled(unlocked: bool)

const VIEWPORT_SIZE := Vector2i(240, 120)
const BUTTON_SIZE := Vector2(216.0, 92.0)
const QUAD_SIZE := Vector2(0.075, 0.038)
const LOCKED_COLOR := Color(0.06, 0.30, 0.12, 0.96)
const UNLOCKED_COLOR := Color(0.55, 0.23, 0.03, 0.98)
const UNAVAILABLE_COLOR := Color(0.12, 0.13, 0.15, 0.88)
const PRESS_HALF_SIZE := Vector2(0.030, 0.014)
const HOVER_HALF_SIZE := Vector2(0.038, 0.021)
const PRESS_DISTANCE_M := 0.008
const ARM_MAX_DISTANCE_M := 0.050
const RELEASE_DISTANCE_M := 0.026
const PRESS_COOLDOWN_SEC := 0.40
const TRIGGER_FLASH_SEC := 0.18
const WRIST_UI_ROTATION_RAD := -PI * 0.5
const BUTTON_BASE_POSITION := Vector2(12.0, 14.0)
const BUTTON_PRESSED_OFFSET := Vector2(0.0, 6.0)

var _button: Button
var _glow: Panel
var _flash: Panel
var _unlocked := false
var _available := false
var _touch_pressed := false
var _cooldown := 0.0
var _flash_remaining := 0.0


func _init() -> void:
	var viewport := _setup_viewport_layer(
		"HandUnlockButtonViewport", VIEWPORT_SIZE, QUAD_SIZE, 3, 10.0
	)
	_build_button(viewport)
	visible = false


func _ready() -> void:
	# This control is intentionally direct-touch only. It keeps the same
	# high-quality composition-layer rendering as the Settings button, but never
	# participates in OperatorInteraction's ray/pinch target collection.
	remove_from_group(TARGET_GROUP)


func _build_button(viewport: SubViewport) -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(root)

	_glow = Panel.new()
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.position = BUTTON_BASE_POSITION - Vector2(5.0, 5.0)
	_glow.size = BUTTON_SIZE + Vector2(10.0, 10.0)
	_glow.add_theme_stylebox_override("panel", _glow_style(Color(0.35, 1.0, 0.48, 0.85)))
	_glow.visible = false
	root.add_child(_glow)

	_button = Button.new()
	_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_button.position = BUTTON_BASE_POSITION
	_button.size = BUTTON_SIZE
	_button.custom_minimum_size = BUTTON_SIZE
	_button.pivot_offset = BUTTON_SIZE * 0.5
	_button.add_theme_font_size_override("font_size", 38)
	_button.add_theme_color_override("font_color", Color.WHITE)
	_button.add_theme_color_override("font_disabled_color", Color(0.62, 0.64, 0.68, 1.0))
	_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	root.add_child(_button)

	_flash = Panel.new()
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.position = BUTTON_BASE_POSITION - Vector2(3.0, 3.0)
	_flash.size = BUTTON_SIZE + Vector2(6.0, 6.0)
	_flash.add_theme_stylebox_override("panel", _flash_style())
	_flash.visible = false
	root.add_child(_flash)
	_refresh()


func update_direct_touch(
		button_transform: Variant,
		fingertip_position: Variant,
		unlocked: bool,
		available: bool,
		delta: float
) -> void:
	_unlocked = unlocked
	_available = available
	_cooldown = maxf(_cooldown - maxf(delta, 0.0), 0.0)
	_flash_remaining = maxf(_flash_remaining - maxf(delta, 0.0), 0.0)

	if not button_transform is Transform3D:
		visible = false
		_reset_touch()
		_refresh()
		return

	transform = display_transform(button_transform as Transform3D)
	visible = true
	if not available or not fingertip_position is Vector3:
		_reset_touch()
		_refresh()
		return

	var local_tip := transform.affine_inverse() * (fingertip_position as Vector3)
	if _touch_pressed:
		if touch_released(local_tip):
			_touch_pressed = false
			_refresh()
		else:
			_refresh("triggered")
		return
	var phase := touch_phase(local_tip)
	if should_trigger_touch(phase, _touch_pressed, _cooldown):
		_touch_pressed = true
		_cooldown = PRESS_COOLDOWN_SEC
		_flash_remaining = TRIGGER_FLASH_SEC
		_unlocked = not _unlocked
		_play_feedback("click", 0.0, self)
		toggled.emit(_unlocked)
	_refresh("triggered" if _touch_pressed else phase)


func cancel_touch() -> void:
	_reset_touch()


func _reset_touch() -> void:
	_touch_pressed = false


func _refresh(phase: String = "idle") -> void:
	if _button == null:
		return
	_button.text = status_text(_unlocked, _available)
	var base_color := status_color(_unlocked, _available)
	var hovered := phase == "arm" or phase == "press"
	if hovered and _available:
		base_color = base_color.lightened(0.18)
	_button.add_theme_stylebox_override("normal", _button_style(base_color))
	_button.add_theme_stylebox_override("disabled", _button_style(UNAVAILABLE_COLOR))
	_button.position = BUTTON_BASE_POSITION
	_button.scale = visual_scale_for_phase(phase)
	if phase == "press" or phase == "triggered":
		_button.position += BUTTON_PRESSED_OFFSET
	_glow.visible = hovered and _available
	if _glow.visible:
		var glow_color := Color(1.0, 0.72, 0.24, 0.95) if phase == "press" \
			else Color(0.35, 1.0, 0.48, 0.88)
		_glow.add_theme_stylebox_override("panel", _glow_style(glow_color))
	_flash.visible = _flash_remaining > 0.0
	if _flash.visible:
		_flash.modulate.a = clampf(_flash_remaining / TRIGGER_FLASH_SEC, 0.0, 1.0)


func _button_style(bg_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.border_color = (
		Color(1.0, 0.647, 0.169, 0.95)
		if _unlocked
		else Color(0.35, 1.0, 0.48, 0.95)
	)
	style.set_border_width_all(3)
	style.set_corner_radius_all(18)
	return style


func _glow_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color.r, color.g, color.b, 0.10)
	style.border_color = color
	style.set_border_width_all(5)
	style.set_corner_radius_all(22)
	return style


func _flash_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.95, 0.55, 0.18)
	style.border_color = Color(1.0, 0.95, 0.65, 1.0)
	style.set_border_width_all(7)
	style.set_corner_radius_all(22)
	return style


static func touch_phase(local_tip: Vector3) -> String:
	var distance_to_plane := absf(local_tip.z)
	var in_press_bounds := (
		absf(local_tip.x) <= PRESS_HALF_SIZE.x
		and absf(local_tip.y) <= PRESS_HALF_SIZE.y
	)
	var in_hover_bounds := (
		absf(local_tip.x) <= HOVER_HALF_SIZE.x
		and absf(local_tip.y) <= HOVER_HALF_SIZE.y
	)
	if in_press_bounds and distance_to_plane <= PRESS_DISTANCE_M:
		return "press"
	if in_hover_bounds and distance_to_plane > PRESS_DISTANCE_M \
			and distance_to_plane <= ARM_MAX_DISTANCE_M:
		return "arm"
	return "inside"


static func touch_released(local_tip: Vector3) -> bool:
	return (
		absf(local_tip.x) > HOVER_HALF_SIZE.x
		or absf(local_tip.y) > HOVER_HALF_SIZE.y
		or absf(local_tip.z) >= RELEASE_DISTANCE_M
	)


static func visual_scale_for_phase(phase: String) -> Vector2:
	match phase:
		"arm":
			return Vector2(1.035, 1.035)
		"press", "triggered":
			return Vector2(0.94, 0.88)
		_:
			return Vector2.ONE


static func should_trigger_touch(phase: String, pressed: bool, cooldown: float) -> bool:
	return phase == "press" and not pressed and cooldown <= 0.0


static func display_transform(source: Transform3D) -> Transform3D:
	var clockwise := Basis(Vector3.BACK, WRIST_UI_ROTATION_RAD)
	return source * Transform3D(clockwise, Vector3.ZERO)


static func status_text(unlocked: bool, available: bool) -> String:
	if not available:
		return "未连接"
	return "锁定" if unlocked else "解锁"


static func status_color(unlocked: bool, available: bool) -> Color:
	if not available:
		return UNAVAILABLE_COLOR
	return UNLOCKED_COLOR if unlocked else LOCKED_COLOR
