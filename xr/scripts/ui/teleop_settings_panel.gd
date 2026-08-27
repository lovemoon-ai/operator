extends "res://scripts/ui/two_column_settings_panel.gd"
class_name TeleopSettingsPanel

signal settings_applied(options: Dictionary)
signal close_requested
signal pico_body_calibration_requested
signal video_connect_requested(options: Dictionary)

const SETTINGS_PATH := "user://teleop_settings.cfg"
const SECTION := "settings"
const RobotProfileRegistryScript := preload(
	"res://scripts/teleop/retargeting/robot_profile_registry.gd"
)

const DEFAULT_IP: String = "127.0.0.1"
const DEFAULT_PORT: int = 63901
const DEFAULT_TARGET_SCOPE := "outside"
const DEFAULT_PROTOCOL := "operator"
const DEFAULT_XROBOT_TOOLKIT_DEVICE_SN := ""
const PROTOCOL_OPERATOR := "operator"
const PROTOCOL_XROBOT_TOOLKIT_V1 := "xrobot_toolkit_v1"
const DEFAULT_RETARGETING_BACKEND := "native"
const DEFAULT_RETARGETING_HOST := "127.0.0.1"
const DEFAULT_RETARGETING_PORT := 8000
const VIDEO_PROTOCOL_OPERATOR := "operator_timed_h264"
const VIDEO_PROTOCOL_XROBOT_TOOLKIT := "xrobot_toolkit_fpv"
const DEFAULT_VIDEO_PROTOCOL := VIDEO_PROTOCOL_OPERATOR
const DEFAULT_VIDEO_IP := "127.0.0.1"
const DEFAULT_OPERATOR_VIDEO_PORT := 12345
const DEFAULT_XROBOT_TOOLKIT_COMMAND_PORT := 13579
const DEFAULT_FACE_LOCKED: bool = true
# Default OFF so a freshly installed app doesn't blast a placeholder quad in
# front of the user. Showing the panel requires both this opt-in AND the robot
# actually sending frames — see LiveVideoView._update_panel_visibility.
const DEFAULT_SHOW_VIDEO_PANEL: bool = false
const DEFAULT_SHOW_OPERATION_TRAJECTORY: bool = false
const DEFAULT_SHOW_VR_POSE: bool = false
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

const IP_TEST_TIMEOUT_MSEC := 2000
const IP_TEST_RESULT_SECS := 3.0
const COL_IP_TEST_OK := Color(0.14, 0.82, 0.45)
const COL_IP_TEST_FAIL := Color(1.0, 0.36, 0.30)

var _discovery_option: OptionButton
var _inside_scope_button: Button
var _outside_scope_button: Button
var _target_scope := DEFAULT_TARGET_SCOPE
var _outside_box: VBoxContainer
var _protocol_row: HBoxContainer
var _protocol_buttons: Dictionary = {}
var _selected_protocol := DEFAULT_PROTOCOL
var _inside_box: VBoxContainer
var _inside_missing_label: Label
var _inside_profile_row: VBoxContainer
var _profile_buttons: Dictionary = {}
var _selected_profile := ""
var _backend_row: HBoxContainer
var _backend_buttons: Dictionary = {}
var _selected_backend := DEFAULT_RETARGETING_BACKEND
var _retargeting_host_input: LineEdit
var _retargeting_port_input: LineEdit
var _retargeting_tls_toggle: CheckButton
var _retargeting_status_label: Label
var _ip_input: LineEdit
var _ip_test_button: Button
var _ip_test_peer: StreamPeerTCP
var _ip_test_deadline_msec := 0
var _ip_test_token := 0
var _port_input: LineEdit
var _xrobot_toolkit_device_sn_input: LineEdit
var _pico_body_calibration_button: Button
var _video_protocol_row: HBoxContainer
var _video_protocol_buttons: Dictionary = {}
var _selected_video_protocol := DEFAULT_VIDEO_PROTOCOL
var _video_ip_input: LineEdit
var _video_port_label: Label
var _video_port_input: LineEdit
var _video_sbs_toggle: CheckButton
var _video_connect_button: Button
var _video_status_label: Label
var _video_face_toggle: CheckButton
var _show_video_panel_toggle: CheckButton
var _show_operation_trajectory_toggle: CheckButton
var _show_vr_pose_toggle: CheckButton
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
	print(
		"[SettingsUI] ready (manual mode; %d discovered; scope=%s; inside robots=%s)"
		% [
			_discovery_option.item_count - 1,
			_target_scope,
			str(RobotProfileRegistryScript.ids()),
		]
	)


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

	# --- Robot group -------------------------------------------------------
	# One group for the whole robot decision: pick where the embodiment lives,
	# then configure only that side. Inside and Outside share no settings, so
	# showing both at once was only ever noise.
	var robot := register_group("robot", "UI_ROBOT_CONFIG", "robot-arm")

	var type_label := Label.new()
	type_label.text = tr("UI_ROBOT_SCOPE")
	type_label.add_theme_font_size_override("font_size", 19)
	type_label.add_theme_color_override("font_color", COL_SECTION)
	robot.add_child(type_label)

	var type_row := HBoxContainer.new()
	type_row.add_theme_constant_override("separation", 10)
	type_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	robot.add_child(type_row)
	_inside_scope_button = _add_scope_button(type_row, tr("UI_INSIDE_ROBOT"), "inside")
	_outside_scope_button = _add_scope_button(type_row, tr("UI_OUTSIDE_ROBOT"), "outside")

	# --- Outside Robot (robot-service) -------------------------------------
	var connection := VBoxContainer.new()
	connection.add_theme_constant_override("separation", 12)
	connection.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	robot.add_child(connection)
	_outside_box = connection

	var protocol_label := Label.new()
	protocol_label.text = tr("UI_PROTOCOL")
	protocol_label.add_theme_font_size_override("font_size", 19)
	protocol_label.add_theme_color_override("font_color", COL_SECTION)
	connection.add_child(protocol_label)

	_protocol_row = HBoxContainer.new()
	_protocol_row.add_theme_constant_override("separation", 10)
	_protocol_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection.add_child(_protocol_row)
	for protocol in [
		[PROTOCOL_OPERATOR, tr("UI_PROTOCOL_OPERATOR")],
		[PROTOCOL_XROBOT_TOOLKIT_V1, tr("UI_PROTOCOL_XROBOT_TOOLKIT_V1")],
	]:
		var protocol_id := str(protocol[0])
		_protocol_buttons[protocol_id] = _add_choice_button(
			_protocol_row,
			str(protocol[1]),
			_on_protocol_pressed.bind(protocol_id)
		)

	_discovery_option = OptionButton.new()
	_discovery_option.custom_minimum_size.y = 55
	# Robot names and types come from the service descriptor and are not
	# length-bounded.  OptionButton otherwise uses its longest item to compute
	# its minimum width, which can widen the whole settings layout and push the
	# bottom action row (including Exit) outside the viewport.
	_discovery_option.fit_to_longest_item = false
	_discovery_option.clip_text = true
	_discovery_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_discovery_option.add_theme_font_size_override("font_size", 23)
	_add_option_item(_discovery_option, tr(MANUAL_LABEL_KEY), "", "signal")
	_discovery_option.item_selected.connect(_on_discovery_selected)
	add_interactive(connection, _discovery_option)

	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 10)
	ip_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection.add_child(ip_row)

	_ip_input = LineEdit.new()
	_ip_input.placeholder_text = tr("UI_ROBOT_IP")
	_ip_input.text = DEFAULT_IP
	_ip_input.custom_minimum_size.y = 55
	_ip_input.add_theme_font_size_override("font_size", 21)
	add_interactive(ip_row, _ip_input)

	_ip_test_button = Button.new()
	_ip_test_button.text = tr("UI_TEST_IP")
	_ip_test_button.focus_mode = Control.FOCUS_NONE
	_ip_test_button.custom_minimum_size = Vector2(96, 55)
	_ip_test_button.add_theme_font_size_override("font_size", 21)
	_ip_test_button.pressed.connect(_on_ip_test_pressed)
	ip_row.add_child(_ip_test_button)

	_port_input = LineEdit.new()
	_port_input.placeholder_text = tr("UI_PORT")
	_port_input.text = str(DEFAULT_PORT)
	_port_input.custom_minimum_size.y = 55
	_port_input.add_theme_font_size_override("font_size", 21)
	add_interactive(connection, _port_input)

	_xrobot_toolkit_device_sn_input = LineEdit.new()
	_xrobot_toolkit_device_sn_input.placeholder_text = tr("UI_XROBOT_TOOLKIT_DEVICE_SN")
	_xrobot_toolkit_device_sn_input.custom_minimum_size.y = 55
	_xrobot_toolkit_device_sn_input.add_theme_font_size_override("font_size", 21)
	_xrobot_toolkit_device_sn_input.tooltip_text = tr("UI_XROBOT_TOOLKIT_DEVICE_SN_TOOLTIP")
	add_interactive(connection, _xrobot_toolkit_device_sn_input)

	_pico_body_calibration_button = Button.new()
	_pico_body_calibration_button.text = tr("UI_PICO_BODY_CALIBRATION")
	_pico_body_calibration_button.focus_mode = Control.FOCUS_NONE
	_pico_body_calibration_button.custom_minimum_size.y = 55
	_pico_body_calibration_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pico_body_calibration_button.add_theme_font_size_override("font_size", 21)
	_pico_body_calibration_button.pressed.connect(_on_pico_body_calibration_pressed)
	add_interactive(connection, _pico_body_calibration_button)

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

	# For an Outside robot the robot *type* is intentionally not a user
	# setting: what the XR client sends is defined entirely by the
	# DeviceDescriptor the robot sends on handshake (input_mapping /
	# control_schema). The discovery list above still shows each robot's
	# self-reported device_type as a label.

	# --- Inside Robot (in-headset embodiment) ------------------------------
	var inside := VBoxContainer.new()
	inside.add_theme_constant_override("separation", 12)
	inside.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	robot.add_child(inside)
	_inside_box = inside

	# Every robot is a button rather than a dropdown entry. An OptionButton
	# opens a PopupMenu, which is a separate window that never reaches this
	# panel's composition viewport — in the headset the operator would only
	# ever see the currently selected robot and could not switch.
	_inside_profile_row = VBoxContainer.new()
	_inside_profile_row.add_theme_constant_override("separation", 8)
	_inside_profile_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inside.add_child(_inside_profile_row)
	# Robots come from the manifests shipped in this build, never from a
	# hardcoded list: generating a robot's assets is what makes it selectable.
	for profile in RobotProfileRegistryScript.list_profiles():
		var profile_id := str(profile.get("profile_id", ""))
		var button := _add_choice_button(
			_inside_profile_row,
			str(profile.get("display_name", profile_id)),
			_on_inside_profile_pressed.bind(profile_id)
		)
		_profile_buttons[profile_id] = button

	_inside_missing_label = Label.new()
	_inside_missing_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inside_missing_label.add_theme_font_size_override("font_size", 18)
	_inside_missing_label.add_theme_color_override("font_color", COL_STATUS)
	_inside_missing_label.visible = false
	inside.add_child(_inside_missing_label)

	_backend_row = HBoxContainer.new()
	_backend_row.add_theme_constant_override("separation", 10)
	_backend_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inside.add_child(_backend_row)
	for backend in [["native", "UI_RETARGETING_NATIVE"], ["remote", "UI_RETARGETING_REMOTE"]]:
		var backend_id := str(backend[0])
		_backend_buttons[backend_id] = _add_choice_button(
			_backend_row, tr(str(backend[1])), _on_retargeting_backend_pressed.bind(backend_id)
		)

	_retargeting_host_input = LineEdit.new()
	_retargeting_host_input.placeholder_text = tr("UI_RETARGETING_HOST")
	_retargeting_host_input.custom_minimum_size.y = 55
	_retargeting_host_input.add_theme_font_size_override("font_size", 21)
	add_interactive(inside, _retargeting_host_input)

	_retargeting_port_input = LineEdit.new()
	_retargeting_port_input.placeholder_text = tr("UI_RETARGETING_PORT")
	_retargeting_port_input.custom_minimum_size.y = 55
	_retargeting_port_input.add_theme_font_size_override("font_size", 21)
	add_interactive(inside, _retargeting_port_input)

	_retargeting_tls_toggle = add_toggle(inside, tr("UI_RETARGETING_TLS"), false, 21)
	_retargeting_status_label = Label.new()
	_retargeting_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_retargeting_status_label.add_theme_font_size_override("font_size", 18)
	_retargeting_status_label.add_theme_color_override("font_color", COL_STATUS)
	inside.add_child(_retargeting_status_label)

	# --- Video group -------------------------------------------------------
	var video := register_group("video", "UI_GROUP_VIDEO", "camera")

	var video_protocol_label := Label.new()
	video_protocol_label.text = tr("UI_VIDEO_PROTOCOL")
	video_protocol_label.add_theme_font_size_override("font_size", 19)
	video_protocol_label.add_theme_color_override("font_color", COL_SECTION)
	video.add_child(video_protocol_label)

	_video_protocol_row = HBoxContainer.new()
	_video_protocol_row.add_theme_constant_override("separation", 10)
	_video_protocol_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	video.add_child(_video_protocol_row)
	for protocol in [
		[VIDEO_PROTOCOL_OPERATOR, "UI_VIDEO_PROTOCOL_OPERATOR"],
		[VIDEO_PROTOCOL_XROBOT_TOOLKIT, "UI_VIDEO_PROTOCOL_XROBOT_TOOLKIT"],
	]:
		var protocol_id := str(protocol[0])
		_video_protocol_buttons[protocol_id] = _add_choice_button(
			_video_protocol_row,
			tr(str(protocol[1])),
			_on_video_protocol_pressed.bind(protocol_id)
		)

	var video_ip_label := Label.new()
	video_ip_label.text = tr("UI_VIDEO_IP")
	video_ip_label.add_theme_font_size_override("font_size", 19)
	video_ip_label.add_theme_color_override("font_color", COL_SECTION)
	video.add_child(video_ip_label)

	var video_ip_row := HBoxContainer.new()
	video_ip_row.add_theme_constant_override("separation", 10)
	video_ip_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	video.add_child(video_ip_row)

	_video_ip_input = LineEdit.new()
	_video_ip_input.placeholder_text = tr("UI_VIDEO_IP")
	_video_ip_input.text = DEFAULT_VIDEO_IP
	_video_ip_input.custom_minimum_size.y = 55
	_video_ip_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_video_ip_input.add_theme_font_size_override("font_size", 21)
	add_interactive(video_ip_row, _video_ip_input)

	_video_connect_button = Button.new()
	_video_connect_button.text = tr("UI_CONNECT")
	_video_connect_button.focus_mode = Control.FOCUS_NONE
	_video_connect_button.custom_minimum_size = Vector2(112, 55)
	_video_connect_button.add_theme_font_size_override("font_size", 21)
	_video_connect_button.pressed.connect(_on_video_connect_pressed)
	video_ip_row.add_child(_video_connect_button)

	_video_port_label = Label.new()
	_video_port_label.add_theme_font_size_override("font_size", 19)
	_video_port_label.add_theme_color_override("font_color", COL_SECTION)
	video.add_child(_video_port_label)

	_video_port_input = LineEdit.new()
	_video_port_input.text = str(DEFAULT_OPERATOR_VIDEO_PORT)
	_video_port_input.custom_minimum_size.y = 55
	_video_port_input.add_theme_font_size_override("font_size", 21)
	add_interactive(video, _video_port_input)

	_video_sbs_toggle = add_toggle(video, tr("UI_VIDEO_SBS"), false, 22)
	_video_face_toggle = add_toggle(video, tr("UI_FACE_LOCKED_VIDEO"), DEFAULT_FACE_LOCKED, 22)
	_show_video_panel_toggle = add_toggle(video, tr("UI_SHOW_VIDEO_PANEL"), DEFAULT_SHOW_VIDEO_PANEL, 22)

	_video_status_label = Label.new()
	_video_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_video_status_label.add_theme_font_size_override("font_size", 18)
	_video_status_label.add_theme_color_override("font_color", COL_STATUS)
	video.add_child(_video_status_label)

	# --- Display group -----------------------------------------------------
	var display := register_group("display", "UI_GROUP_DISPLAY", "settings")
	_show_operation_trajectory_toggle = add_toggle(
		display,
		tr("UI_SHOW_OPERATION_TRAJECTORY"),
		DEFAULT_SHOW_OPERATION_TRAJECTORY,
		22
	)
	# The VR-pose skeleton is the operator's tracked body shown beside the
	# Inside robot; off by default, on when the operator wants to inspect input.
	_show_vr_pose_toggle = add_toggle(display, tr("UI_SHOW_VR_POSE"), DEFAULT_SHOW_VR_POSE, 22)

	# --- Startup group -----------------------------------------------------
	var startup := register_group("startup", "UI_GROUP_STARTUP", "power")
	_show_on_launch_toggle = add_toggle(startup, tr("UI_SHOW_SETTINGS_ON_LAUNCH"), DEFAULT_SHOW_ON_LAUNCH, 22)

	# The robot group is shown by default (first registered).
	call_deferred("_refresh_scope_ui")
	call_deferred("_refresh_video_protocol_ui")


## One always-visible choice button. Every selection on this page uses these
## instead of an OptionButton: a dropdown's PopupMenu is a separate window that
## never reaches this panel's composition viewport, so in the headset only the
## selected entry would be visible and the operator could not switch.
func _add_choice_button(parent: Container, label: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 58
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 22)
	button.pressed.connect(on_pressed)
	add_interactive(parent, button)
	return button


func _add_scope_button(row: HBoxContainer, label: String, scope: String) -> Button:
	return _add_choice_button(row, label, _on_scope_button_pressed.bind(scope))


func _on_confirm_requested() -> void:
	var options := get_options()
	var scope := str(options.get("target_scope", DEFAULT_TARGET_SCOPE))
	if scope == "outside":
		var ip := str(options.get("ip", "")).strip_edges()
		var port := int(options.get("port", 0))
		if ip.is_empty():
			set_status(tr("UI_IP_REQUIRED"))
			return
		if port <= 0 or port > 65535:
			set_status(tr("UI_INVALID_PORT"))
			return
	else:
		var profile_id := str(options.get("inside_profile", ""))
		var retargeting_backend := str(options.get("retargeting_backend", ""))
		if not RobotProfileRegistryScript.supports_backend(profile_id, retargeting_backend):
			set_status(tr("UI_RETARGETING_BACKEND_UNAVAILABLE"))
			return
		if retargeting_backend == "remote":
			if str(options.get("retargeting_host", "")).strip_edges().is_empty():
				set_status(tr("UI_RETARGETING_HOST_REQUIRED"))
				return
			var remote_port := int(options.get("retargeting_port", 0))
			if remote_port <= 0 or remote_port > 65535:
				set_status(tr("UI_INVALID_PORT"))
				return

	_save_settings(options)
	set_status(tr("UI_APPLYING"))
	settings_applied.emit(options)


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
	return {
		"target_scope": _target_scope,
		"protocol": _selected_protocol,
		"ip": _ip_input.text.strip_edges(),
		"port": _port_input.text.strip_edges().to_int(),
		"xrobot_toolkit_device_sn": _xrobot_toolkit_device_sn_input.text.strip_edges(),
		"inside_profile": _selected_profile,
		"retargeting_backend": _selected_backend,
		"retargeting_host": _retargeting_host_input.text.strip_edges(),
		"retargeting_port": _retargeting_port_input.text.strip_edges().to_int(),
		"retargeting_tls": _retargeting_tls_toggle.button_pressed,
		"video_protocol": _selected_video_protocol,
		"video_ip": _video_ip_input.text.strip_edges(),
		"video_port": _video_port_input.text.strip_edges().to_int(),
		"video_sbs": _video_sbs_toggle.button_pressed,
		"video_face_locked": _video_face_toggle.button_pressed,
		"show_video_panel": _show_video_panel_toggle.button_pressed,
		"show_operation_trajectory": _show_operation_trajectory_toggle.button_pressed,
		"show_vr_pose": _show_vr_pose_toggle.button_pressed,
		"show_on_launch": _show_on_launch_toggle.button_pressed
	}


func set_options(options: Dictionary) -> void:
	_target_scope = str(options.get("target_scope", DEFAULT_TARGET_SCOPE))
	if _target_scope != "inside":
		_target_scope = "outside"
	_selected_protocol = _normalized_protocol(str(options.get("protocol", DEFAULT_PROTOCOL)))
	_ip_input.text = str(options.get("ip", DEFAULT_IP))
	_port_input.text = str(int(options.get("port", DEFAULT_PORT)))
	_xrobot_toolkit_device_sn_input.text = str(
		options.get("xrobot_toolkit_device_sn", DEFAULT_XROBOT_TOOLKIT_DEVICE_SN)
	).strip_edges()
	_selected_profile = str(options.get("inside_profile", _default_inside_profile()))
	_refresh_backend_options(str(options.get("retargeting_backend", DEFAULT_RETARGETING_BACKEND)))
	_retargeting_host_input.text = str(options.get("retargeting_host", DEFAULT_RETARGETING_HOST))
	_retargeting_port_input.text = str(int(options.get("retargeting_port", DEFAULT_RETARGETING_PORT)))
	_retargeting_tls_toggle.button_pressed = bool(options.get("retargeting_tls", false))
	_selected_video_protocol = _normalized_video_protocol(
		str(options.get("video_protocol", DEFAULT_VIDEO_PROTOCOL))
	)
	_video_ip_input.text = str(options.get("video_ip", DEFAULT_VIDEO_IP))
	_video_port_input.text = str(
		int(options.get("video_port", _default_video_port(_selected_video_protocol)))
	)
	_video_sbs_toggle.button_pressed = bool(options.get("video_sbs", false))
	_video_face_toggle.button_pressed = bool(options.get("video_face_locked", DEFAULT_FACE_LOCKED))
	_show_video_panel_toggle.button_pressed = bool(options.get("show_video_panel", DEFAULT_SHOW_VIDEO_PANEL))
	_show_operation_trajectory_toggle.button_pressed = bool(
		options.get("show_operation_trajectory", DEFAULT_SHOW_OPERATION_TRAJECTORY)
	)
	_show_vr_pose_toggle.button_pressed = bool(options.get("show_vr_pose", DEFAULT_SHOW_VR_POSE))
	_show_on_launch_toggle.button_pressed = bool(options.get("show_on_launch", DEFAULT_SHOW_ON_LAUNCH))
	_refresh_protocol_buttons()
	_refresh_video_protocol_ui()
	_refresh_scope_ui()


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
	_apply_mode_lock()
	set_status(tr("UI_WILL_CONNECT_TO") % _format_robot_label(rname, info))


func _apply_mode_lock() -> void:
	if _discovery_option == null:
		return
	var manual := _discovery_option.selected <= 0
	_ip_input.editable = manual
	_port_input.editable = manual
	# A discovery beacon can auto-select a robot — and so flip these to
	# read-only — while the operator is still typing in one of them. No focus
	# change occurs, so the keyboard would stay up and silently eat keys.
	refresh_keyboard()


# --- IP reachability test ----------------------------------------------------
#
# One-shot TCP probe of the current ip:port. The command server accepts
# multiple connections (one task per client), so probing never disturbs an
# active teleop session. Result (✓/✗) shows for IP_TEST_RESULT_SECS, then the
# button reverts to its label.

func _process(delta: float) -> void:
	super._process(delta)
	_poll_ip_test()


func _exit_tree() -> void:
	# Scene teardown (e.g. Exit → change_scene) can land here mid-probe. The
	# RefCounted peer would close on free anyway, but drop it explicitly so we
	# never depend on GC timing for the socket.
	if _ip_test_peer != null:
		_ip_test_peer.disconnect_from_host()
		_ip_test_peer = null


func _on_ip_test_pressed() -> void:
	if _ip_test_peer != null:
		return  # probe already in flight
	_ip_test_token += 1
	var ip := _ip_input.text.strip_edges()
	var port := _port_input.text.strip_edges().to_int()
	if ip.is_empty() or port <= 0 or port > 65535:
		_show_ip_test_result(false)
		return
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(ip, port) != OK:
		_show_ip_test_result(false)
		return
	_ip_test_peer = peer
	_ip_test_deadline_msec = Time.get_ticks_msec() + IP_TEST_TIMEOUT_MSEC
	_ip_test_button.text = "…"


func _poll_ip_test() -> void:
	if _ip_test_peer == null:
		return
	_ip_test_peer.poll()
	var status := _ip_test_peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		_finish_ip_test(true)
	elif status == StreamPeerTCP.STATUS_ERROR \
			or Time.get_ticks_msec() >= _ip_test_deadline_msec:
		_finish_ip_test(false)


func _finish_ip_test(reachable: bool) -> void:
	if _ip_test_peer != null:
		_ip_test_peer.disconnect_from_host()
		_ip_test_peer = null
	_show_ip_test_result(reachable)


func _show_ip_test_result(reachable: bool) -> void:
	_ip_test_token += 1
	var token := _ip_test_token
	var color := COL_IP_TEST_OK if reachable else COL_IP_TEST_FAIL
	_ip_test_button.text = "✓" if reachable else "✗"
	for theme_key in ["font_color", "font_hover_color", "font_pressed_color"]:
		_ip_test_button.add_theme_color_override(theme_key, color)
	get_tree().create_timer(IP_TEST_RESULT_SECS).timeout.connect(func() -> void:
		# A newer press/result owns the button now; leave it alone.
		if token == _ip_test_token:
			_reset_ip_test_button()
	)


func _reset_ip_test_button() -> void:
	_ip_test_button.text = tr("UI_TEST_IP")
	for theme_key in ["font_color", "font_hover_color", "font_pressed_color"]:
		_ip_test_button.remove_theme_color_override(theme_key)


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


## The first robot this build ships, so a fresh install lands on something
## that can actually start rather than on a robot that was never generated.
static func _default_inside_profile() -> String:
	var offered := RobotProfileRegistryScript.ids()
	return str(offered[0]) if not offered.is_empty() else ""


static func _default_options() -> Dictionary:
	return {
		"target_scope": DEFAULT_TARGET_SCOPE,
		"protocol": DEFAULT_PROTOCOL,
		"ip": DEFAULT_IP,
		"port": DEFAULT_PORT,
		"xrobot_toolkit_device_sn": DEFAULT_XROBOT_TOOLKIT_DEVICE_SN,
		"inside_profile": _default_inside_profile(),
		"retargeting_backend": DEFAULT_RETARGETING_BACKEND,
		"retargeting_host": DEFAULT_RETARGETING_HOST,
		"retargeting_port": DEFAULT_RETARGETING_PORT,
		"retargeting_tls": false,
		"video_protocol": DEFAULT_VIDEO_PROTOCOL,
		"video_ip": DEFAULT_VIDEO_IP,
		"video_port": DEFAULT_OPERATOR_VIDEO_PORT,
		"video_sbs": false,
		"video_face_locked": DEFAULT_FACE_LOCKED,
		"show_video_panel": DEFAULT_SHOW_VIDEO_PANEL,
		"show_operation_trajectory": DEFAULT_SHOW_OPERATION_TRAJECTORY,
		"show_vr_pose": DEFAULT_SHOW_VR_POSE,
		"show_on_launch": DEFAULT_SHOW_ON_LAUNCH
	}


func _on_scope_button_pressed(scope: String) -> void:
	_target_scope = scope
	_refresh_scope_ui()


func _on_protocol_pressed(protocol: String) -> void:
	_selected_protocol = _normalized_protocol(protocol)
	_refresh_protocol_buttons()


func _on_pico_body_calibration_pressed() -> void:
	pico_body_calibration_requested.emit()


func _on_video_protocol_pressed(protocol: String) -> void:
	var previous_protocol := _selected_video_protocol
	_selected_video_protocol = _normalized_video_protocol(protocol)
	if _selected_video_protocol != previous_protocol:
		var current_port := _video_port_input.text.strip_edges().to_int()
		if _video_port_input.text.strip_edges().is_empty() \
				or current_port == _default_video_port(previous_protocol):
			_video_port_input.text = str(_default_video_port(_selected_video_protocol))
	_refresh_video_protocol_ui()


func _on_video_connect_pressed() -> void:
	var options := _validated_video_options()
	if options.is_empty():
		return
	set_video_status(tr("UI_VIDEO_CONNECT_REQUESTED"))
	video_connect_requested.emit(options)


func _validated_video_options() -> Dictionary:
	var options := get_options()
	if str(options.get("video_ip", "")).strip_edges().is_empty():
		set_video_status(tr("UI_VIDEO_IP_REQUIRED"))
		return {}
	var port := int(options.get("video_port", 0))
	if port <= 0 or port > 65535:
		set_video_status(tr("UI_VIDEO_INVALID_PORT"))
		return {}
	return options


func set_video_status(text: String) -> void:
	if _video_status_label != null:
		_video_status_label.text = text


## Switch the "show video panel" preference on from outside the panel.
##
## The video test button exists to prove an endpoint works, so a test that
## actually decodes frames turns the preference on rather than leaving the
## operator to discover a separate checkbox. Driving the real toggle (instead
## of forcing the value at confirm time) keeps the form honest: the operator
## sees it flip, it is saved with everything else on Confirm, and it can still
## be turned back off before confirming.
func set_show_video_panel_enabled(enabled: bool) -> void:
	if _show_video_panel_toggle != null:
		_show_video_panel_toggle.button_pressed = enabled


func _refresh_video_protocol_ui() -> void:
	for protocol in _video_protocol_buttons:
		_set_choice_selected(
			_video_protocol_buttons[protocol],
			protocol == _selected_video_protocol
		)
	var xrobot_toolkit := _selected_video_protocol == VIDEO_PROTOCOL_XROBOT_TOOLKIT
	if _video_port_label != null:
		_video_port_label.text = tr(
			"UI_VIDEO_COMMAND_PORT" if xrobot_toolkit else "UI_VIDEO_STREAM_PORT"
		)
	if _video_port_input != null:
		_video_port_input.placeholder_text = _video_port_label.text
	refresh_keyboard()


func _refresh_protocol_buttons() -> void:
	for protocol in _protocol_buttons:
		_set_choice_selected(_protocol_buttons[protocol], protocol == _selected_protocol)
	_refresh_xrobot_toolkit_controls()
	refresh_keyboard()


func _refresh_xrobot_toolkit_controls() -> void:
	var show_xrobot_controls := (
		_target_scope == DEFAULT_TARGET_SCOPE
		and _selected_protocol == PROTOCOL_XROBOT_TOOLKIT_V1
	)
	if _xrobot_toolkit_device_sn_input != null:
		_xrobot_toolkit_device_sn_input.visible = show_xrobot_controls
	if _pico_body_calibration_button != null:
		_pico_body_calibration_button.visible = show_xrobot_controls
		var slot := _pico_body_calibration_button.get_parent() as Control
		if slot != null:
			slot.visible = show_xrobot_controls


static func _normalized_protocol(protocol: String) -> String:
	if protocol == PROTOCOL_XROBOT_TOOLKIT_V1:
		return PROTOCOL_XROBOT_TOOLKIT_V1
	return PROTOCOL_OPERATOR


static func _normalized_video_protocol(protocol: String) -> String:
	if protocol == VIDEO_PROTOCOL_XROBOT_TOOLKIT:
		return VIDEO_PROTOCOL_XROBOT_TOOLKIT
	return VIDEO_PROTOCOL_OPERATOR


static func _default_video_port(protocol: String) -> int:
	if protocol == VIDEO_PROTOCOL_XROBOT_TOOLKIT:
		return DEFAULT_XROBOT_TOOLKIT_COMMAND_PORT
	return DEFAULT_OPERATOR_VIDEO_PORT


## The pressed state alone is easy to miss on a panel seen from a metre away,
## so the active choice also carries the accent colour.
func _set_choice_selected(button: Button, selected: bool) -> void:
	button.button_pressed = selected
	var color := COL_ACCENT if selected else COL_SECTION
	# XR pointer interaction leaves the hovered toggle in `hover_pressed`, not
	# plain `pressed`. Cover every visible state so the selected colour changes
	# immediately and stays correct while the pointer is still over the button.
	for color_name in [
		"font_color",
		"font_pressed_color",
		"font_hover_color",
		"font_hover_pressed_color",
		"font_focus_color",
	]:
		button.add_theme_color_override(color_name, color)


func _on_inside_profile_pressed(profile_id: String) -> void:
	_selected_profile = profile_id
	_refresh_backend_options()


func _on_retargeting_backend_pressed(backend: String) -> void:
	if not RobotProfileRegistryScript.supports_backend(_selected_profile, backend):
		return
	_selected_backend = backend
	# Repaint the backend buttons so the accent colour follows the click;
	# without this the selection changed but the row still looked unchanged.
	for backend_id in _backend_buttons:
		var button: Button = _backend_buttons[backend_id]
		_set_choice_selected(button, backend_id == _selected_backend and not button.disabled)
	_refresh_remote_fields()


func _refresh_scope_ui() -> void:
	if _inside_scope_button == null or _outside_scope_button == null:
		return
	# No Inside profile can be started without its assets, so a build without
	# them offers Outside only rather than a dead selection.
	var inside_available := not _profile_buttons.is_empty()
	if not inside_available:
		_target_scope = "outside"
	var inside := _target_scope == "inside"
	_inside_scope_button.disabled = not inside_available
	_set_choice_selected(_inside_scope_button, inside)
	_set_choice_selected(_outside_scope_button, not inside)
	if _inside_box != null:
		_inside_box.visible = inside
	if _outside_box != null:
		_outside_box.visible = not inside
	_refresh_xrobot_toolkit_controls()
	if _inside_missing_label != null:
		var unavailable := RobotProfileRegistryScript.unavailable()
		_inside_missing_label.visible = inside and not unavailable.is_empty()
		if _inside_missing_label.visible:
			var names: Array = unavailable.keys()
			names.sort()
			_inside_missing_label.text = tr("UI_INSIDE_ROBOT_ASSETS_MISSING") % ", ".join(names)
	_refresh_remote_fields()


func _refresh_backend_options(preferred := "") -> void:
	if _profile_buttons.is_empty() or _backend_buttons.is_empty():
		return
	if not _profile_buttons.has(_selected_profile):
		_selected_profile = _default_inside_profile()
	for profile_id in _profile_buttons:
		_set_choice_selected(_profile_buttons[profile_id], profile_id == _selected_profile)

	var wanted := preferred if not preferred.is_empty() else _selected_backend
	# A backend the chosen robot cannot run must not stay selected from the
	# previous robot; fall back to whichever one it does support.
	if not RobotProfileRegistryScript.supports_backend(_selected_profile, wanted):
		wanted = (
			"native"
			if RobotProfileRegistryScript.supports_backend(_selected_profile, "native")
			else "remote"
		)
	_selected_backend = wanted
	for backend in _backend_buttons:
		var button: Button = _backend_buttons[backend]
		button.disabled = not RobotProfileRegistryScript.supports_backend(
			_selected_profile, backend
		)
		_set_choice_selected(button, backend == _selected_backend and not button.disabled)
	_refresh_remote_fields()


func _refresh_remote_fields() -> void:
	if _backend_buttons.is_empty():
		return
	var remote := _selected_backend == "remote"
	for field in [_retargeting_host_input, _retargeting_port_input, _retargeting_tls_toggle]:
		if field != null:
			field.visible = remote
	if _retargeting_status_label != null:
		var profile := RobotProfileRegistryScript.get_profile(_selected_profile)
		var simulation := _simulation_display(str(profile.get("simulation_backend", "kinematic")))
		_retargeting_status_label.text = tr("UI_INSIDE_RUNTIME_SUMMARY") % [
			tr("UI_RETARGETING_REMOTE") if remote else tr("UI_RETARGETING_NATIVE"),
			simulation,
		]
	refresh_keyboard()


func _simulation_display(backend: String) -> String:
	if backend.begins_with("mujoco"):
		return "MuJoCo"
	return backend.capitalize()


func _selected_metadata(option: OptionButton, fallback: String) -> String:
	if option == null or option.item_count <= 0 or option.selected < 0:
		return fallback
	return str(option.get_item_metadata(option.selected))


func _select_metadata(option: OptionButton, value: String) -> void:
	if option == null:
		return
	for index in range(option.item_count):
		if str(option.get_item_metadata(index)) == value:
			option.select(index)
			return
	if option.item_count > 0:
		option.select(0)
