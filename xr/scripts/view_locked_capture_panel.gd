extends "res://scripts/ui/two_column_settings_panel.gd"
class_name ViewLockedCapturePanel

const ConfigStore := preload("res://scripts/ui/settings_config_store.gd")

signal saved(options: Dictionary)
## Emitted when the user taps the 📷 button next to the Upload URL field.
## capture_app.gd subscribes and opens the QR scanner overlay. The scanner
## eventually calls set_upload_url_from_scan() to feed the result back.
## `exit_requested` is inherited from BaseSettingsPanel — don't redeclare.
signal scan_upload_url_requested

# 840 wide gives ~430px of detail column after sidebar + margins. The 1180-tall
# legacy viewport went away once the form was split into groups — every group
# fits comfortably in 720, including the upload section.
const VIEWPORT_SIZE := Vector2i(840, 720)
const DEFAULT_SAVE_ROOT := "/sdcard/Movies/SpatialMP4"
const STORAGE_REFRESH_SECONDS := 3.0
const SETTINGS_PATH := "user://capture_settings.cfg"
const SECTION := "capture"
# Health check timeout: keep short so the user is not stuck staring at
# "Checking..." if the endpoint is firewalled/dead. 8 s is enough for a
# TLS handshake on slow Wi-Fi but short enough that the operator can
# react. Anything longer feels broken in a HMD.
const UPLOAD_HEALTH_TIMEOUT_S := 8.0

var _mode: OptionButton
var _save_root: LineEdit
var _stream_toggles: Dictionary = {}
var _upload_url: LineEdit
var _upload_token := ""
var _upload_status_label: Label
# Dedicated HTTPRequest for the open()-time upload-URL health probe.
# Separate from capture_app.gd's upload_ack_request so the two flows
# (QR ACK challenge vs plain reachability check) don't clobber each
# other if the user scans a code while a probe is in flight.
var _upload_health_request: HTTPRequest
# _cursor, _pointer_position/_pointer_pressed, _highlighted_slot,
# _exit_indicator/_exit_holding/_exit_hold_seconds are all inherited
# from BaseSettingsPanel — don't redeclare.
var _storage_label: Label
var _storage_refresh_accum := STORAGE_REFRESH_SECONDS
var _storage_plugin: Object
var _storage_plugin_checked := false


func _init() -> void:
	# Two-column layout: left sidebar of group names, right pane holds the
	# active group's controls. Each group has its own scroll, so adding new
	# fields only grows the affected group instead of stretching the panel.
	_setup_two_column_panel(VIEWPORT_SIZE, Vector2(0.63, 0.54), "UI_CAPTURE_SETTINGS_TITLE", "UI_SAVE", 2, true)
	_setup_upload_health_request()
	set_options(load_settings())


func _setup_upload_health_request() -> void:
	# HTTPRequest needs to live in the scene tree to drive its internal
	# HTTPClient. We add it as a child here in _init(); the engine will
	# call _ready() once the panel itself enters the tree.
	_upload_health_request = HTTPRequest.new()
	_upload_health_request.name = "UploadHealthRequest"
	_upload_health_request.timeout = UPLOAD_HEALTH_TIMEOUT_S
	_upload_health_request.use_threads = true
	add_child(_upload_health_request)
	_upload_health_request.request_completed.connect(_on_upload_health_completed)


func _process(delta: float) -> void:
	super._process(delta)
	if not visible:
		return
	_storage_refresh_accum += delta
	if _storage_refresh_accum >= STORAGE_REFRESH_SECONDS:
		_storage_refresh_accum = 0.0
		_refresh_storage_usage()


func get_options() -> Dictionary:
	return {
		"interaction_mode": _mode.get_item_metadata(_mode.selected),
		"stereo_rgb": _toggle_enabled("stereo_rgb"),
		"record_depth": _toggle_enabled("record_depth"),
		"record_head_pose": _toggle_enabled("record_head_pose"),
		"record_controller_pose": _toggle_enabled("record_controller_pose"),
		"record_hand_data": _toggle_enabled("record_hand_data"),
		# v3 spatial audio: opt-in for privacy. The toggle defaults off below
		# (default_on=false in _add_stream_toggle) so a recording never opens
		# the mic without the operator explicitly enabling it.
		"record_audio": _toggle_enabled("record_audio"),
		"save_controller_hand_sidecar": _toggle_enabled("save_controller_hand_sidecar"),
		"save_root": _configured_save_root(),
		"upload_url": _upload_url.text.strip_edges() if _upload_url else "",
		"upload_token": _upload_token,
		"upload_on_finalize": _toggle_enabled("upload_on_finalize"),
		"keep_local_after_upload": _toggle_enabled("keep_local_after_upload"),
	}


func set_options(options: Dictionary) -> void:
	_select_mode(str(options.get("interaction_mode", "controllers")))
	for key in _stream_toggles.keys():
		var toggle := _stream_toggles[key] as CheckButton
		if toggle != null:
			toggle.button_pressed = bool(options.get(key, _default_value_for_key(key)))
	var save_root := str(options.get("save_root", DEFAULT_SAVE_ROOT)).strip_edges()
	_save_root.text = DEFAULT_SAVE_ROOT if save_root.is_empty() else save_root
	if _upload_url:
		_upload_url.text = str(options.get("upload_url", ""))
	_upload_token = str(options.get("upload_token", ""))
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	if is_inside_tree():
		_refresh_storage_usage()


func open() -> void:
	super.open()
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	_refresh_storage_usage()
	# Don't auto-probe on open — every open() would hit the operator's
	# network even when they're just toggling a stream switch. Reset
	# the status row so a stale result from a previous open doesn't
	# linger, and let the operator press the pulse button to actually
	# run the check.
	if _upload_status_label != null:
		_upload_status_label.text = ""
		_upload_status_label.visible = false


func _build_settings_content(parent: VBoxContainer) -> void:
	build_two_column(parent)

	# --- Recording group ---------------------------------------------------
	var recording := register_group("recording", "UI_RECORD_CONTROL", "handshake")

	_mode = OptionButton.new()
	_mode.custom_minimum_size.y = 55
	_mode.add_theme_font_size_override("font_size", 23)
	_mode.add_item(tr("UI_CONTROLLERS"))
	_mode.set_item_metadata(0, "controllers")
	_mode.add_item(tr("UI_HANDS"))
	_mode.set_item_metadata(1, "hands")
	_mode.add_item(tr("UI_HEAD_BUTTONS"))
	_mode.set_item_metadata(2, "head")
	add_interactive(recording, _mode)

	# --- Streams group -----------------------------------------------------
	var streams := register_group("streams", "UI_CAPTURED_STREAMS", "camera")
	_add_stream_toggle(streams, "stereo_rgb", tr("UI_STEREO_RGB"))
	_add_stream_toggle(streams, "record_depth", tr("UI_DEPTH"))
	_add_stream_toggle(streams, "record_head_pose", tr("UI_HEAD_POSE"))
	_add_stream_toggle(streams, "record_controller_pose", tr("UI_CONTROLLER_POSES"))
	_add_stream_toggle(streams, "record_hand_data", tr("UI_HAND_JOINTS"))
	# Audio is privacy-sensitive (opens the microphone), so the toggle starts
	# OFF -- the operator has to flip it explicitly. The capture pipeline
	# additionally gates on RECORD_AUDIO runtime permission downstream.
	_add_stream_toggle(streams, "record_audio", tr("UI_RECORD_AUDIO"), false)

	# --- Outputs group -----------------------------------------------------
	var outputs := register_group("outputs", "UI_OUTPUTS", "check")
	# Controller/hand poses always go into the MP4 mett tracks. This toggle only
	# controls whether they are ALSO written as separate JSONL sidecar files for
	# debugging. Default off to avoid the extra main-thread JSON cost.
	_add_stream_toggle(outputs, "save_controller_hand_sidecar", tr("UI_CONTROLLER_HAND_SIDECAR"), false)

	# --- Storage group -----------------------------------------------------
	var storage := register_group("storage", "UI_GROUP_STORAGE", "plug")

	_save_root = LineEdit.new()
	_save_root.text = DEFAULT_SAVE_ROOT
	_save_root.placeholder_text = DEFAULT_SAVE_ROOT
	_save_root.custom_minimum_size.y = 55
	_save_root.add_theme_font_size_override("font_size", 19)
	_save_root.text_changed.connect(_on_save_root_changed)
	add_interactive(storage, _save_root)

	_storage_label = _add_status_label_to(storage, tr("UI_STORAGE_CHECKING"))

	# --- Upload group ------------------------------------------------------
	# Optional: if `upload_url` is non-empty and `upload_on_finalize` is
	# on, every finalized session is queued for resumable upload (TUS
	# 1.0.0) to the configured endpoint. See
	# `claw/issues/010-ego-data-upload.md`. Settings persist via
	# EgoSettingsStore across app launches.
	var upload := register_group("upload", "UI_UPLOAD", "signal")

	# [LineEdit — Upload URL] [💓 health-check] [📷 scan]
	# The health-check button (pulse icon) probes the configured URL
	# on demand — no auto-trigger on panel open, so we don't hit the
	# operator's network every time they tweak a stream toggle.
	# The QR scan button (camera icon) only renders on Android (gated
	# by _qr_scan_supported), where the QR Scanner plugin AAR is bundled
	# into the APK. On macOS / Linux dev builds the row is just the
	# LineEdit + the health-check button. See
	# claw/issues/011-xr-qr-scanner.md.
	var upload_url_row := HBoxContainer.new()
	upload_url_row.add_theme_constant_override("separation", 8)
	upload_url_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upload.add_child(upload_url_row)

	_upload_url = LineEdit.new()
	_upload_url.placeholder_text = "https://my-ingest.local:8443/ingest"
	_upload_url.custom_minimum_size.y = 55
	_upload_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_upload_url.add_theme_font_size_override("font_size", 19)
	add_interactive(upload_url_row, _upload_url)

	# Manual health-check trigger. Always available — even on desktop
	# dev builds we want a way to verify the server is up.
	_add_url_action_button(
		upload_url_row,
		"pulse",
		tr("UI_UPLOAD_HEALTH_CHECK_TOOLTIP"),
		_on_health_check_button_pressed
	)

	if _qr_scan_supported():
		_add_url_action_button(
			upload_url_row,
			"camera",
			tr("UI_SCAN_QR_TOOLTIP"),
			_on_scan_button_pressed
		)

	_upload_status_label = _add_status_label_to(upload, "")
	_upload_status_label.visible = false

	_add_stream_toggle(upload, "upload_on_finalize", tr("UI_AUTO_UPLOAD_ON_STOP"), true)
	_add_stream_toggle(upload, "keep_local_after_upload", tr("UI_KEEP_LOCAL_AFTER_UPLOAD"), true)


func _on_confirm_requested() -> void:
	var options := get_options()
	_save_to_disk(options)
	close()
	saved.emit(options)


func _add_stream_toggle(parent: Container, key: String, label: String, default_on: bool = true) -> void:
	var toggle := add_toggle(parent, label, default_on, 23)
	_stream_toggles[key] = toggle


func _add_status_label_to(parent: Container, initial_text: String) -> Label:
	# add_status_label() in BaseSettingsPanel hard-codes _content as the parent,
	# but in the two-column layout we want the label inside a specific group.
	var lbl := Label.new()
	lbl.text = initial_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COL_STATUS)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(lbl)
	return lbl


func _toggle_enabled(key: String) -> bool:
	var toggle: CheckButton = _stream_toggles[key]
	return toggle.button_pressed


func _configured_save_root() -> String:
	var configured := _save_root.text.strip_edges()
	return DEFAULT_SAVE_ROOT if configured.is_empty() else configured


func _select_mode(mode: String) -> void:
	for idx in range(_mode.item_count):
		if String(_mode.get_item_metadata(idx)) == mode:
			_mode.select(idx)
			return
	_mode.select(0)


func _default_value_for_key(key: String) -> Variant:
	return _default_options().get(key)


func _save_to_disk(options: Dictionary) -> void:
	ConfigStore.save(SETTINGS_PATH, SECTION, _default_options(), options, "CaptureSettings")


static func load_settings() -> Dictionary:
	var out := ConfigStore.load(SETTINGS_PATH, SECTION, _default_options())
	var save_root := str(out.get("save_root", DEFAULT_SAVE_ROOT)).strip_edges()
	out["save_root"] = DEFAULT_SAVE_ROOT if save_root.is_empty() else save_root
	return out


static func _default_options() -> Dictionary:
	return {
		"interaction_mode": "controllers",
		"stereo_rgb": true,
		"record_depth": true,
		"record_head_pose": true,
		"record_controller_pose": true,
		"record_hand_data": true,
		"record_audio": false,
		"audio_channel_layout": "stereo",
		"audio_sample_rate_hz": 48000,
		"audio_bitrate_bps": 128000,
		"save_controller_hand_sidecar": false,
		"save_root": DEFAULT_SAVE_ROOT,
		"upload_url": "",
		"upload_token": "",
		"upload_on_finalize": true,
		"keep_local_after_upload": true
	}


# --- QR scan integration ---------------------------------------------------
# The actual Camera2 + ZXing scanning lives in the qr_scanner Android plugin
# (xr/android_plugin/qrscanner/). This panel only fires the signal and
# accepts the resulting payload back. capture_app.gd brokers the overlay
# lifecycle. (_on_save_pressed / _on_exit_button_* / _cancel_exit_hold are
# inherited from BaseSettingsPanel — don't redeclare them.)

func _qr_scan_supported() -> bool:
	# Show the button on Android only — the plugin is Android-only by
	# design. In the editor / macOS dev builds we hide the button so we
	# don't promise something we can't deliver. Flip
	# `ProjectSettings: ego/qr_scan/force_show` to true to stub-fake it
	# during desktop UI work.
	if ProjectSettings.has_setting("ego/qr_scan/force_show"):
		if bool(ProjectSettings.get_setting("ego/qr_scan/force_show")):
			return true
	return OS.get_name() == "Android"


func _on_scan_button_pressed() -> void:
	print("[QR] upload-url scan button pressed")
	scan_upload_url_requested.emit()


func _on_health_check_button_pressed() -> void:
	# Operator pressed the pulse icon — run the reachability probe now.
	# Always re-runs (cancels in-flight requests in _trigger_upload_health_check)
	# so a second tap retries instead of being dropped.
	print("[UploadHealth] manual check requested")
	_trigger_upload_health_check()


# Build a square icon-only button that sits to the right of the upload-URL
# LineEdit. Both the health-check and the QR scan buttons use the same
# geometry so the row stays tidy regardless of which buttons are present.
#
# Note on icon rendering: _apply_button_icon() in the base class is tuned
# for text+icon buttons (confirm/exit). For icon-only buttons we override
# the size constants — expand_icon with empty text can collapse the icon
# to zero in some Godot 4 builds. Setting an explicit icon_max_width and
# disabling expand_icon makes the result deterministic.
func _add_url_action_button(
		row: HBoxContainer,
		icon_name: String,
		tooltip: String,
		handler: Callable
) -> Button:
	var btn := Button.new()
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(70, 55)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	var icon := _load_icon(icon_name)
	if icon == null:
		push_warning("[ViewLockedCapturePanel] icon '%s' failed to load — button will be blank" % icon_name)
	btn.icon = icon
	btn.expand_icon = false
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.add_theme_constant_override("icon_max_width", 36)
	btn.pressed.connect(handler)
	var slot := add_interactive(row, btn)
	slot.size_flags_horizontal = Control.SIZE_SHRINK_END
	slot.custom_minimum_size = Vector2(78, 55)
	return btn


## Called by capture_app.gd once the QR scanner overlay returns a payload.
## We DO NOT close the panel here — the user still needs to review + Save.
func set_upload_url_from_scan(url: String, token: String = "", enable_auto_upload: bool = false) -> void:
	if _upload_url == null:
		return
	var trimmed := url.strip_edges()
	if trimmed.is_empty():
		return
	_upload_url.text = trimmed
	_upload_token = token
	if enable_auto_upload and _stream_toggles.has("upload_on_finalize"):
		(_stream_toggles["upload_on_finalize"] as CheckButton).button_pressed = true


func set_upload_connectivity_status(text: String, level: String = "normal") -> void:
	if _upload_status_label == null:
		return
	_upload_status_label.text = text
	_upload_status_label.visible = not text.strip_edges().is_empty()
	var color := COL_STATUS
	if level == "error":
		color = Color(1.0, 0.36, 0.28)
	elif level == "success":
		color = Color(0.36, 0.96, 0.58)
	elif level == "warning":
		# Amber — server responded but probe wasn't conclusive (e.g. 401/404
		# on OPTIONS, or missing Tus-Resumable header). The endpoint is up,
		# but we can't promise the actual upload will succeed.
		color = Color(1.0, 0.78, 0.40)
	_upload_status_label.add_theme_color_override("font_color", color)


# --- Upload URL reachability probe -----------------------------------------
# Triggered every time the panel opens. The user asked for "if the upload
# URL is non-empty, every time you open settings, check whether it's healthy
# and show the status — don't show nothing." So:
#   - empty URL  → hide the label (no row at all; nothing to check)
#   - bad URL    → red, "invalid URL"
#   - probe      → an OPTIONS request to the configured endpoint
#       - 2xx/3xx + Tus-Resumable header → green, TUS endpoint ready
#       - 2xx/3xx without Tus-Resumable  → green, generic reachable
#       - 4xx                            → amber (reachable but probe rejected)
#       - 5xx / network error / timeout  → red

func _trigger_upload_health_check() -> void:
	if _upload_status_label == null:
		return
	var url := ""
	if _upload_url != null:
		url = _upload_url.text.strip_edges()
	if url.is_empty():
		# Nothing configured — collapse the status row entirely so we don't
		# show stale "OK" text from a previous URL the user just cleared.
		_upload_status_label.text = ""
		_upload_status_label.visible = false
		return
	if not (url.begins_with("http://") or url.begins_with("https://")):
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_INVALID_URL"), "error")
		return
	if _upload_health_request == null:
		# Panel was constructed without the helper somehow — at least surface
		# that a check would have happened so the row isn't blank.
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_UNAVAILABLE"), "warning")
		return
	# Cancel any in-flight probe before issuing the new one so back-to-back
	# open() calls don't deliver stale callbacks.
	if _upload_health_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_upload_health_request.cancel_request()
	set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_CHECKING"), "normal")
	# Tus-Resumable in the *request* is recommended by the TUS spec for
	# OPTIONS probes. Many ingest servers also accept a plain OPTIONS.
	var headers := PackedStringArray([
		"User-Agent: ego-uploader/1.0 (godot)",
		"Tus-Resumable: 1.0.0",
	])
	var err := _upload_health_request.request(url, headers, HTTPClient.METHOD_OPTIONS)
	if err != OK:
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_REQUEST_FAILED") % err, "error")


func _on_upload_health_completed(result: int, response_code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_NETWORK_ERROR") % result, "error")
		return
	# Look for Tus-Resumable / Tus-Version response headers (case-insensitive).
	# Their presence is a strong signal that the URL is actually a TUS ingest
	# endpoint, not just some web server that happens to be reachable.
	var tus_version := ""
	for h in headers:
		var idx := h.find(":")
		if idx < 0:
			continue
		var name := h.substr(0, idx).strip_edges().to_lower()
		if name == "tus-version":
			tus_version = h.substr(idx + 1).strip_edges()
			break
		if name == "tus-resumable" and tus_version.is_empty():
			tus_version = h.substr(idx + 1).strip_edges()
	if not tus_version.is_empty():
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_TUS_OK") % tus_version, "success")
		return
	if response_code >= 200 and response_code < 400:
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_OK") % response_code, "success")
	elif response_code >= 400 and response_code < 500:
		# Reachable but rejected the probe. Plenty of perfectly fine ingest
		# servers return 401/404 to OPTIONS — flag as warning, not error.
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_HTTP_WARN") % response_code, "warning")
	else:
		set_upload_connectivity_status(tr("UI_UPLOAD_HEALTH_HTTP_ERROR") % response_code, "error")


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
