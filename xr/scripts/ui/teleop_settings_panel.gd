extends "res://scripts/ui/two_column_settings_panel.gd"
class_name TeleopSettingsPanel

signal settings_applied(options: Dictionary)
signal close_requested
signal pico_body_calibration_requested
signal video_connect_requested(options: Dictionary)
signal blueprint_visibility_override_requested(component_id: String, visible: Variant)

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
const BLUEPRINT_OVERRIDE_LABEL_KEYS := {
	"follow": "UI_BLUEPRINT_FOLLOW",
	"show": "UI_BLUEPRINT_SHOW",
	"hide": "UI_BLUEPRINT_HIDE",
}

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

## Time between two trigger presses inside the IP field that counts as a
## double-click and enters edit mode. Longer than a mouse double-click because
## an XR trigger is coarser than a mouse button and users pump it slower.
const IP_DOUBLE_CLICK_MSEC := 450

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
## Inline list of discovered hosts, expanded under the IP row on single-click.
## A VBoxContainer of Buttons rather than a PopupMenu so it renders reliably
## inside CompositionViewportUI's SubViewport (see `_add_choice_button`).
var _ip_dropdown: VBoxContainer
## Hint under the IP field. Reads either "Tap to pick from N" or
## "No discovered hosts — double-click to edit", depending on discovery state.
var _ip_hint_label: Label
## Single-shot debounce timer that separates single-click (open dropdown) from
## double-click (enter edit mode). A second trigger arriving before this
## expires cancels it and starts editing instead.
var _ip_click_timer: Timer
## Metadata list mirroring `_ip_dropdown` items 1:1 so the item-selected
## handler can resolve an item id back to a `_discovered` endpoint id.
var _ip_dropdown_endpoint_ids: PackedStringArray = PackedStringArray()
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
var _blueprint_group: VBoxContainer
var _blueprint_rows: VBoxContainer
var _blueprint_override_buttons: Dictionary = {}
var _blueprint_override_modes: Dictionary = {}
var _status_label: Label
var _discovery_spinner: DiscoverySpinner
var _discovery_active := false
var _discovered: Dictionary = {}
var _applying_discovery_selection := false


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
	# Kept alive (populated by `set_discovery_state`, still the source of truth
	# for the currently selected endpoint) but no longer rendered: the IP row
	# below now owns the pick-a-host interaction. Made a child of the panel so
	# `set_discovery_state` still runs; hidden so it takes no visual space.
	_discovery_option.visible = false
	connection.add_child(_discovery_option)

	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 10)
	ip_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection.add_child(ip_row)

	_ip_input = LineEdit.new()
	_ip_input.placeholder_text = tr("UI_ROBOT_IP")
	_ip_input.text = DEFAULT_IP
	_ip_input.custom_minimum_size.y = 55
	_ip_input.add_theme_font_size_override("font_size", 21)
	# Read-only by default. A single trigger pops the discovery list; a
	# double-trigger flips this back on and summons the virtual keyboard. The
	# soft keyboard checks `editable` on its focused field, so leaving this
	# false is what keeps the keyboard down on plain taps.
	_ip_input.editable = false
	_ip_input.text_changed.connect(_on_manual_endpoint_changed)
	_ip_input.gui_input.connect(_on_ip_input_gui_input)
	_ip_input.focus_exited.connect(_on_ip_input_focus_exited)
	add_interactive(ip_row, _ip_input)

	_ip_test_button = Button.new()
	_ip_test_button.text = tr("UI_TEST_IP")
	_ip_test_button.focus_mode = Control.FOCUS_NONE
	_ip_test_button.custom_minimum_size = Vector2(96, 55)
	_ip_test_button.add_theme_font_size_override("font_size", 21)
	_ip_test_button.pressed.connect(_on_ip_test_pressed)
	ip_row.add_child(_ip_test_button)

	# Hint under the IP row. Empty-discovery state prompts the operator to
	# double-click; a non-empty state advertises how many hosts are on offer.
	_ip_hint_label = Label.new()
	_ip_hint_label.add_theme_font_size_override("font_size", 17)
	_ip_hint_label.add_theme_color_override("font_color", COL_STATUS)
	_ip_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	connection.add_child(_ip_hint_label)

	# Debounce timer for double-click detection. `create_timer` cannot be
	# cancelled, and the XR trigger cannot deliver an `InputEventMouseButton`
	# with `double_click = true` (see `composition_viewport_ui.gd`), so we
	# reconstruct the gesture from press timing here.
	_ip_click_timer = Timer.new()
	_ip_click_timer.one_shot = true
	_ip_click_timer.wait_time = IP_DOUBLE_CLICK_MSEC / 1000.0
	_ip_click_timer.timeout.connect(_on_ip_click_timer_timeout)
	add_child(_ip_click_timer)

	# Inline dropdown, expanded in place under the IP row. A PopupMenu (i.e.
	# what OptionButton uses internally) is a native Window and does not
	# render inside a CompositionViewportUI SubViewport — see
	# `_add_choice_button` a few pages down for the same warning. Using a
	# plain VBoxContainer of Buttons sidesteps the whole subwindow-embed
	# question and pushes the rest of the form down while visible.
	_ip_dropdown = VBoxContainer.new()
	_ip_dropdown.add_theme_constant_override("separation", 4)
	_ip_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ip_dropdown.visible = false
	connection.add_child(_ip_dropdown)

	_refresh_ip_hint()

	_port_input = LineEdit.new()
	_port_input.placeholder_text = tr("UI_PORT")
	_port_input.text = str(DEFAULT_PORT)
	_port_input.custom_minimum_size.y = 55
	_port_input.add_theme_font_size_override("font_size", 21)
	_port_input.text_changed.connect(_on_manual_endpoint_changed)
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

	# --- Robot-authored UI group -------------------------------------------
	_blueprint_group = register_group(
		"blueprint", "UI_GROUP_BLUEPRINT", "settings"
	)
	var blueprint_help := Label.new()
	blueprint_help.text = tr("UI_BLUEPRINT_HELP")
	blueprint_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blueprint_help.add_theme_font_size_override("font_size", 18)
	blueprint_help.add_theme_color_override("font_color", COL_STATUS)
	_blueprint_group.add_child(blueprint_help)
	_blueprint_rows = VBoxContainer.new()
	_blueprint_rows.add_theme_constant_override("separation", 16)
	_blueprint_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blueprint_group.add_child(_blueprint_rows)
	_set_blueprint_group_available(false)

	# --- Startup group -----------------------------------------------------
	var startup := register_group("startup", "UI_GROUP_STARTUP", "power")
	_show_on_launch_toggle = add_toggle(startup, tr("UI_SHOW_SETTINGS_ON_LAUNCH"), DEFAULT_SHOW_ON_LAUNCH, 22)

	# The robot group is shown by default (first registered).
	call_deferred("_refresh_scope_ui")
	call_deferred("_refresh_video_protocol_ui")


func set_blueprint_visibility_options(options: Array) -> void:
	if _blueprint_rows == null:
		return
	for child in _blueprint_rows.get_children():
		_blueprint_rows.remove_child(child)
		child.queue_free()
	_blueprint_override_buttons.clear()
	_blueprint_override_modes.clear()
	for option_v in options:
		if not option_v is Dictionary:
			continue
		var option := option_v as Dictionary
		var component_id := str(option.get("id", "")).strip_edges()
		if component_id.is_empty():
			continue
		var section := VBoxContainer.new()
		section.add_theme_constant_override("separation", 8)
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_blueprint_rows.add_child(section)
		var label := Label.new()
		label.text = str(option.get("label", component_id))
		label.clip_text = true
		label.tooltip_text = component_id
		label.add_theme_font_size_override("font_size", 19)
		label.add_theme_color_override("font_color", COL_SECTION)
		section.add_child(label)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_child(row)
		var buttons := {}
		for mode in BLUEPRINT_OVERRIDE_LABEL_KEYS:
			buttons[mode] = _add_choice_button(
				row,
				tr(str(BLUEPRINT_OVERRIDE_LABEL_KEYS[mode])),
				_on_blueprint_override_pressed.bind(component_id, mode),
			)
		_blueprint_override_buttons[component_id] = buttons
		var override_v: Variant = option.get("override", null)
		var selected_mode := "follow"
		if override_v != null:
			selected_mode = "show" if bool(override_v) else "hide"
		_blueprint_override_modes[component_id] = selected_mode
		_refresh_blueprint_override_buttons(component_id)
	_set_blueprint_group_available(not _blueprint_override_buttons.is_empty())


func _on_blueprint_override_pressed(component_id: String, mode: String) -> void:
	if not _blueprint_override_buttons.has(component_id):
		return
	_blueprint_override_modes[component_id] = mode
	_refresh_blueprint_override_buttons(component_id)
	var visible: Variant = null
	if mode == "show":
		visible = true
	elif mode == "hide":
		visible = false
	blueprint_visibility_override_requested.emit(component_id, visible)


func _refresh_blueprint_override_buttons(component_id: String) -> void:
	var buttons_v: Variant = _blueprint_override_buttons.get(component_id, null)
	if not buttons_v is Dictionary:
		return
	var buttons := buttons_v as Dictionary
	var selected_mode := str(_blueprint_override_modes.get(component_id, "follow"))
	for mode in buttons:
		_set_choice_selected(
			buttons[mode] as Button,
			str(mode) == selected_mode,
		)


func _set_blueprint_group_available(available: bool) -> void:
	var button_v: Variant = _group_buttons.get("blueprint", null)
	if button_v is Button:
		(button_v as Button).visible = available
	if not available and _active_group == "blueprint":
		select_group("display")


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


func set_discovery_state(
	known_robots: Dictionary,
	prefer_ip: String = "",
	prefer_protocol: String = "",
	prefer_port: int = 0
) -> void:
	_discovered = known_robots.duplicate(true)

	var previously_selected_id := _selected_discovery_id()

	_discovery_option.clear()
	_add_option_item(_discovery_option, tr(MANUAL_LABEL_KEY), "", "signal")

	var endpoint_ids: Array = _discovered.keys()
	endpoint_ids.sort()
	var idx_to_select := 0
	for i in range(endpoint_ids.size()):
		var endpoint_id: String = endpoint_ids[i]
		var info: Dictionary = _discovered[endpoint_id]
		var rname := String(info.get("name", endpoint_id))
		var disp := _format_robot_label(rname, info)
		var idx := _add_option_item(
			_discovery_option,
			disp,
			endpoint_id,
			_icon_name_for_robot_type(String(info.get("device_type", "")))
		)
		if endpoint_id == previously_selected_id:
			idx_to_select = idx
		elif idx_to_select == 0 and not prefer_ip.is_empty():
			var endpoint_protocol := _normalized_protocol(String(info.get("protocol", PROTOCOL_OPERATOR)))
			var protocol_matches := (
				prefer_protocol.is_empty()
				or endpoint_protocol == _normalized_protocol(prefer_protocol)
			)
			var port_matches := prefer_port <= 0 or int(info.get("pose_port", 0)) == prefer_port
			if String(info.get("ip", "")) == prefer_ip and protocol_matches and port_matches:
				idx_to_select = idx

	_discovery_option.select(idx_to_select)
	_on_discovery_selected(idx_to_select)
	# The inline list was built from the previous `_discovered` snapshot;
	# rebuild it lazily on the next open rather than mutating it live under
	# the operator's finger.
	_hide_ip_dropdown()
	_refresh_ip_hint()


func add_discovered(endpoint_id: String, info: Dictionary) -> void:
	_discovered[endpoint_id] = info
	set_discovery_state(_discovered)


func remove_discovered(endpoint_id: String) -> void:
	if _discovered.erase(endpoint_id):
		set_discovery_state(_discovered)


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

	var endpoint_id: String = String(_discovery_option.get_item_metadata(idx))
	if not _discovered.has(endpoint_id):
		return
	var info: Dictionary = _discovered[endpoint_id]
	var rname := String(info.get("name", endpoint_id))
	_applying_discovery_selection = true
	_ip_input.text = String(info.get("ip", DEFAULT_IP))
	_port_input.text = str(int(info.get("pose_port", DEFAULT_PORT)))
	# A host found on the XRoboToolkit beacon speaks only that protocol, and the
	# beacon says so. Selecting it while the radio still reads "operator" would
	# hand the user a row that cannot connect and no hint as to why.
	var announced_protocol := String(info.get("protocol", ""))
	if not announced_protocol.is_empty():
		_selected_protocol = _normalized_protocol(announced_protocol)
		_refresh_protocol_buttons()
	_applying_discovery_selection = false
	_apply_mode_lock()
	set_status(tr("UI_WILL_CONNECT_TO") % _format_robot_label(rname, info))


func _apply_mode_lock() -> void:
	if _discovery_option == null:
		return
	# Discovery is a shortcut, not an ownership lock. The IP field is
	# read-only by default so a single trigger opens the discovered-hosts
	# popup instead of the virtual keyboard; a second trigger within
	# IP_DOUBLE_CLICK_MSEC flips it editable and the keyboard appears.
	# `_port_input` stays freely editable — it has no discovery UX, and users
	# occasionally need to override the default port even when they picked a
	# discovered host.
	_port_input.editable = true
	refresh_keyboard()


func _on_manual_endpoint_changed(_value: String) -> void:
	if _applying_discovery_selection or _discovery_option == null:
		return
	if _discovery_option.selected <= 0:
		return
	_discovery_option.select(0)
	_apply_mode_lock()
	set_status(tr("UI_MANUAL_ENTRY_STATUS"))


# --- IP field click routing --------------------------------------------------
#
# Single trigger on the IP field opens the discovered-hosts popup; two triggers
# within IP_DOUBLE_CLICK_MSEC flip the field editable and summon the virtual
# keyboard. Both gestures are reconstructed here from bare mouse-button events
# because the XR trigger cannot synthesize `InputEventMouseButton.double_click`
# (see `composition_viewport_ui.gd::set_pointer_pressed`).

func _on_ip_input_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if not mouse.pressed:
		return
	if mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	if _ip_input.editable:
		# Already in edit mode. Let LineEdit's own handler run so caret
		# positioning still works; do not re-arm the debounce timer.
		return
	if _ip_click_timer != null and _ip_click_timer.time_left > 0.0:
		# Second click inside the double-click window → edit mode.
		_ip_click_timer.stop()
		_enter_ip_edit_mode()
		# Consume so the LineEdit's own click handler does not also focus
		# and immediately blur when the popup would have opened.
		_ip_input.accept_event()
		return
	# First click. Defer the popup so a rapid second click can cancel it.
	if _ip_click_timer != null:
		_ip_click_timer.start()
	_ip_input.accept_event()


func _on_ip_click_timer_timeout() -> void:
	if _ip_input == null or _ip_input.editable:
		return
	_show_ip_dropdown()


func _show_ip_dropdown() -> void:
	if _ip_dropdown == null or _ip_input == null:
		return
	# Toggle if already open: a second single-click on the IP field is a
	# natural "put it away" gesture and cheaper than hunting for the
	# "manual entry" row.
	if _ip_dropdown.visible:
		_hide_ip_dropdown()
		return
	# Rebuild every open — the discovery set can change between opens and the
	# button list is cheap.
	for child in _ip_dropdown.get_children():
		_ip_dropdown.remove_child(child)
		child.queue_free()
	_ip_dropdown_endpoint_ids.clear()
	var endpoint_ids: Array = _discovered.keys()
	endpoint_ids.sort()
	if endpoint_ids.is_empty():
		# Nothing to pick from — surface the double-click affordance through
		# the hint label rather than opening an empty list. An empty
		# VBoxContainer would still consume separator space.
		_refresh_ip_hint(true)
		return
	for endpoint_id_v in endpoint_ids:
		var endpoint_id := String(endpoint_id_v)
		var info: Dictionary = _discovered.get(endpoint_id, {})
		var rname := String(info.get("name", endpoint_id))
		var row := Button.new()
		row.text = _format_robot_label(rname, info)
		row.focus_mode = Control.FOCUS_NONE
		row.custom_minimum_size.y = 48
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_font_size_override("font_size", 20)
		# Copy the endpoint_id into the callable so item indices don't
		# matter across rebuilds — the dropdown owns its own listing but
		# defers to the endpoint_id for state.
		row.pressed.connect(_on_ip_dropdown_pick.bind(endpoint_id))
		_ip_dropdown.add_child(row)
		_ip_dropdown_endpoint_ids.append(endpoint_id)
	_ip_dropdown.visible = true


func _hide_ip_dropdown() -> void:
	if _ip_dropdown == null:
		return
	_ip_dropdown.visible = false


func _on_ip_dropdown_pick(endpoint_id: String) -> void:
	_hide_ip_dropdown()
	# Reuse the existing selection path by pointing `_discovery_option` at
	# the same endpoint. Everything downstream — protocol lock, status
	# text, port sync — is already handled there.
	for idx in range(_discovery_option.item_count):
		if String(_discovery_option.get_item_metadata(idx)) == endpoint_id:
			_discovery_option.select(idx)
			_on_discovery_selected(idx)
			break
	_refresh_ip_hint()


func _enter_ip_edit_mode() -> void:
	if _ip_input == null:
		return
	_hide_ip_dropdown()
	_ip_input.editable = true
	_ip_input.grab_focus()
	# Select all so a fresh double-click behaves like "start over".
	_ip_input.select_all()
	refresh_keyboard()
	_refresh_ip_hint()


func _on_ip_input_focus_exited() -> void:
	if _ip_input == null:
		return
	# Snap back to read-only when the user commits/blurs. Deferred so the
	# focus transition (and any concurrent keyboard-hide) settle first —
	# otherwise flipping `editable` mid-signal can leave the keyboard bar
	# stuck visible against an inert field.
	call_deferred("_leave_ip_edit_mode")


func _leave_ip_edit_mode() -> void:
	if _ip_input == null:
		return
	_ip_input.editable = false
	refresh_keyboard()
	_refresh_ip_hint()


func _refresh_ip_hint(force_empty_prompt: bool = false) -> void:
	if _ip_hint_label == null:
		return
	if _ip_input != null and _ip_input.editable:
		_ip_hint_label.text = tr("UI_IP_HINT_EDITING")
		return
	var count := _discovered.size()
	if count > 0 and not force_empty_prompt:
		_ip_hint_label.text = tr("UI_IP_HINT_TAP_TO_PICK") % count
	else:
		_ip_hint_label.text = tr("UI_IP_HINT_DOUBLE_CLICK_TO_EDIT")


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


func _selected_discovery_id() -> String:
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
		"xrobot_toolkit":
			return tr("UI_DEVICE_TYPE_XROBOT_TOOLKIT")
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
	var next_protocol := _normalized_protocol(protocol)
	if _discovery_option != null and _discovery_option.selected > 0:
		var endpoint_id := _selected_discovery_id()
		var selected_info: Dictionary = _discovered.get(endpoint_id, {})
		var announced_protocol := _normalized_protocol(
			str(selected_info.get("protocol", PROTOCOL_OPERATOR))
		)
		if announced_protocol != next_protocol:
			_discovery_option.select(0)
			set_status(tr("UI_MANUAL_ENTRY_STATUS"))
	_selected_protocol = next_protocol
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
	var robot_authored_blueprint := (
		_target_scope == DEFAULT_TARGET_SCOPE
		and _selected_protocol == PROTOCOL_OPERATOR
	)
	for legacy_toggle in [
		_video_face_toggle,
		_show_video_panel_toggle,
		_show_operation_trajectory_toggle,
	]:
		if legacy_toggle == null:
			continue
		var slot := legacy_toggle.get_parent() as Control
		if slot != null:
			slot.visible = not robot_authored_blueprint
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
