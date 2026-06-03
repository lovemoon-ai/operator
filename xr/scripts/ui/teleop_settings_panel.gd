extends "res://scripts/ui/base_settings_panel.gd"
class_name TeleopSettingsPanel

signal settings_applied(ip: String, port: int, robot_type: String, video_face_locked: bool, show_on_launch: bool)
signal close_requested

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "settings"

const ROBOT_TYPES: Array[String] = ["robot_arm", "rc_car"]
const DEFAULT_IP: String = "127.0.0.1"
const DEFAULT_PORT: int = 63901
const DEFAULT_TYPE: String = "robot_arm"
const DEFAULT_FACE_LOCKED: bool = true
const DEFAULT_SHOW_ON_LAUNCH: bool = false
const MANUAL_LABEL_KEY := "UI_MANUAL_ENTRY"

var _discovery_option: OptionButton
var _ip_input: LineEdit
var _port_input: LineEdit
var _type_option: OptionButton
var _video_face_toggle: CheckButton
var _show_on_launch_toggle: CheckButton
var _status_label: Label
var _discovered: Dictionary = {}


func _init() -> void:
	_setup_settings_panel(Vector2i(720, 884), Vector2(0.54, 0.663), "UI_SETTINGS_TITLE", "UI_OK", 2, false)
	_load_from_disk()
	_apply_mode_lock()
	print("[SettingsUI] ready (manual mode; %d discovered)" % (_discovery_option.item_count - 1))


func _build_settings_content(_parent: VBoxContainer) -> void:
	add_section_label("UI_CONNECT_TO")

	_discovery_option = OptionButton.new()
	_discovery_option.custom_minimum_size.y = 55
	_discovery_option.add_theme_font_size_override("font_size", 23)
	_discovery_option.add_item(tr(MANUAL_LABEL_KEY))
	_discovery_option.set_item_metadata(0, "")
	_discovery_option.item_selected.connect(_on_discovery_selected)
	add_interactive(_content, _discovery_option)

	_ip_input = LineEdit.new()
	_ip_input.placeholder_text = tr("UI_ROBOT_IP")
	_ip_input.text = DEFAULT_IP
	_ip_input.custom_minimum_size.y = 55
	_ip_input.add_theme_font_size_override("font_size", 21)
	add_interactive(_content, _ip_input)

	_port_input = LineEdit.new()
	_port_input.placeholder_text = tr("UI_PORT")
	_port_input.text = str(DEFAULT_PORT)
	_port_input.custom_minimum_size.y = 55
	_port_input.add_theme_font_size_override("font_size", 21)
	add_interactive(_content, _port_input)

	add_section_label("UI_ROBOT_TYPE")

	_type_option = OptionButton.new()
	_type_option.custom_minimum_size.y = 55
	_type_option.add_theme_font_size_override("font_size", 23)
	for t in ROBOT_TYPES:
		_type_option.add_item(_robot_type_display(t))
		_type_option.set_item_metadata(_type_option.item_count - 1, t)
	add_interactive(_content, _type_option)

	_video_face_toggle = add_toggle(_content, tr("UI_FACE_LOCKED_VIDEO"), DEFAULT_FACE_LOCKED, 22)
	_show_on_launch_toggle = add_toggle(_content, tr("UI_SHOW_SETTINGS_ON_LAUNCH"), DEFAULT_SHOW_ON_LAUNCH, 22)

	_status_label = add_status_label(tr("UI_STATUS_PREFIX") % tr("UI_STATUS_EMPTY"))


func _on_confirm_requested() -> void:
	var ip := _ip_input.text.strip_edges()
	var port := _port_input.text.strip_edges().to_int()
	if ip.is_empty():
		set_status(tr("UI_IP_REQUIRED"))
		return
	if port <= 0 or port > 65535:
		port = DEFAULT_PORT
		_port_input.text = str(port)

	var rtype := DEFAULT_TYPE
	if _type_option.selected >= 0:
		rtype = String(_type_option.get_item_metadata(_type_option.selected))
	var face_locked := _video_face_toggle.button_pressed
	var show_on_launch := _show_on_launch_toggle.button_pressed

	_save_to_disk(ip, port, rtype, face_locked, show_on_launch)
	set_status(tr("UI_APPLYING"))
	settings_applied.emit(ip, port, rtype, face_locked, show_on_launch)


func set_discovery_state(known_robots: Dictionary, prefer_ip: String = "") -> void:
	_discovered = known_robots.duplicate(true)

	var previously_selected_name := _selected_robot_name()

	_discovery_option.clear()
	_discovery_option.add_item(tr(MANUAL_LABEL_KEY))
	_discovery_option.set_item_metadata(0, "")

	var names: Array = _discovered.keys()
	names.sort()
	var idx_to_select := 0
	for i in range(names.size()):
		var rname: String = names[i]
		var info: Dictionary = _discovered[rname]
		var disp := _format_robot_label(rname, info)
		_discovery_option.add_item(disp)
		var idx: int = _discovery_option.item_count - 1
		_discovery_option.set_item_metadata(idx, rname)
		if rname == previously_selected_name:
			idx_to_select = idx
		elif idx_to_select == 0 and prefer_ip != "" and String(info.get("ip", "")) == prefer_ip:
			idx_to_select = idx

	if idx_to_select == 0 and names.size() == 1:
		idx_to_select = 1

	_discovery_option.select(idx_to_select)
	_on_discovery_selected(idx_to_select)


func add_discovered(robot_name: String, info: Dictionary) -> void:
	_discovered[robot_name] = info
	set_discovery_state(_discovered, _ip_input.text.strip_edges())


func remove_discovered(robot_name: String) -> void:
	if _discovered.erase(robot_name):
		set_discovery_state(_discovered, _ip_input.text.strip_edges())


func set_status(text: String) -> void:
	if _status_label:
		_status_label.text = tr("UI_STATUS_PREFIX") % text


func _load_from_disk() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SETTINGS_PATH)
	var ip: String = DEFAULT_IP
	var port: int = DEFAULT_PORT
	var rtype: String = DEFAULT_TYPE
	var face_locked: bool = DEFAULT_FACE_LOCKED
	var show_on_launch: bool = DEFAULT_SHOW_ON_LAUNCH
	if err == OK:
		ip = cfg.get_value(SECTION, "ip", DEFAULT_IP)
		port = int(cfg.get_value(SECTION, "port", DEFAULT_PORT))
		rtype = cfg.get_value(SECTION, "robot_type", DEFAULT_TYPE)
		face_locked = bool(cfg.get_value(SECTION, "video_face_locked", DEFAULT_FACE_LOCKED))
		show_on_launch = bool(cfg.get_value(SECTION, "show_on_launch", DEFAULT_SHOW_ON_LAUNCH))

	_ip_input.text = ip
	_port_input.text = str(port)
	var type_idx := ROBOT_TYPES.find(rtype)
	if type_idx < 0:
		type_idx = 0
	_type_option.select(type_idx)
	_video_face_toggle.button_pressed = face_locked
	_show_on_launch_toggle.button_pressed = show_on_launch

	var status_key := "UI_LOADED_SETTINGS" if err == OK else "UI_USING_DEFAULTS"
	set_status(tr(status_key))


func _save_to_disk(ip: String, port: int, rtype: String, face_locked: bool, show_on_launch: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "ip", ip)
	cfg.set_value(SECTION, "port", port)
	cfg.set_value(SECTION, "robot_type", rtype)
	cfg.set_value(SECTION, "video_face_locked", face_locked)
	cfg.set_value(SECTION, "show_on_launch", show_on_launch)
	var err := cfg.save(SETTINGS_PATH)
	if err != OK:
		push_warning("[Settings] Failed to save %s: error %d" % [SETTINGS_PATH, err])


func _on_discovery_selected(idx: int) -> void:
	if idx <= 0:
		_apply_mode_lock()
		set_status(tr("UI_MANUAL_ENTRY_STATUS"))
		return

	var rname: String = String(_discovery_option.get_item_metadata(idx))
	if not _discovered.has(rname):
		return
	var info: Dictionary = _discovered[rname]
	_ip_input.text = String(info.get("ip", DEFAULT_IP))
	_port_input.text = str(int(info.get("pose_port", DEFAULT_PORT)))
	var dtype: String = String(info.get("device_type", ""))
	if dtype != "":
		var t_idx := ROBOT_TYPES.find(dtype)
		if t_idx >= 0:
			_type_option.select(t_idx)
	_apply_mode_lock()
	set_status(tr("UI_WILL_CONNECT_TO") % _format_robot_label(rname, info))


func _apply_mode_lock() -> void:
	var manual := _discovery_option.selected <= 0
	_ip_input.editable = manual
	_port_input.editable = manual


func _format_robot_label(rname: String, info: Dictionary) -> String:
	var dname: String = String(info.get("device_name", ""))
	var head: String = rname
	if dname != "":
		head = dname
	var dtype: String = String(info.get("device_type", ""))
	var type_suffix := ""
	if dtype != "":
		type_suffix = " (%s)" % _robot_type_display(dtype)
	return "%s%s — %s:%d" % [head, type_suffix, String(info.get("ip", "?")), int(info.get("pose_port", 0))]


func _selected_robot_name() -> String:
	if _discovery_option == null:
		return ""
	var idx := _discovery_option.selected
	if idx <= 0:
		return ""
	return String(_discovery_option.get_item_metadata(idx))


func _robot_type_display(robot_type: String) -> String:
	match robot_type:
		"robot_arm":
			return tr("UI_DEVICE_TYPE_ROBOT_ARM")
		"rc_car":
			return tr("UI_DEVICE_TYPE_RC_CAR")
		_:
			return robot_type


static func load_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	var out := {
		"ip": DEFAULT_IP,
		"port": DEFAULT_PORT,
		"robot_type": DEFAULT_TYPE,
		"video_face_locked": DEFAULT_FACE_LOCKED,
		"show_on_launch": DEFAULT_SHOW_ON_LAUNCH,
		"loaded": false,
	}
	if cfg.load(SETTINGS_PATH) == OK:
		out["ip"] = cfg.get_value(SECTION, "ip", DEFAULT_IP)
		out["port"] = int(cfg.get_value(SECTION, "port", DEFAULT_PORT))
		out["robot_type"] = cfg.get_value(SECTION, "robot_type", DEFAULT_TYPE)
		out["video_face_locked"] = bool(cfg.get_value(SECTION, "video_face_locked", DEFAULT_FACE_LOCKED))
		out["show_on_launch"] = bool(cfg.get_value(SECTION, "show_on_launch", DEFAULT_SHOW_ON_LAUNCH))
		out["loaded"] = true
	return out
