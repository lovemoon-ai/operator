extends Control
## Settings panel UI — embedded inside a Viewport2DIn3D wrapper.
##
## Visual style mirrors GodotQuestCapture's ViewLockedCapturePanel:
##   - dark translucent panel, subtle border, rounded corners
##   - muted section labels above full-width controls
##   - every interactive control wrapped in a "slot" PanelContainer that
##     highlights with the operator accent border on pointer hover (mouse_entered)
##   - CheckButton (switch) toggles instead of CheckBox
##
## The whole UI is built in code (not a .tscn layout) so the hover-slot
## wrapping and theming stay in one place.
##
## Behaviour:
##   - Discovered dropdown (Auto): pick a robot found via UDP broadcast.
##     IP/Port show the discovered values, read-only.
##   - Manual entry: dropdown set to "─ Manual entry ─", IP/Port editable.
##   - Confirm → save to user://settings.cfg + emit settings_applied(...)
##   - Exit requires a short hold, then hides the panel without connecting.

signal settings_applied(ip: String, port: int, robot_type: String, video_face_locked: bool, show_on_launch: bool)
signal close_requested()

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "settings"

const ROBOT_TYPES: Array[String] = ["robot_arm", "rc_car"]
const DEFAULT_IP: String = "127.0.0.1"
const DEFAULT_PORT: int = 63901
const DEFAULT_TYPE: String = "robot_arm"
const DEFAULT_FACE_LOCKED: bool = true
const DEFAULT_SHOW_ON_LAUNCH: bool = false
const EXIT_HOLD_SECONDS := 2.0

const MANUAL_LABEL_KEY := "UI_MANUAL_ENTRY"

# --- Palette --------------------------------------------------------
const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_SECTION := Color(0.65, 0.70, 0.75)
const COL_STATUS := Color(0.55, 0.80, 0.66)
const COL_ACCENT := Color(1.0, 0.647, 0.169, 0.98)

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
		draw_line(Vector2(inset, y), Vector2(end_x, y), Color(1.0, 0.647, 0.169, 0.98), 4.0, true)

# --- Built controls ----------------------------------------------------------
var _discovery_option: OptionButton
var _ip_input: LineEdit
var _port_input: LineEdit
var _type_option: OptionButton
var _video_face_toggle: CheckButton
var _show_on_launch_toggle: CheckButton
var _status_label: Label
var _exit_indicator: HoldIndicator
var _exit_holding := false
var _exit_hold_seconds := 0.0

## name -> { ip, pose_port, video_port, device_type, device_name }
var _discovered: Dictionary = {}
## Currently hover-highlighted slot.
var _highlighted_slot: PanelContainer


func _ready() -> void:
	_build_ui()
	_load_from_disk()
	_apply_mode_lock()
	print("[SettingsUI] ready (manual mode; %d discovered)" % (_discovery_option.item_count - 1))


func _process(delta: float) -> void:
	if not _exit_holding:
		return
	_exit_hold_seconds = minf(_exit_hold_seconds + delta, EXIT_HOLD_SECONDS)
	if _exit_indicator:
		_exit_indicator.set_progress(_exit_hold_seconds / EXIT_HOLD_SECONDS)
	if _exit_hold_seconds < EXIT_HOLD_SECONDS:
		return
	_cancel_exit_hold()
	close_requested.emit()


# --- UI construction ----------------------------------------------------------

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = COL_PANEL_BG
	panel_style.border_color = COL_PANEL_BORDER
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)

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
	title.text = tr("UI_SETTINGS_TITLE")
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", COL_TITLE)
	content.add_child(title)

	# --- Connect-to section ---
	content.add_child(_section_label("UI_CONNECT_TO"))

	_discovery_option = OptionButton.new()
	_discovery_option.custom_minimum_size.y = 55
	_discovery_option.add_theme_font_size_override("font_size", 23)
	_discovery_option.add_item(tr(MANUAL_LABEL_KEY))
	_discovery_option.set_item_metadata(0, "")
	_discovery_option.item_selected.connect(_on_discovery_selected)
	_add_interactive(content, _discovery_option)

	_ip_input = LineEdit.new()
	_ip_input.placeholder_text = tr("UI_ROBOT_IP")
	_ip_input.text = DEFAULT_IP
	_ip_input.custom_minimum_size.y = 55
	_ip_input.add_theme_font_size_override("font_size", 21)
	_add_interactive(content, _ip_input)

	_port_input = LineEdit.new()
	_port_input.placeholder_text = tr("UI_PORT")
	_port_input.text = str(DEFAULT_PORT)
	_port_input.custom_minimum_size.y = 55
	_port_input.add_theme_font_size_override("font_size", 21)
	_add_interactive(content, _port_input)

	# --- Device section ---
	content.add_child(_section_label("UI_ROBOT_TYPE"))

	_type_option = OptionButton.new()
	_type_option.custom_minimum_size.y = 55
	_type_option.add_theme_font_size_override("font_size", 23)
	for t in ROBOT_TYPES:
		_type_option.add_item(_robot_type_display(t))
		_type_option.set_item_metadata(_type_option.item_count - 1, t)
	_add_interactive(content, _type_option)

	# --- Video + options toggles ---
	_video_face_toggle = CheckButton.new()
	_video_face_toggle.text = tr("UI_FACE_LOCKED_VIDEO")
	_video_face_toggle.button_pressed = DEFAULT_FACE_LOCKED
	_video_face_toggle.custom_minimum_size.y = 47
	_video_face_toggle.add_theme_font_size_override("font_size", 22)
	_add_interactive(content, _video_face_toggle)

	_show_on_launch_toggle = CheckButton.new()
	_show_on_launch_toggle.text = tr("UI_SHOW_SETTINGS_ON_LAUNCH")
	_show_on_launch_toggle.button_pressed = DEFAULT_SHOW_ON_LAUNCH
	_show_on_launch_toggle.custom_minimum_size.y = 47
	_show_on_launch_toggle.add_theme_font_size_override("font_size", 22)
	_add_interactive(content, _show_on_launch_toggle)

	_status_label = Label.new()
	_status_label.text = tr("UI_STATUS_PREFIX") % tr("UI_STATUS_EMPTY")
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.add_theme_color_override("font_color", COL_STATUS)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_status_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(spacer)

	# --- Actions ---
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 14)
	content.add_child(actions)

	var ok_button := Button.new()
	ok_button.text = tr("UI_OK")
	ok_button.custom_minimum_size.y = 68
	ok_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok_button.add_theme_font_size_override("font_size", 28)
	ok_button.pressed.connect(_on_ok_pressed)
	_add_interactive(actions, ok_button)

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


func _section_label(text_key: String) -> Label:
	var lbl := Label.new()
	lbl.text = tr(text_key)
	lbl.add_theme_font_size_override("font_size", 21)
	lbl.add_theme_color_override("font_color", COL_SECTION)
	return lbl


# --- Hover-highlight slots ---------------------------------------------------

func _add_interactive(parent: Container, control: Control) -> PanelContainer:
	var slot := PanelContainer.new()
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
	style.border_color = COL_ACCENT if highlighted else Color.TRANSPARENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	return style


# --- Persistence -------------------------------------------------------------

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
	_set_status(tr(status_key))


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


# --- Discovery integration ---------------------------------------------------

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
		# OptionButton.add_item() returns void in Godot 4; query the index after.
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


# --- UI callbacks ------------------------------------------------------------

func _on_discovery_selected(idx: int) -> void:
	if idx <= 0:
		_apply_mode_lock()
		_set_status(tr("UI_MANUAL_ENTRY_STATUS"))
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
	_set_status(tr("UI_WILL_CONNECT_TO") % _format_robot_label(rname, info))


func _apply_mode_lock() -> void:
	var manual := _discovery_option.selected <= 0
	_ip_input.editable = manual
	_port_input.editable = manual


func _on_ok_pressed() -> void:
	_cancel_exit_hold()
	var ip := _ip_input.text.strip_edges()
	var port := _port_input.text.strip_edges().to_int()
	if ip.is_empty():
		_set_status(tr("UI_IP_REQUIRED"))
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
	_set_status(tr("UI_APPLYING"))
	settings_applied.emit(ip, port, rtype, face_locked, show_on_launch)


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


# --- External hooks ----------------------------------------------------------

func set_status(text: String) -> void:
	_set_status(text)


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = tr("UI_STATUS_PREFIX") % text


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
