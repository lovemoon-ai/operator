extends "res://scripts/ui/composition_viewport_ui.gd"
class_name HandUnlockButton

signal toggled(unlocked: bool)
signal action_triggered(action_id: StringName)

const PalmMenuVisibilityStateScript = preload(
	"res://scripts/ui/palm_menu_visibility_state.gd"
)

const ACTION_TOGGLE_LOCK := &"toggle_hand_lock"
const VIEWPORT_SIZE := Vector2i(320, 176)
const QUAD_SIZE := Vector2(0.104, 0.0572)
const TITLE_RECT := Rect2(18.0, 10.0, 284.0, 38.0)
const BUTTON_RECT := Rect2(18.0, 58.0, 284.0, 100.0)
const LOCKED_COLOR := Color(0.06, 0.30, 0.12, 0.96)
const UNLOCKED_COLOR := Color(0.55, 0.23, 0.03, 0.98)
const UNAVAILABLE_COLOR := Color(0.12, 0.13, 0.15, 0.92)
const PRESS_DISTANCE_M := 0.008
const ARM_MAX_DISTANCE_M := 0.050
const RELEASE_DISTANCE_M := 0.026
const TRIGGER_FLASH_SEC := 0.18
const POSITION_FOLLOW_RATE := 18.0
const ROTATION_FOLLOW_RATE := 14.0
const BUTTON_PRESSED_OFFSET := Vector2(0.0, 7.0)

var _title: Label
var _buttons: Dictionary = {}
var _glows: Dictionary = {}
var _flashes: Dictionary = {}
var _action_rects: Dictionary = {}
var _unlocked := false
var _available := false
var _touch_pressed := false
var _touch_armed := false
var _pressed_action := &""
var _flash_remaining := 0.0
var _flash_action := &""
var _visibility_state := PalmMenuVisibilityStateScript.new()
var _has_smoothed_transform := false


func _init() -> void:
	var viewport := _setup_viewport_layer(
		"HandPalmMenuViewport", VIEWPORT_SIZE, QUAD_SIZE, 3, 10.0
	)
	_build_menu(viewport)
	visible = false


func _ready() -> void:
	remove_from_group(TARGET_GROUP)


func _build_menu(viewport: SubViewport) -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(root)

	_title = Label.new()
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.position = TITLE_RECT.position
	_title.size = TITLE_RECT.size
	_title.text = "手部控制"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 24)
	_title.add_theme_color_override("font_color", Color(0.90, 0.93, 0.97, 1.0))
	_title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.90))
	_title.add_theme_constant_override("outline_size", 7)
	root.add_child(_title)

	_add_action_button(root, ACTION_TOGGLE_LOCK, BUTTON_RECT)
	_refresh()


func _add_action_button(root: Control, action_id: StringName, rect: Rect2) -> void:
	var glow := Panel.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.position = rect.position - Vector2(5.0, 5.0)
	glow.size = rect.size + Vector2(10.0, 10.0)
	glow.add_theme_stylebox_override("panel", _glow_style(Color(0.35, 1.0, 0.48, 0.85)))
	glow.visible = false
	root.add_child(glow)

	var button := Button.new()
	button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.position = rect.position
	button.size = rect.size
	button.custom_minimum_size = rect.size
	button.pivot_offset = rect.size * 0.5
	button.add_theme_font_size_override("font_size", 38)
	button.add_theme_color_override("font_color", Color.WHITE)
	button.add_theme_color_override("font_disabled_color", Color(0.62, 0.64, 0.68, 1.0))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	root.add_child(button)

	var flash := Panel.new()
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.position = rect.position - Vector2(3.0, 3.0)
	flash.size = rect.size + Vector2(6.0, 6.0)
	flash.add_theme_stylebox_override("panel", _flash_style())
	flash.visible = false
	root.add_child(flash)

	_buttons[action_id] = button
	_glows[action_id] = glow
	_flashes[action_id] = flash
	_action_rects[action_id] = rect


func update_palm_menu(
	menu_state: Dictionary,
	head_transform: Variant,
	fingertip_position: Variant,
	unlocked: bool,
	available: bool,
	enabled: bool,
	delta: float,
) -> void:
	_unlocked = unlocked
	_available = available
	_flash_remaining = maxf(_flash_remaining - maxf(delta, 0.0), 0.0)
	if _flash_remaining <= 0.0:
		_flash_action = &""
	if not enabled:
		_visibility_state.reset()
		visible = false
		_has_smoothed_transform = false
		_reset_touch()
		_clear_trigger_feedback()
		_refresh()
		return

	var tracked := bool(menu_state.get("tracked", false))
	var facing := float(menu_state.get("facing", -1.0))
	var openness := float(menu_state.get("openness", 0.0))
	var pose_visible: bool = _visibility_state.update(tracked, facing, openness, delta)
	var anchor_v: Variant = menu_state.get("anchor_position", null)
	if tracked and anchor_v is Vector3 and head_transform is Transform3D:
		_update_smoothed_transform(
			face_head_transform(anchor_v as Vector3, head_transform as Transform3D), delta
		)
	else:
		_has_smoothed_transform = false

	if not pose_visible or not _has_smoothed_transform:
		visible = false
		_reset_touch()
		_refresh()
		return

	visible = true
	var pose_interactive := PalmMenuVisibilityStateScript.meets_exit_pose(facing, openness)
	if not available or not pose_interactive or not fingertip_position is Vector3:
		_reset_touch()
		if not available:
			_clear_trigger_feedback()
		_refresh()
		return

	var local_tip := transform.affine_inverse() * (fingertip_position as Vector3)
	var touch := _touch_state(local_tip)
	var phase := str(touch.get("phase", "idle"))
	var action_id := StringName(touch.get("action", &""))
	if _touch_pressed:
		if _action_touch_released(_pressed_action, local_tip):
			_touch_pressed = false
			_pressed_action = &""
			_touch_armed = true
			_refresh(phase, action_id)
		else:
			_refresh("press", _pressed_action)
		return

	if phase == "arm" or action_id == &"":
		_touch_armed = true
	if should_trigger_armed_touch(phase, _touch_pressed, _touch_armed) and action_id != &"":
		_touch_pressed = true
		_touch_armed = false
		_pressed_action = action_id
		_flash_remaining = TRIGGER_FLASH_SEC
		_flash_action = action_id
		_trigger_action(action_id)
	_refresh("triggered" if _touch_pressed else phase, action_id)


func cancel_touch() -> void:
	_reset_touch()


func reset_menu() -> void:
	_visibility_state.reset()
	visible = false
	_has_smoothed_transform = false
	_reset_touch()
	_clear_trigger_feedback()
	_refresh()


func _reset_touch() -> void:
	_touch_pressed = false
	_touch_armed = false
	_pressed_action = &""


func _clear_trigger_feedback() -> void:
	_flash_remaining = 0.0
	_flash_action = &""


func _update_smoothed_transform(target: Transform3D, delta: float) -> void:
	if not _has_smoothed_transform:
		transform = target
		_has_smoothed_transform = true
		return
	var position_weight := smoothing_weight(POSITION_FOLLOW_RATE, delta)
	var rotation_weight := smoothing_weight(ROTATION_FOLLOW_RATE, delta)
	var position := transform.origin.lerp(target.origin, position_weight)
	var rotation := transform.basis.get_rotation_quaternion().slerp(
		target.basis.get_rotation_quaternion(), rotation_weight
	)
	transform = Transform3D(Basis(rotation), position)


func _trigger_action(action_id: StringName) -> void:
	action_triggered.emit(action_id)
	if action_id == ACTION_TOGGLE_LOCK:
		_unlocked = not _unlocked
		_play_feedback(feedback_event_for_state(_unlocked), 0.0, self)
		toggled.emit(_unlocked)
	else:
		_play_feedback("click", 0.0, self)


func _touch_state(local_tip: Vector3) -> Dictionary:
	var armed_action := &""
	for action_v in _action_rects:
		var action_id := StringName(action_v)
		var rect_v: Variant = _action_rects[action_id]
		if not rect_v is Rect2:
			continue
		var phase := touch_phase_for_rect(local_tip, rect_v as Rect2)
		if phase == "press":
			return {"action": action_id, "phase": phase}
		if phase == "arm":
			armed_action = action_id
	return {"action": armed_action, "phase": "arm" if armed_action != &"" else "idle"}


func _action_touch_released(action_id: StringName, local_tip: Vector3) -> bool:
	var rect_v: Variant = _action_rects.get(action_id, null)
	if not rect_v is Rect2:
		return true
	return touch_released_for_rect(local_tip, rect_v as Rect2)


func _refresh(phase: String = "idle", active_action: StringName = ACTION_TOGGLE_LOCK) -> void:
	for action_v in _buttons:
		var action_id := StringName(action_v)
		var button_v: Variant = _buttons[action_id]
		var glow_v: Variant = _glows.get(action_id, null)
		var flash_v: Variant = _flashes.get(action_id, null)
		var rect_v: Variant = _action_rects.get(action_id, null)
		if not button_v is Button or not glow_v is Panel or not flash_v is Panel \
				or not rect_v is Rect2:
			continue
		var button := button_v as Button
		var glow := glow_v as Panel
		var flash := flash_v as Panel
		var rect := rect_v as Rect2
		button.text = status_text(_unlocked, _available)
		button.disabled = not _available
		var action_phase := phase if active_action == action_id else "idle"
		var base_color := status_color(_unlocked, _available)
		var approached := action_phase == "arm"
		var pressed := action_phase == "press" or action_phase == "triggered"
		if approached and _available:
			base_color = base_color.lightened(0.18)
		elif pressed and _available:
			base_color = base_color.lightened(0.08)
		button.add_theme_stylebox_override("normal", _button_style(base_color))
		button.add_theme_stylebox_override("disabled", _button_style(UNAVAILABLE_COLOR))
		button.position = rect.position
		button.scale = visual_scale_for_phase(action_phase)
		if pressed:
			button.position += BUTTON_PRESSED_OFFSET
		glow.visible = (approached or pressed) and _available
		if glow.visible:
			var glow_color := Color(1.0, 0.72, 0.24, 0.95) if pressed \
				else Color(0.35, 1.0, 0.48, 0.88)
			glow.add_theme_stylebox_override("panel", _glow_style(glow_color))
		flash.visible = action_id == _flash_action and _flash_remaining > 0.0
		if flash.visible:
			flash.modulate.a = clampf(_flash_remaining / TRIGGER_FLASH_SEC, 0.0, 1.0)


func _button_style(bg_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	if not _available:
		style.border_color = Color(0.42, 0.45, 0.50, 0.90)
	else:
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
	return touch_phase_for_rect(local_tip, BUTTON_RECT)


static func touch_phase_for_rect(local_tip: Vector3, rect: Rect2) -> String:
	var center := rect_center_local(rect)
	var offset := local_tip - Vector3(center.x, center.y, 0.0)
	var distance_to_plane := absf(offset.z)
	var press_half_size := rect_half_size_local(rect, 0.82)
	var hover_half_size := rect_half_size_local(rect, 1.08)
	var in_press_bounds := (
		absf(offset.x) <= press_half_size.x and absf(offset.y) <= press_half_size.y
	)
	var in_hover_bounds := (
		absf(offset.x) <= hover_half_size.x and absf(offset.y) <= hover_half_size.y
	)
	if in_press_bounds and distance_to_plane <= PRESS_DISTANCE_M:
		return "press"
	if in_hover_bounds and distance_to_plane > PRESS_DISTANCE_M \
			and distance_to_plane <= ARM_MAX_DISTANCE_M:
		return "arm"
	return "idle"


static func touch_released(local_tip: Vector3) -> bool:
	return touch_released_for_rect(local_tip, BUTTON_RECT)


static func touch_released_for_rect(local_tip: Vector3, rect: Rect2) -> bool:
	var center := rect_center_local(rect)
	var offset := local_tip - Vector3(center.x, center.y, 0.0)
	var hover_half_size := rect_half_size_local(rect, 1.08)
	return (
		absf(offset.x) > hover_half_size.x
		or absf(offset.y) > hover_half_size.y
		or absf(offset.z) >= RELEASE_DISTANCE_M
	)


static func button_center_local() -> Vector2:
	return rect_center_local(BUTTON_RECT)


static func rect_center_local(rect: Rect2) -> Vector2:
	var center_px := rect.position + rect.size * 0.5
	return Vector2(
		(center_px.x / float(VIEWPORT_SIZE.x) - 0.5) * QUAD_SIZE.x,
		(0.5 - center_px.y / float(VIEWPORT_SIZE.y)) * QUAD_SIZE.y,
	)


static func button_half_size_local(scale: float = 1.0) -> Vector2:
	return rect_half_size_local(BUTTON_RECT, scale)


static func rect_half_size_local(rect: Rect2, scale: float = 1.0) -> Vector2:
	return Vector2(
		rect.size.x / float(VIEWPORT_SIZE.x) * QUAD_SIZE.x * 0.5 * scale,
		rect.size.y / float(VIEWPORT_SIZE.y) * QUAD_SIZE.y * 0.5 * scale,
	)


static func visual_scale_for_phase(phase: String) -> Vector2:
	match phase:
		"arm":
			return Vector2(1.035, 1.035)
		"press", "triggered":
			return Vector2(0.94, 0.88)
		_:
			return Vector2.ONE


static func should_trigger_touch(phase: String, pressed: bool, cooldown: float = 0.0) -> bool:
	return phase == "press" and not pressed and cooldown <= 0.0


static func should_trigger_armed_touch(phase: String, pressed: bool, armed: bool) -> bool:
	return phase == "press" and not pressed and armed


static func feedback_event_for_state(unlocked: bool) -> String:
	return "toggle_on" if unlocked else "toggle_off"


static func face_head_transform(anchor: Vector3, head_transform: Transform3D) -> Transform3D:
	var z_axis := head_transform.origin - anchor
	if z_axis.length_squared() <= 0.000001:
		return Transform3D(head_transform.basis.orthonormalized(), anchor)
	z_axis = z_axis.normalized()
	var y_axis := head_transform.basis.y - z_axis * head_transform.basis.y.dot(z_axis)
	if y_axis.length_squared() <= 0.000001:
		y_axis = z_axis.cross(Vector3.RIGHT)
	if y_axis.length_squared() <= 0.000001:
		y_axis = Vector3.UP
	y_axis = y_axis.normalized()
	var x_axis := y_axis.cross(z_axis).normalized()
	y_axis = z_axis.cross(x_axis).normalized()
	return Transform3D(Basis(x_axis, y_axis, z_axis).orthonormalized(), anchor)


static func smoothing_weight(follow_rate: float, delta: float) -> float:
	if delta <= 0.0:
		return 0.0
	return 1.0 - exp(-maxf(follow_rate, 0.0) * delta)


static func status_text(unlocked: bool, available: bool) -> String:
	if not available:
		return "未连接"
	return "锁定" if unlocked else "解锁"


static func status_color(unlocked: bool, available: bool) -> Color:
	if not available:
		return UNAVAILABLE_COLOR
	return UNLOCKED_COLOR if unlocked else LOCKED_COLOR
