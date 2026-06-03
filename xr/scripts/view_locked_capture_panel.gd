extends OpenXRCompositionLayerQuad
class_name ViewLockedCapturePanel

signal saved(options: Dictionary)
signal exit_requested

const VIEWPORT_SIZE := Vector2i(720, 1000)
const DEFAULT_SAVE_ROOT := "/sdcard/Movies/SpatialMP4"
const NO_POINTER := Vector2(-1.0, -1.0)
const HIGHLIGHT_COLOR := Color(0.20, 0.86, 1.0, 0.98)
const EXIT_HOLD_SECONDS := 2.0

class HoldIndicator:
	extends Control

	var progress := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_progress(value: float) -> void:
		progress = clampf(value, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		if progress <= 0.0:
			return
		var inset := 8.0
		var y := size.y - 5.0
		var end_x := inset + (size.x - inset * 2.0) * progress
		draw_line(Vector2(inset, y), Vector2(end_x, y), Color(0.20, 0.86, 1.0, 0.98), 4.0, true)

const STORAGE_REFRESH_SECONDS := 3.0

var _viewport: SubViewport
var _mode: OptionButton
var _save_root: LineEdit
var _stream_toggles: Dictionary = {}
var _cursor: Panel
var _pointer_position := NO_POINTER
var _pointer_pressed := false
var _highlighted_slot: PanelContainer
var _exit_indicator: HoldIndicator
var _exit_holding := false
var _exit_hold_seconds := 0.0
var _storage_label: Label
var _storage_refresh_accum := STORAGE_REFRESH_SECONDS
var _storage_plugin: Object
var _storage_plugin_checked := false


func _init() -> void:
	# Keep quad aspect ratio matched to VIEWPORT_SIZE (1000/720 ≈ 1.389).
	quad_size = Vector2(0.54, 0.75)
	alpha_blend = true
	sort_order = 2
	_build_viewport()


func _process(delta: float) -> void:
	if visible:
		_storage_refresh_accum += delta
		if _storage_refresh_accum >= STORAGE_REFRESH_SECONDS:
			_storage_refresh_accum = 0.0
			_refresh_storage_usage()

	if not _exit_holding:
		return
	_exit_hold_seconds = minf(_exit_hold_seconds + delta, EXIT_HOLD_SECONDS)
	if _exit_indicator:
		_exit_indicator.set_progress(_exit_hold_seconds / EXIT_HOLD_SECONDS)
	if _exit_hold_seconds < EXIT_HOLD_SECONDS:
		return
	_cancel_exit_hold()
	emit_signal("exit_requested")


func get_options() -> Dictionary:
	return {
		"interaction_mode": _mode.get_item_metadata(_mode.selected),
		"stereo_rgb": _toggle_enabled("stereo_rgb"),
		"record_depth": _toggle_enabled("record_depth"),
		"record_head_pose": _toggle_enabled("record_head_pose"),
		"record_controller_pose": _toggle_enabled("record_controller_pose"),
		"record_hand_data": _toggle_enabled("record_hand_data"),
		"save_controller_hand_sidecar": _toggle_enabled("save_controller_hand_sidecar"),
		"save_root": _configured_save_root()
	}


func open() -> void:
	visible = true
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	_refresh_storage_usage()


func close() -> void:
	clear_pointer()
	visible = false


func update_pointer_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	var uv: Vector2 = intersects_ray(ray_origin, ray_direction)
	if uv.x < 0.0 or uv.y < 0.0:
		clear_pointer()
		return false

	var next_position := Vector2(uv.x * VIEWPORT_SIZE.x, uv.y * VIEWPORT_SIZE.y)
	if next_position != _pointer_position:
		var motion := InputEventMouseMotion.new()
		motion.position = next_position
		motion.global_position = next_position
		_viewport.push_input(motion)
	_pointer_position = next_position
	_cursor.position = next_position - (_cursor.size * 0.5)
	_cursor.visible = true
	return true


func set_pointer_pressed(pressed: bool) -> void:
	if pressed == _pointer_pressed:
		return
	if pressed and _pointer_position == NO_POINTER:
		return

	_pointer_pressed = pressed
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = _pointer_position
	event.global_position = _pointer_position
	_viewport.push_input(event)


func clear_pointer() -> void:
	_cancel_exit_hold()
	if _pointer_pressed:
		set_pointer_pressed(false)
	_pointer_position = NO_POINTER
	_cursor.visible = false
	_set_highlighted_slot(null)


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "SettingsViewport"
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	layer_viewport = _viewport

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.067, 0.08, 0.96)
	panel_style.border_color = Color(0.18, 0.22, 0.26, 1.0)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", panel_style)
	_viewport.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 38)
	margin.add_theme_constant_override("margin_right", 38)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	margin.add_child(content)

	var title := Label.new()
	title.text = tr("UI_CAPTURE_SETTINGS_TITLE")
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.98))
	content.add_child(title)

	var mode_label := Label.new()
	mode_label.text = tr("UI_RECORD_CONTROL")
	mode_label.add_theme_font_size_override("font_size", 21)
	mode_label.add_theme_color_override("font_color", Color(0.65, 0.70, 0.75))
	content.add_child(mode_label)

	_mode = OptionButton.new()
	_mode.custom_minimum_size.y = 55
	_mode.add_theme_font_size_override("font_size", 23)
	_mode.add_item(tr("UI_CONTROLLERS"))
	_mode.set_item_metadata(0, "controllers")
	_mode.add_item(tr("UI_HANDS"))
	_mode.set_item_metadata(1, "hands")
	_mode.add_item(tr("UI_HEAD_BUTTONS"))
	_mode.set_item_metadata(2, "head")
	_add_interactive(content, _mode)

	var streams_label := Label.new()
	streams_label.text = tr("UI_CAPTURED_STREAMS")
	streams_label.add_theme_font_size_override("font_size", 21)
	streams_label.add_theme_color_override("font_color", Color(0.65, 0.70, 0.75))
	content.add_child(streams_label)

	_add_toggle(content, "stereo_rgb", tr("UI_STEREO_RGB"))
	_add_toggle(content, "record_depth", tr("UI_DEPTH"))
	_add_toggle(content, "record_head_pose", tr("UI_HEAD_POSE"))
	_add_toggle(content, "record_controller_pose", tr("UI_CONTROLLER_POSES"))
	_add_toggle(content, "record_hand_data", tr("UI_HAND_JOINTS"))

	var outputs_label := Label.new()
	outputs_label.text = tr("UI_OUTPUTS")
	outputs_label.add_theme_font_size_override("font_size", 21)
	outputs_label.add_theme_color_override("font_color", Color(0.65, 0.70, 0.75))
	content.add_child(outputs_label)

	# Controller/hand poses always go into the MP4 mett tracks. This toggle only
	# controls whether they are ALSO written as separate JSONL sidecar files for
	# debugging. Default off to avoid the extra main-thread JSON cost.
	_add_toggle(content, "save_controller_hand_sidecar", tr("UI_CONTROLLER_HAND_SIDECAR"), false)

	var storage_label := Label.new()
	storage_label.text = tr("UI_SAVE_PATH")
	storage_label.add_theme_font_size_override("font_size", 21)
	storage_label.add_theme_color_override("font_color", Color(0.65, 0.70, 0.75))
	content.add_child(storage_label)

	_save_root = LineEdit.new()
	_save_root.text = DEFAULT_SAVE_ROOT
	_save_root.placeholder_text = DEFAULT_SAVE_ROOT
	_save_root.custom_minimum_size.y = 55
	_save_root.add_theme_font_size_override("font_size", 19)
	_save_root.text_changed.connect(_on_save_root_changed)
	_add_interactive(content, _save_root)

	_storage_label = Label.new()
	_storage_label.text = tr("UI_STORAGE_CHECKING")
	_storage_label.add_theme_font_size_override("font_size", 18)
	_storage_label.add_theme_color_override("font_color", Color(0.55, 0.80, 0.66))
	_storage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_storage_label)

	var spacer := Control.new()
	spacer.custom_minimum_size.y = 4
	content.add_child(spacer)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 14)
	content.add_child(actions)

	var save_button := Button.new()
	save_button.text = tr("UI_SAVE")
	save_button.custom_minimum_size.y = 68
	save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_button.add_theme_font_size_override("font_size", 28)
	save_button.pressed.connect(_on_save_pressed)
	_add_interactive(actions, save_button)

	var exit_button := Button.new()
	exit_button.text = tr("UI_EXIT")
	exit_button.custom_minimum_size.y = 68
	exit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exit_button.add_theme_font_size_override("font_size", 28)
	exit_button.button_down.connect(_on_exit_button_down)
	exit_button.button_up.connect(_on_exit_button_up)
	exit_button.mouse_exited.connect(_on_exit_mouse_exited)
	var exit_slot := _add_interactive(actions, exit_button)
	_exit_indicator = HoldIndicator.new()
	_exit_indicator.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	exit_slot.add_child(_exit_indicator)

	_cursor = Panel.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.size = Vector2(18.0, 18.0)
	var cursor_style := StyleBoxFlat.new()
	cursor_style.bg_color = Color(0.20, 0.86, 1.0, 0.98)
	cursor_style.set_corner_radius_all(9)
	_cursor.add_theme_stylebox_override("panel", cursor_style)
	_viewport.add_child(_cursor)


func _add_toggle(parent: VBoxContainer, key: String, label: String, default_on: bool = true) -> void:
	var toggle := CheckButton.new()
	toggle.text = label
	toggle.button_pressed = default_on
	toggle.custom_minimum_size.y = 47
	toggle.add_theme_font_size_override("font_size", 23)
	_stream_toggles[key] = toggle
	_add_interactive(parent, toggle)


func _add_interactive(parent: Container, control: Control) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.add_theme_stylebox_override("panel", _interactive_style(false))
	control.mouse_entered.connect(_on_interactive_mouse_entered.bind(slot))
	control.mouse_exited.connect(_on_interactive_mouse_exited.bind(slot))
	slot.add_child(control)
	parent.add_child(slot)
	return slot


func _on_interactive_mouse_entered(slot: PanelContainer) -> void:
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
	style.border_color = HIGHLIGHT_COLOR if highlighted else Color.TRANSPARENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	return style


func _toggle_enabled(key: String) -> bool:
	var toggle: CheckButton = _stream_toggles[key]
	return toggle.button_pressed


func _configured_save_root() -> String:
	var configured := _save_root.text.strip_edges()
	return DEFAULT_SAVE_ROOT if configured.is_empty() else configured


func _on_save_pressed() -> void:
	var options := get_options()
	close()
	emit_signal("saved", options)


func _on_exit_button_down() -> void:
	_cancel_exit_hold()
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


func _on_save_root_changed(_new_text: String) -> void:
	# Re-query immediately when the operator edits the path so the figure
	# tracks the volume they actually picked.
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	_refresh_storage_usage()


func _refresh_storage_usage() -> void:
	var text := _query_storage_text()
	if _storage_label and _storage_label.text != text:
		_storage_label.text = text
		print("QcStorage %s" % text)


func _resolve_storage_plugin() -> Object:
	if _storage_plugin_checked:
		return _storage_plugin
	_storage_plugin_checked = true
	if Engine.has_singleton("QuestCapturePlugin"):
		_storage_plugin = Engine.get_singleton("QuestCapturePlugin")
	return _storage_plugin


func _query_storage_text() -> String:
	var plugin := _resolve_storage_plugin()
	if plugin == null:
		return tr("UI_STORAGE_UNAVAILABLE_PLATFORM")
	var raw: Variant = plugin.call("getStorageUsageJson", _configured_save_root())
	if typeof(raw) != TYPE_STRING or String(raw).is_empty():
		return tr("UI_STORAGE_UNAVAILABLE")
	var parsed: Variant = JSON.parse_string(String(raw))
	if typeof(parsed) != TYPE_DICTIONARY:
		return tr("UI_STORAGE_UNAVAILABLE")
	if parsed.has("error"):
		return tr("UI_STORAGE_ERROR") % str(parsed["error"])
	var total_b := float(parsed.get("total_bytes", 0.0))
	var free_b := float(parsed.get("available_bytes", parsed.get("free_bytes", 0.0)))
	var capture_b := float(parsed.get("capture_dir_bytes", 0.0))
	if total_b <= 0.0:
		return tr("UI_STORAGE_UNAVAILABLE")
	var used_pct := int(round((total_b - free_b) / total_b * 100.0))
	return tr("UI_FREE_STORAGE") % [
		_human_bytes(free_b),
		_human_bytes(total_b),
		used_pct,
		_human_bytes(capture_b)
	]


func _human_bytes(amount: float) -> String:
	var gb := 1024.0 * 1024.0 * 1024.0
	var mb := 1024.0 * 1024.0
	var kb := 1024.0
	if amount >= gb:
		return "%.1f GB" % (amount / gb)
	if amount >= mb:
		return "%.0f MB" % (amount / mb)
	if amount >= kb:
		return "%.0f KB" % (amount / kb)
	return "%d B" % int(amount)
