extends "res://scripts/ui/base_settings_panel.gd"
class_name ViewLockedCapturePanel

const ConfigStore := preload("res://scripts/ui/settings_config_store.gd")

signal saved(options: Dictionary)

const VIEWPORT_SIZE := Vector2i(720, 1000)
const DEFAULT_SAVE_ROOT := "/sdcard/Movies/SpatialMP4"
const STORAGE_REFRESH_SECONDS := 3.0
const SETTINGS_PATH := "user://capture_settings.cfg"
const SECTION := "capture"

var _mode: OptionButton
var _save_root: LineEdit
var _stream_toggles: Dictionary = {}
var _storage_label: Label
var _storage_refresh_accum := STORAGE_REFRESH_SECONDS
var _storage_plugin: Object
var _storage_plugin_checked := false


func _init() -> void:
	_setup_settings_panel(VIEWPORT_SIZE, Vector2(0.54, 0.75), "UI_CAPTURE_SETTINGS_TITLE", "UI_SAVE", 2, true)
	set_options(load_settings())


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
		"save_controller_hand_sidecar": _toggle_enabled("save_controller_hand_sidecar"),
		"save_root": _configured_save_root()
	}


func set_options(options: Dictionary) -> void:
	_select_mode(str(options.get("interaction_mode", "controllers")))
	for key in _stream_toggles.keys():
		var toggle := _stream_toggles[key] as CheckButton
		if toggle != null:
			toggle.button_pressed = bool(options.get(key, _default_value_for_key(key)))
	var save_root := str(options.get("save_root", DEFAULT_SAVE_ROOT)).strip_edges()
	_save_root.text = DEFAULT_SAVE_ROOT if save_root.is_empty() else save_root
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	if is_inside_tree():
		_refresh_storage_usage()


func open() -> void:
	super.open()
	_storage_refresh_accum = STORAGE_REFRESH_SECONDS
	_refresh_storage_usage()


func _build_settings_content(_parent: VBoxContainer) -> void:
	add_section_label("UI_RECORD_CONTROL")

	_mode = OptionButton.new()
	_mode.custom_minimum_size.y = 55
	_mode.add_theme_font_size_override("font_size", 23)
	_mode.add_item(tr("UI_CONTROLLERS"))
	_mode.set_item_metadata(0, "controllers")
	_mode.add_item(tr("UI_HANDS"))
	_mode.set_item_metadata(1, "hands")
	_mode.add_item(tr("UI_HEAD_BUTTONS"))
	_mode.set_item_metadata(2, "head")
	add_interactive(_content, _mode)

	add_section_label("UI_CAPTURED_STREAMS")

	_add_stream_toggle("stereo_rgb", tr("UI_STEREO_RGB"))
	_add_stream_toggle("record_depth", tr("UI_DEPTH"))
	_add_stream_toggle("record_head_pose", tr("UI_HEAD_POSE"))
	_add_stream_toggle("record_controller_pose", tr("UI_CONTROLLER_POSES"))
	_add_stream_toggle("record_hand_data", tr("UI_HAND_JOINTS"))

	add_section_label("UI_OUTPUTS")

	# Controller/hand poses always go into the MP4 mett tracks. This toggle only
	# controls whether they are ALSO written as separate JSONL sidecar files for
	# debugging. Default off to avoid the extra main-thread JSON cost.
	_add_stream_toggle("save_controller_hand_sidecar", tr("UI_CONTROLLER_HAND_SIDECAR"), false)

	add_section_label("UI_SAVE_PATH")

	_save_root = LineEdit.new()
	_save_root.text = DEFAULT_SAVE_ROOT
	_save_root.placeholder_text = DEFAULT_SAVE_ROOT
	_save_root.custom_minimum_size.y = 55
	_save_root.add_theme_font_size_override("font_size", 19)
	_save_root.text_changed.connect(_on_save_root_changed)
	add_interactive(_content, _save_root)

	_storage_label = add_status_label(tr("UI_STORAGE_CHECKING"))


func _on_confirm_requested() -> void:
	var options := get_options()
	_save_to_disk(options)
	close()
	saved.emit(options)


func _add_stream_toggle(key: String, label: String, default_on: bool = true) -> void:
	var toggle := add_toggle(_content, label, default_on, 23)
	_stream_toggles[key] = toggle


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
		"save_controller_hand_sidecar": false,
		"save_root": DEFAULT_SAVE_ROOT
	}


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
