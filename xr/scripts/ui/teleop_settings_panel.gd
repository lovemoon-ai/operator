extends "res://scripts/ui/two_column_settings_panel.gd"
class_name TeleopSettingsPanel

signal settings_applied(ip: String, port: int, robot_type: String, video_face_locked: bool, show_video_panel: bool, show_on_launch: bool)
signal close_requested

const SETTINGS_PATH := "user://teleop_settings.cfg"
const SECTION := "settings"

const ROBOT_TYPES: Array[String] = ["robot_arm", "rc_car"]
const DEFAULT_IP: String = "127.0.0.1"
const DEFAULT_PORT: int = 63901
const DEFAULT_TYPE: String = "robot_arm"
const DEFAULT_FACE_LOCKED: bool = true
# Default OFF so a freshly installed app doesn't blast a placeholder quad in
# front of the user. Showing the panel requires both this opt-in AND the robot
# actually sending frames — see LiveVideoView._update_panel_visibility.
const DEFAULT_SHOW_VIDEO_PANEL: bool = false
const DEFAULT_SHOW_ON_LAUNCH: bool = false
const MANUAL_LABEL_KEY := "UI_MANUAL_ENTRY"

class DiscoverySpinner:
	extends Control

	var active := false
	var accent_color := Color(1.0, 0.647, 0.169, 0.98)
	var _angle := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(26, 26)
		visible = false
		set_process(false)

	func set_active(value: bool) -> void:
		if active == value:
			return
		active = value
		visible = active
		set_process(active)
		queue_redraw()

	func _process(delta: float) -> void:
		_angle = wrapf(_angle + delta * 4.2, 0.0, PI * 2.0)
		queue_redraw()

	func _draw() -> void:
		if not active:
			return
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.5 - 3.0
		var base_color := Color(accent_color.r, accent_color.g, accent_color.b, 0.18)
		draw_arc(center, radius, 0.0, PI * 2.0, 40, base_color, 3.0, true)
		draw_arc(center, radius, _angle, _angle + PI * 1.45, 28, accent_color, 3.4, true)

var _discovery_option: OptionButton
var _ip_input: LineEdit
var _port_input: LineEdit
var _type_option: OptionButton
var _video_face_toggle: CheckButton
var _show_video_panel_toggle: CheckButton
var _show_on_launch_toggle: CheckButton
var _status_label: Label
var _discovery_spinner: DiscoverySpinner
var _discovery_active := false
var _discovered: Dictionary = {}


func _init() -> void:
	# 840 wide gives ~430px of detail column after sidebar + margins,
	# 720 tall replaces the legacy 884 — there's no longer a single tall
	# scroll list, each group fits comfortably.
	_setup_two_column_panel(Vector2i(840, 720), Vector2(0.63, 0.54), "UI_SETTINGS_TITLE", "UI_OK", 2, false)
	var settings := _load_settings()
	set_options(settings)
	set_status(tr("UI_LOADED_SETTINGS" if bool(settings.get("loaded", false)) else "UI_USING_DEFAULTS"))
	_apply_mode_lock()
	print("[SettingsUI] ready (manual mode; %d discovered)" % (_discovery_option.item_count - 1))


func _settings_path() -> String:
	return SETTINGS_PATH


func _settings_section() -> String:
	return SECTION


func _settings_defaults() -> Dictionary:
	return _default_options()


func _settings_loaded_key() -> String:
	return "loaded"


func _settings_log_tag() -> String:
	return "Settings"


func _build_settings_content(parent: VBoxContainer) -> void:
	build_two_column(parent)

	# --- Connection group --------------------------------------------------
	var connection := register_group("connection", "UI_GROUP_CONNECTION", "signal")

	_discovery_option = OptionButton.new()
	_discovery_option.custom_minimum_size.y = 55
	_discovery_option.add_theme_font_size_override("font_size", 23)
	_add_option_item(_discovery_option, tr(MANUAL_LABEL_KEY), "", "signal")
	_discovery_option.item_selected.connect(_on_discovery_selected)
	add_interactive(connection, _discovery_option)

	_ip_input = LineEdit.new()
	_ip_input.placeholder_text = tr("UI_ROBOT_IP")
	_ip_input.text = DEFAULT_IP
	_ip_input.custom_minimum_size.y = 55
	_ip_input.add_theme_font_size_override("font_size", 21)
	add_interactive(connection, _ip_input)

	_port_input = LineEdit.new()
	_port_input.placeholder_text = tr("UI_PORT")
	_port_input.text = str(DEFAULT_PORT)
	_port_input.custom_minimum_size.y = 55
	_port_input.add_theme_font_size_override("font_size", 21)
	add_interactive(connection, _port_input)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 10)
	status_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection.add_child(status_row)

	_discovery_spinner = DiscoverySpinner.new()
	_discovery_spinner.accent_color = COL_ACCENT
	status_row.add_child(_discovery_spinner)

	_status_label = Label.new()
	_status_label.text = tr("UI_STATUS_PREFIX") % tr("UI_STATUS_EMPTY")
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.add_theme_color_override("font_color", COL_STATUS)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)

	# --- Robot group -------------------------------------------------------
	var robot := register_group("robot", "UI_GROUP_ROBOT", "robot-arm")

	_type_option = OptionButton.new()
	_type_option.custom_minimum_size.y = 55
	_type_option.add_theme_font_size_override("font_size", 23)
	for t in ROBOT_TYPES:
		_add_option_item(_type_option, _robot_type_display(t), t, _icon_name_for_robot_type(t))
	add_interactive(robot, _type_option)

	# --- Display group -----------------------------------------------------
	var display := register_group("display", "UI_GROUP_DISPLAY", "settings")
	_video_face_toggle = add_toggle(display, tr("UI_FACE_LOCKED_VIDEO"), DEFAULT_FACE_LOCKED, 22)
	_show_video_panel_toggle = add_toggle(display, tr("UI_SHOW_VIDEO_PANEL"), DEFAULT_SHOW_VIDEO_PANEL, 22)

	# --- Startup group -----------------------------------------------------
	var startup := register_group("startup", "UI_GROUP_STARTUP", "power")
	_show_on_launch_toggle = add_toggle(startup, tr("UI_SHOW_SETTINGS_ON_LAUNCH"), DEFAULT_SHOW_ON_LAUNCH, 22)

	# Connection is shown by default (first registered), no explicit select needed.


func _on_confirm_requested() -> void:
	var ip := _ip_input.text.strip_edges()
	var port := _port_input.text.strip_edges().to_int()
	if ip.is_empty():
		set_status(tr("UI_IP_REQUIRED"))
		return
	if port <= 0 or port > 65535:
		port = DEFAULT_PORT
		_port_input.text = str(port)
	_ip_input.text = ip

	var options := get_options()
	_save_settings(options)
	set_status(tr("UI_APPLYING"))
	settings_applied.emit(
			str(options.get("ip", DEFAULT_IP)),
			int(options.get("port", DEFAULT_PORT)),
			str(options.get("robot_type", DEFAULT_TYPE)),
			bool(options.get("video_face_locked", DEFAULT_FACE_LOCKED)),
			bool(options.get("show_video_panel", DEFAULT_SHOW_VIDEO_PANEL)),
			bool(options.get("show_on_launch", DEFAULT_SHOW_ON_LAUNCH))
	)


func set_discovery_state(known_robots: Dictionary, prefer_ip: String = "") -> void:
	_discovered = known_robots.duplicate(true)

	var previously_selected_name := _selected_robot_name()

	_discovery_option.clear()
	_add_option_item(_discovery_option, tr(MANUAL_LABEL_KEY), "", "signal")

	var names: Array = _discovered.keys()
	names.sort()
	var idx_to_select := 0
	for i in range(names.size()):
		var rname: String = names[i]
		var info: Dictionary = _discovered[rname]
		var disp := _format_robot_label(rname, info)
		var idx := _add_option_item(
			_discovery_option,
			disp,
			rname,
			_icon_name_for_robot_type(String(info.get("device_type", "")))
		)
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
	if not _discovery_active and _discovery_spinner:
		_discovery_spinner.set_active(false)


func set_discovering(active: bool, text: String = "") -> void:
	_discovery_active = active
	if _discovery_spinner:
		_discovery_spinner.set_active(active)
	if not text.is_empty():
		set_status(text)


func get_options() -> Dictionary:
	var rtype := DEFAULT_TYPE
	if _type_option.selected >= 0:
		rtype = String(_type_option.get_item_metadata(_type_option.selected))
	return {
		"ip": _ip_input.text.strip_edges(),
		"port": _port_input.text.strip_edges().to_int(),
		"robot_type": rtype,
		"video_face_locked": _video_face_toggle.button_pressed,
		"show_video_panel": _show_video_panel_toggle.button_pressed,
		"show_on_launch": _show_on_launch_toggle.button_pressed
	}


func set_options(options: Dictionary) -> void:
	_ip_input.text = str(options.get("ip", DEFAULT_IP))
	_port_input.text = str(int(options.get("port", DEFAULT_PORT)))
	var rtype := str(options.get("robot_type", DEFAULT_TYPE))
	var type_idx := ROBOT_TYPES.find(rtype)
	if type_idx < 0:
		type_idx = 0
	_type_option.select(type_idx)
	_video_face_toggle.button_pressed = bool(options.get("video_face_locked", DEFAULT_FACE_LOCKED))
	_show_video_panel_toggle.button_pressed = bool(options.get("show_video_panel", DEFAULT_SHOW_VIDEO_PANEL))
	_show_on_launch_toggle.button_pressed = bool(options.get("show_on_launch", DEFAULT_SHOW_ON_LAUNCH))


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


func _icon_name_for_robot_type(robot_type: String) -> String:
	match robot_type:
		"robot_arm":
			return "robot-arm"
		"rc_car":
			return "car"
		_:
			return "signal"


func _add_option_item(option: OptionButton, label: String, metadata: Variant, icon_name: String) -> int:
	option.add_item(label)
	var idx := option.item_count - 1
	option.set_item_metadata(idx, metadata)
	var icon := _load_icon(icon_name)
	if icon != null:
		option.set_item_icon(idx, icon)
	return idx


static func load_settings() -> Dictionary:
	return BaseSettingsPanel.load_settings_from_config(SETTINGS_PATH, SECTION, _default_options(), "loaded")


static func _default_options() -> Dictionary:
	return {
		"ip": DEFAULT_IP,
		"port": DEFAULT_PORT,
		"robot_type": DEFAULT_TYPE,
		"video_face_locked": DEFAULT_FACE_LOCKED,
		"show_video_panel": DEFAULT_SHOW_VIDEO_PANEL,
		"show_on_launch": DEFAULT_SHOW_ON_LAUNCH
	}
