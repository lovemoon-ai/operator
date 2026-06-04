extends OpenXRCompositionLayerQuad
class_name EgoQRScanner

## In-headset QR-code scanner overlay.
##
## Lifecycle:
##   1. capture_app.gd hides the capture panel + record control,
##      passthrough stays on (XR composition).
##   2. We call QRScannerPlugin.startScan() on the Kotlin singleton.
##   3. The plugin runs a Camera2 capture loop @ 15 fps, decodes each
##      frame with ZXing, and emits qr_detections(results_json).
##   4. We freeze the first frame with one or more detected QR codes and
##      render a green arrow for each decoded payload.
##   5. User points the controller at an arrow + pulls trigger → we
##      emit `payload_accepted(payload)`. The panel writes it into the
##      Upload URL field.
##   6. We tear down the camera and hide.
##
## Multi-result note: Several QR codes can be in view simultaneously
## (e.g. the web app's /connect page shows one per LAN interface). All
## detections from the frozen frame appear as separate arrows; the user
## picks one or taps Rescan.

signal payload_accepted(payload: String)
signal cancelled

const VIEWPORT_SIZE := Vector2i(900, 700)
const NO_POINTER := Vector2(-1.0, -1.0)
const HIGHLIGHT_COLOR := Color(0.20, 0.86, 1.0, 0.98)
const SCAN_COLOR := Color(0.18, 0.96, 0.52, 0.95)
const SCAN_COLOR_MUTED := Color(0.18, 0.96, 0.52, 0.22)

class Detection:
	var payload: String
	var center: Vector2          # In scan-area coordinates.
	var pick_button: Button      # The clickable arrow widget.


class ScanEffect:
	extends Control

	const FX_COLOR := Color(0.18, 0.96, 0.52, 0.95)
	const FX_COLOR_MUTED := Color(0.18, 0.96, 0.52, 0.22)

	var phase := 0.0
	var active := true
	var _line := ColorRect.new()
	var _label := Label.new()
	var _box := Panel.new()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var style := StyleBoxFlat.new()
		style.bg_color = Color.TRANSPARENT
		style.border_color = FX_COLOR_MUTED
		style.set_border_width_all(2)
		style.set_corner_radius_all(8)
		_box.add_theme_stylebox_override("panel", style)
		add_child(_box)

		_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_line.color = FX_COLOR
		_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_line.custom_minimum_size.y = 4
		add_child(_line)

		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.add_theme_font_size_override("font_size", 42)
		_label.add_theme_color_override("font_color", FX_COLOR)
		_label.text = "扫描"
		add_child(_label)

	func set_active(next_active: bool) -> void:
		active = next_active
		visible = next_active

	func tick(delta: float) -> void:
		if not active:
			return
		phase += delta
		var scan_y := fposmod(phase * 170.0, maxf(size.y, 1.0))
		_line.position = Vector2(0.0, scan_y)
		_line.size = Vector2(size.x, 4.0)
		_label.size = Vector2(size.x, 70.0)
		_label.position = Vector2(0.0, size.y * 0.5 - 35.0)
		var dots := int(fposmod(phase * 3.0, 4.0))
		_label.text = "扫描" + ["", ".", "..", "..."][dots]
		_label.modulate.a = 0.55 + 0.35 * sin(phase * TAU)

var _viewport: SubViewport
var _detections: Dictionary = {}     # payload -> Detection
var _cursor: Panel
var _pointer_position := Vector2(-1.0, -1.0)
var _pointer_pressed := false
var _cancel_button: Button
var _rescan_button: Button
var _status_label: Label
var _scan_area: Control
var _detections_root: Control
var _scan_effect: ScanEffect
var _frozen_frame: TextureRect
var _plugin: Object
var _plugin_checked := false
var _running := false
var _locked_detection := false
var _last_detection_log_msec := 0


func _init() -> void:
	# Slightly wider/taller than the capture panel so multiple URL
	# previews don't crowd each other. Aspect: 900/700 ≈ 1.286.
	quad_size = Vector2(0.72, 0.56)
	alpha_blend = true
	sort_order = 4
	visible = false
	_build_viewport()


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if _scan_effect:
		_scan_effect.tick(delta)


func open() -> void:
	if _running:
		print("[QR] scanner open ignored; already running")
		return
	print("[QR] scanner overlay opening")
	visible = true
	set_process(true)
	_reset_for_scan()
	_start_plugin_scan()


func _reset_for_scan() -> void:
	_locked_detection = false
	_running = false
	_drain_detections()
	_clear_frozen_frame()
	if _scan_effect:
		_scan_effect.set_active(true)
	if _rescan_button:
		_rescan_button.visible = false
	_set_status("")


func _start_plugin_scan() -> void:
	var plugin := _resolve_plugin()
	if plugin == null:
		_set_status("QR scanner plugin not installed on this device.")
		push_warning("[QR] QRScannerPlugin singleton not found")
		return
	_connect_plugin_signals(plugin)
	if not plugin.is_connected("qr_error", Callable(self, "_on_qr_error")):
		plugin.connect("qr_error", Callable(self, "_on_qr_error"))
	# Permission gate. startScan() refuses without CAMERA permission, so
	# we ask Android to show the OS dialog and tell the user what to do
	# next. Reachable workflow: dialog appears in front of the headset
	# view → user grants → dialog closes → user taps Cancel on this
	# overlay → settings panel reappears → user taps 📷 again →
	# we land back here, hasCameraPermission() is true, startScan() runs.
	if plugin.has_method("hasCameraPermission") and not bool(plugin.call("hasCameraPermission")):
		_set_status("Camera permission needed. Grant it in the OS dialog, then tap Cancel and try again from the settings panel.")
		print("[QR] camera permission missing; requesting Android permission")
		if plugin.has_method("requestCameraPermission"):
			plugin.call("requestCameraPermission")
		return
	var started := bool(plugin.call("startScan"))
	print("[QR] QRScannerPlugin.startScan returned %s" % started)
	if not started:
		_set_status("Scanner did not start. Check device camera permission and logcat.")
		return
	_running = true


func close() -> void:
	if not _running and not visible:
		return
	_running = false
	_locked_detection = false
	set_process(false)
	visible = false
	clear_pointer()
	if _plugin != null:
		_plugin.call("stopScan")
	if _scan_effect:
		_scan_effect.set_active(false)
	if _rescan_button:
		_rescan_button.visible = false
	_drain_detections()
	_clear_frozen_frame()


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
	if _pointer_pressed:
		set_pointer_pressed(false)
	_pointer_position = NO_POINTER
	if _cursor:
		_cursor.visible = false


# --- Plugin signal handlers -------------------------------------------------

func _on_qr_detected(payload: String, bounds_json: String) -> void:
	_lock_detected_entries([{"payload": payload, "bounds_json": bounds_json}])


func _on_qr_detections(results_json: String) -> void:
	var parsed: Variant = JSON.parse_string(results_json)
	if typeof(parsed) != TYPE_ARRAY:
		push_warning("[QR] invalid qr_detections payload")
		return
	_lock_detected_entries(parsed)


func _on_qr_error(message: String) -> void:
	print("[QR] scanner error: %s" % message)
	_set_status("Scanner error: " + message)


func _lock_detected_entries(entries: Array) -> void:
	if _locked_detection:
		return
	var valid: Array = []
	var seen := {}
	for entry in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var payload := str(entry.get("payload", "")).strip_edges()
		if payload.is_empty() or seen.has(payload):
			continue
		seen[payload] = true
		valid.append(entry)
	if valid.is_empty():
		return

	var now := Time.get_ticks_msec()
	if now - _last_detection_log_msec > 1000:
		_last_detection_log_msec = now
		print("[QR] detected %d QR code(s)" % valid.size())

	_locked_detection = true
	_running = false
	_show_frozen_frame_from_plugin()
	if _plugin != null:
		_plugin.call("stopScan")
	if _scan_effect:
		_scan_effect.set_active(false)
	if _rescan_button:
		_rescan_button.visible = true
	_drain_detections()

	for entry in valid:
		var det := Detection.new()
		det.payload = str(entry.get("payload", "")).strip_edges()
		det.center = _parse_center_from_entry(entry)
		_create_detection_widgets(det)
		_detections[det.payload] = det
		_position_detection_widgets(det)
	_set_status(tr("UI_QR_FOUND_COUNT") % valid.size())


# --- Detection widget bookkeeping -------------------------------------------

func _create_detection_widgets(det: Detection) -> void:
	det.pick_button = Button.new()
	det.pick_button.text = "➜"
	det.pick_button.custom_minimum_size = Vector2(84, 64)
	det.pick_button.add_theme_font_size_override("font_size", 38)
	det.pick_button.tooltip_text = "Use this upload endpoint"
	det.pick_button.add_theme_color_override("font_color", Color.WHITE)
	det.pick_button.add_theme_stylebox_override("normal", _arrow_style(false))
	det.pick_button.add_theme_stylebox_override("hover", _arrow_style(true))
	det.pick_button.add_theme_stylebox_override("pressed", _arrow_style(true))
	det.pick_button.pressed.connect(_on_pick_pressed.bind(det.payload))
	_detections_root.add_child(det.pick_button)


func _position_detection_widgets(det: Detection) -> void:
	if det.pick_button == null:
		return
	var area_size := _active_scan_area_size()
	var pos := det.center + Vector2(18.0, -32.0)
	pos.x = clampf(pos.x, 12.0, area_size.x - 96.0)
	pos.y = clampf(pos.y, 12.0, area_size.y - 76.0)
	det.pick_button.position = pos


func _arrow_style(highlighted: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.74, 0.32, 0.96) if not highlighted else Color(0.12, 0.90, 0.42, 1.0)
	style.border_color = Color(0.68, 1.0, 0.78, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	return style


func _destroy_detection(payload: String) -> void:
	if not _detections.has(payload):
		return
	var det: Detection = _detections[payload]
	if det.pick_button:
		det.pick_button.queue_free()
	_detections.erase(payload)


func _drain_detections() -> void:
	for payload in _detections.keys():
		_destroy_detection(payload)


func _on_pick_pressed(payload: String) -> void:
	emit_signal("payload_accepted", payload)
	close()


func _on_cancel_pressed() -> void:
	emit_signal("cancelled")
	close()


func _on_rescan_pressed() -> void:
	if not visible:
		return
	if _plugin != null:
		_plugin.call("stopScan")
	clear_pointer()
	_reset_for_scan()
	_start_plugin_scan()


# --- Plugin resolution ------------------------------------------------------

func _resolve_plugin() -> Object:
	if _plugin_checked:
		return _plugin
	_plugin_checked = true
	if Engine.has_singleton("QRScannerPlugin"):
		_plugin = Engine.get_singleton("QRScannerPlugin")
	return _plugin


func _connect_plugin_signals(plugin: Object) -> void:
	# Prefer the batch signal. It preserves the fact that one frozen camera
	# frame can contain multiple QR codes. Keep the single-result signal as
	# a fallback for older APKs.
	if plugin.has_signal("qr_detections"):
		if not plugin.is_connected("qr_detections", Callable(self, "_on_qr_detections")):
			plugin.connect("qr_detections", Callable(self, "_on_qr_detections"))
		if plugin.is_connected("qr_detected", Callable(self, "_on_qr_detected")):
			plugin.disconnect("qr_detected", Callable(self, "_on_qr_detected"))
		return
	if not plugin.is_connected("qr_detected", Callable(self, "_on_qr_detected")):
		plugin.connect("qr_detected", Callable(self, "_on_qr_detected"))


# Parse the bounds payload the Kotlin side emits. Format is a JSON
# object {"cx": Float, "cy": Float, "w": Float, "h": Float} where the
# coords are normalized 0..1 against the camera frame. We project to
# our viewport. If the parse fails, fall back to the viewport center
# so the user still sees an arrow they can click.
func _parse_center_from_bounds(raw: String) -> Vector2:
	var fallback := _active_scan_area_size() * 0.5
	if raw.is_empty():
		return fallback
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return fallback
	return _parse_center_from_bounds_dict(parsed)


func _parse_center_from_entry(entry: Dictionary) -> Vector2:
	if entry.has("bounds") and typeof(entry["bounds"]) == TYPE_DICTIONARY:
		return _parse_center_from_bounds_dict(entry["bounds"])
	return _parse_center_from_bounds(str(entry.get("bounds_json", "")))


func _parse_center_from_bounds_dict(bounds: Dictionary) -> Vector2:
	var size := _active_scan_area_size()
	var cx := clampf(float(bounds.get("cx", 0.5)), 0.0, 1.0)
	var cy := clampf(float(bounds.get("cy", 0.5)), 0.0, 1.0)
	return Vector2(cx * size.x, cy * size.y)


func _active_scan_area_size() -> Vector2:
	if _scan_area != null and _scan_area.size.x > 1.0 and _scan_area.size.y > 1.0:
		return _scan_area.size
	return Vector2(VIEWPORT_SIZE)


# --- UI construction --------------------------------------------------------

func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "QRScannerViewport"
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	layer_viewport = _viewport

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.067, 0.08, 0.55)  # mostly transparent so passthrough shows
	panel_style.border_color = Color(0.18, 0.22, 0.26, 1.0)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", panel_style)
	_viewport.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(column)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", Color(0.65, 0.70, 0.75))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# Spacer so the detections root takes the middle of the panel.
	_scan_area = Control.new()
	_scan_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scan_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_scan_area)

	_frozen_frame = TextureRect.new()
	_frozen_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frozen_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frozen_frame.stretch_mode = TextureRect.STRETCH_SCALE
	_frozen_frame.modulate = Color(1.0, 1.0, 1.0, 0.96)
	_frozen_frame.visible = false
	_frozen_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scan_area.add_child(_frozen_frame)

	_scan_effect = ScanEffect.new()
	_scan_effect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scan_effect.set_active(false)
	_scan_area.add_child(_scan_effect)

	# The detections root is intentionally absolute-positioned: each
	# detection's arrow sits at the screen-space coords reported by ZXing.
	# We use Control rather than Container so child positions stick instead
	# of getting auto-laid-out.
	_detections_root = Control.new()
	_detections_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detections_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scan_area.add_child(_detections_root)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_child(_status_label)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(actions)

	_rescan_button = Button.new()
	_rescan_button.text = tr("UI_QR_RESCAN")
	_rescan_button.visible = false
	_rescan_button.custom_minimum_size = Vector2(150, 52)
	_rescan_button.add_theme_font_size_override("font_size", 22)
	_rescan_button.pressed.connect(_on_rescan_pressed)
	actions.add_child(_rescan_button)

	_cancel_button = Button.new()
	_cancel_button.text = tr("UI_CANCEL")
	_cancel_button.custom_minimum_size = Vector2(120, 52)
	_cancel_button.add_theme_font_size_override("font_size", 22)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	actions.add_child(_cancel_button)

	_cursor = Panel.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.size = Vector2(18.0, 18.0)
	var cursor_style := StyleBoxFlat.new()
	cursor_style.bg_color = HIGHLIGHT_COLOR
	cursor_style.set_corner_radius_all(9)
	_cursor.add_theme_stylebox_override("panel", cursor_style)
	_viewport.add_child(_cursor)


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text
		_status_label.visible = not text.strip_edges().is_empty()


func _show_frozen_frame_from_plugin() -> void:
	if _plugin == null or not _plugin.has_method("getLastDetectedFramePath"):
		return
	var path := str(_plugin.call("getLastDetectedFramePath"))
	if path.strip_edges().is_empty():
		return
	var image := Image.new()
	var err := image.load(path)
	if err != OK:
		push_warning("[QR] failed to load frozen frame %s err=%d" % [path, err])
		return
	if _frozen_frame:
		_frozen_frame.texture = ImageTexture.create_from_image(image)
		_frozen_frame.visible = true


func _clear_frozen_frame() -> void:
	if _frozen_frame:
		_frozen_frame.texture = null
		_frozen_frame.visible = false
