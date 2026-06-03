extends Node3D
## Two-phase VR panel:
##   STATE_SELECT  – pick a discovered hardware (or enter IP manually) and
##                   press "Enter Control" to start handshake.
##   STATE_CONTROL – descriptor handshake done; driver is active. Shows
##                   device summary + Disconnect / Back-to-Select.
##
## Phase transitions are driven by `set_connected(bool)` and
## `show_device_info(descriptor)` from main.gd.

signal connect_requested(ip: String, port: int)
signal disconnect_requested()

enum State { SELECT, CONTROL }

## Title (shared)
@onready var _title_label: Label = $SubViewport/Panel/VBoxContainer/TitleLabel

## --- Select page ---
@onready var _select_page: VBoxContainer = $SubViewport/Panel/VBoxContainer/SelectPage
@onready var _robot_list_label: Label = $SubViewport/Panel/VBoxContainer/SelectPage/RobotListLabel
@onready var _robot_list: ItemList = $SubViewport/Panel/VBoxContainer/SelectPage/RobotList
@onready var _manual_label: Label = $SubViewport/Panel/VBoxContainer/SelectPage/ManualLabel
@onready var _ip_input: LineEdit = $SubViewport/Panel/VBoxContainer/SelectPage/IPContainer/IPInput
@onready var _port_input: LineEdit = $SubViewport/Panel/VBoxContainer/SelectPage/IPContainer/PortInput
@onready var _enter_button: Button = $SubViewport/Panel/VBoxContainer/SelectPage/EnterButton

## --- Control page ---
@onready var _control_page: VBoxContainer = $SubViewport/Panel/VBoxContainer/ControlPage
@onready var _device_name_label: Label = $SubViewport/Panel/VBoxContainer/ControlPage/DeviceNameLabel
@onready var _device_type_label: Label = $SubViewport/Panel/VBoxContainer/ControlPage/DeviceTypeLabel
@onready var _device_address_label: Label = $SubViewport/Panel/VBoxContainer/ControlPage/DeviceAddressLabel
@onready var _control_hint_label: Label = $SubViewport/Panel/VBoxContainer/ControlPage/ControlHintLabel
@onready var _back_button: Button = $SubViewport/Panel/VBoxContainer/ControlPage/ButtonContainer/BackButton
@onready var _disconnect_button: Button = $SubViewport/Panel/VBoxContainer/ControlPage/ButtonContainer/DisconnectButton

## Shared status
@onready var _status_label: Label = $SubViewport/Panel/VBoxContainer/StatusLabel

## Known robots: name -> { ip, pose_port, video_port, device_type, device_name }
var _robots: Dictionary = {}
## Currently connected state
var _connected: bool = false
## Currently shown UI state
var _state: int = State.SELECT
## Address of the device we asked to connect to (used for the control page header)
var _pending_ip: String = ""
var _pending_port: int = 0
## Default pose port
const DEFAULT_PORT: int = 63901


func _ready() -> void:
	_apply_static_text()

	# Defaults
	if _ip_input:
		_ip_input.text = "127.0.0.1"
		_ip_input.placeholder_text = tr("UI_IP_ADDRESS")
	if _port_input:
		_port_input.text = str(DEFAULT_PORT)
		_port_input.placeholder_text = tr("UI_PORT")

	if _enter_button:
		_enter_button.pressed.connect(_on_enter_pressed)
	if _disconnect_button:
		_disconnect_button.pressed.connect(_on_disconnect_pressed)
	if _back_button:
		# "Back" is implemented as a disconnect — the driver is the only
		# reason we are in CONTROL state, so leaving it means dropping the
		# session and returning to the selector.
		_back_button.pressed.connect(_on_disconnect_pressed)

	if _robot_list:
		_robot_list.item_selected.connect(_on_robot_selected)
		_robot_list.item_activated.connect(_on_robot_activated)

	_set_state(State.SELECT)
	_update_ui()


# --- Select-page actions ---------------------------------------------------

func _on_enter_pressed() -> void:
	var ip := _ip_input.text.strip_edges()
	var port := _port_input.text.strip_edges().to_int()

	if ip.is_empty():
		_set_status(tr("UI_NO_HARDWARE_ADDRESS"))
		return
	if port <= 0 or port > 65535:
		port = DEFAULT_PORT

	_pending_ip = ip
	_pending_port = port
	_set_status(tr("UI_CONNECTING_TO") % [ip, port])
	connect_requested.emit(ip, port)


func _on_robot_selected(index: int) -> void:
	if index < 0 or not _robot_list:
		return

	var robot_name: String = _robot_list.get_item_metadata(index)
	if _robots.has(robot_name):
		var info: Dictionary = _robots[robot_name]
		if _ip_input:
			_ip_input.text = info["ip"]
		if _port_input:
			_port_input.text = str(info["pose_port"])


func _on_robot_activated(index: int) -> void:
	# Double-click / Enter on a list row is a fast-path: select + connect.
	_on_robot_selected(index)
	_on_enter_pressed()


# --- Control-page actions --------------------------------------------------

func _on_disconnect_pressed() -> void:
	disconnect_requested.emit()


# --- Discovery feed --------------------------------------------------------

## Add a discovered robot to the list.
func add_robot(robot_name: String, ip: String, pose_port: int, video_port: int, device_type: String = "", device_name: String = "") -> void:
	_robots[robot_name] = {
		"ip": ip,
		"pose_port": pose_port,
		"video_port": video_port,
		"device_type": device_type,
		"device_name": device_name,
	}
	_refresh_robot_list()


## Remove a robot from the list.
func remove_robot(robot_name: String) -> void:
	_robots.erase(robot_name)
	_refresh_robot_list()


func _refresh_robot_list() -> void:
	if not _robot_list:
		return

	# Remember which robot was highlighted so a refresh doesn't surprise the user.
	var prev_selected_name: String = ""
	var sel := _robot_list.get_selected_items()
	if sel.size() > 0:
		prev_selected_name = String(_robot_list.get_item_metadata(sel[0]))

	_robot_list.clear()
	for robot_name in _robots:
		var info: Dictionary = _robots[robot_name]
		var device_type: String = info.get("device_type", "")
		var device_name: String = info.get("device_name", "")

		# Display: "[device_name] (device_type) — robot_name @ ip:port"
		var head: String = device_name if device_name != "" else robot_name
		var type_suffix := " (%s)" % _robot_type_display(device_type) if device_type != "" else ""
		var display_text := "%s%s — %s @ %s:%d" % [
			head, type_suffix, robot_name, info["ip"], info["pose_port"],
		]
		var idx := _robot_list.add_item(display_text)
		_robot_list.set_item_metadata(idx, robot_name)
		if robot_name == prev_selected_name:
			_robot_list.select(idx)


# --- State management ------------------------------------------------------

## Update connected state and UI. Called by main.gd from TcpHandler signals.
## Note: socket-level connect happens BEFORE the v2 descriptor handshake,
## so this only flips the status text. Page switching waits until
## `show_device_info` is called from `_on_device_connected`.
func set_connected(connected: bool) -> void:
	_connected = connected
	if connected:
		_set_status(tr("UI_CONNECTED_HANDSHAKE"))
	else:
		_pending_ip = ""
		_pending_port = 0
		_set_status(tr("UI_DISCONNECTED"))
		_set_state(State.SELECT)
	_update_ui()


## Called by main.gd once the DeviceDescriptor handshake completes.
## Switches us into the driver-control phase.
func show_device_info(descriptor: Dictionary) -> void:
	var device_info: Dictionary = descriptor.get("device", {})
	var dname: String = device_info.get("name", tr("UI_UNKNOWN_DEVICE"))
	var dtype: String = device_info.get("type", tr("UI_UNKNOWN"))
	var display_type := _robot_type_display(dtype)

	if _device_name_label:
		_device_name_label.text = tr("UI_DEVICE_LABEL") % dname
	if _device_type_label:
		_device_type_label.text = tr("UI_TYPE_LABEL") % display_type
	if _device_address_label:
		var addr := "%s:%d" % [_pending_ip, _pending_port] if _pending_ip != "" else "—"
		_device_address_label.text = tr("UI_ADDRESS_LABEL") % addr

	_set_status(tr("UI_DRIVER_ACTIVE") % [dname, display_type])
	_set_state(State.CONTROL)


func _set_state(new_state: int) -> void:
	_state = new_state
	var in_select := new_state == State.SELECT
	if _select_page:
		_select_page.visible = in_select
	if _control_page:
		_control_page.visible = not in_select
	if _title_label:
		_title_label.text = tr("UI_CONNECTION_TITLE_SELECT") if in_select else tr("UI_CONNECTION_TITLE_CONTROL")


func _update_ui() -> void:
	# Select page: only allow "Enter Control" while we are not already connected.
	if _enter_button:
		_enter_button.disabled = _connected
	if _ip_input:
		_ip_input.editable = not _connected
	if _port_input:
		_port_input.editable = not _connected


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = tr("UI_STATUS_PREFIX") % text


func _apply_static_text() -> void:
	if _robot_list_label:
		_robot_list_label.text = tr("UI_DISCOVERED_HARDWARE_HELP")
	if _manual_label:
		_manual_label.text = tr("UI_MANUAL_CONNECTION")
	if _enter_button:
		_enter_button.text = tr("UI_ENTER_CONTROL")
	if _device_name_label:
		_device_name_label.text = tr("UI_DEVICE_LABEL") % "--"
	if _device_type_label:
		_device_type_label.text = tr("UI_TYPE_LABEL") % "--"
	if _device_address_label:
		_device_address_label.text = tr("UI_ADDRESS_LABEL") % "--"
	if _control_hint_label:
		_control_hint_label.text = tr("UI_DRIVER_CONTROL_HINT")
	if _back_button:
		_back_button.text = tr("UI_BACK_TO_HARDWARE_SELECT")
	if _disconnect_button:
		_disconnect_button.text = tr("UI_DISCONNECT")
	if _status_label:
		_status_label.text = tr("UI_STATUS_PREFIX") % tr("UI_NOT_CONNECTED")


func _robot_type_display(robot_type: String) -> String:
	match robot_type:
		"robot_arm":
			return tr("UI_DEVICE_TYPE_ROBOT_ARM")
		"rc_car":
			return tr("UI_DEVICE_TYPE_RC_CAR")
		_:
			return robot_type
