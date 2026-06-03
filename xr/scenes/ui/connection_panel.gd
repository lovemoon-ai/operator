extends Node3D
## Two-phase VR panel:
##   STATE_SELECT  - pick a discovered hardware (or enter IP manually) and
##                   press "Enter Control" to start handshake.
##   STATE_CONTROL - descriptor handshake done; driver is active. Shows
##                   device summary + Disconnect / Back-to-Select.
##
## Phase transitions are driven by `set_connected(bool)` and
## `show_device_info(descriptor)` from main.gd.

signal connect_requested(ip: String, port: int)
signal disconnect_requested()

enum State { SELECT, CONTROL }

const DEFAULT_PORT: int = 63901
const ICON_PATH := "res://assets/icons/%s.svg"

const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_GLASS := Color(0.025, 0.032, 0.040, 0.72)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_MUTED := Color(0.65, 0.70, 0.75)
const COL_ACCENT := Color(1.0, 0.647, 0.169, 0.98)
const COL_ACCENT_SOFT := Color(1.0, 0.647, 0.169, 0.18)
const COL_ONLINE := Color(0.55, 0.80, 0.66)
const COL_DANGER := Color(1.0, 0.30, 0.20)

const CARD_MIN_SIZE := Vector2(260, 96)
const CARD_HOVER_SCALE := Vector2(1.035, 1.035)
const CARD_NORMAL_SCALE := Vector2.ONE
const CARD_HOVER_Y_OFFSET := -5.0
const CARD_TWEEN_DURATION := 0.14
const HANDSHAKE_CARD_SIZE := Vector2(440, 190)


class HandshakeScan:
	extends Control

	var active := false
	var accent_color := Color(1.0, 0.647, 0.169, 0.98)
	var _phase := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(360, 24)
		set_process(false)

	func set_active(value: bool) -> void:
		active = value
		set_process(active)
		queue_redraw()

	func _process(delta: float) -> void:
		_phase = wrapf(_phase + delta * 1.8, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		if not active:
			return
		var y := size.y * 0.5
		var base := Color(accent_color.r, accent_color.g, accent_color.b, 0.18)
		draw_line(Vector2(0.0, y), Vector2(size.x, y), base, 3.0, true)
		var head_x := lerpf(0.0, size.x, _phase)
		var tail_x := maxf(0.0, head_x - size.x * 0.28)
		draw_line(Vector2(tail_x, y), Vector2(head_x, y), accent_color, 4.0, true)
		draw_circle(Vector2(head_x, y), 4.0, accent_color)


## Title (shared)
@onready var _title_label: Label = $SubViewport/Panel/VBoxContainer/TitleLabel

## --- Select page ---
@onready var _select_page: VBoxContainer = $SubViewport/Panel/VBoxContainer/SelectPage
@onready var _robot_list_label: Label = $SubViewport/Panel/VBoxContainer/SelectPage/RobotListLabel
@onready var _robot_grid_scroll: ScrollContainer = $SubViewport/Panel/VBoxContainer/SelectPage/RobotGridScroll
@onready var _robot_grid: GridContainer = $SubViewport/Panel/VBoxContainer/SelectPage/RobotGridScroll/RobotGrid
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
var _robot_cards: Dictionary = {}
var _robot_card_tweens: Dictionary = {}
var _selected_robot_name := ""

## Currently connected state
var _connected := false
## Currently shown UI state
var _state: int = State.SELECT
## Address of the device we asked to connect to (used for the control page header)
var _pending_ip := ""
var _pending_port := 0

var _icon_cache: Dictionary = {}
var _handshake_overlay: PanelContainer
var _handshake_card: PanelContainer
var _handshake_icon: TextureRect
var _handshake_label: Label
var _handshake_scan: HandshakeScan
var _handshake_tween: Tween
var _handshake_active := false
var _handshake_sequence_id := 0
var _feedback_input_mode := "controllers"
var _feedback_controller: XRController3D


func _ready() -> void:
	_apply_static_text()
	_build_handshake_overlay()

	if _robot_grid:
		_robot_grid.columns = 2
	if _robot_grid_scroll:
		_robot_grid_scroll.follow_focus = true

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
		# "Back" is implemented as a disconnect - the driver is the only
		# reason we are in CONTROL state, so leaving it means dropping the
		# session and returning to the selector.
		_back_button.pressed.connect(_on_disconnect_pressed)

	_set_state(State.SELECT)
	_refresh_robot_list()
	_update_ui()


func set_feedback_input_mode(mode: String, controller: XRController3D = null) -> void:
	_feedback_input_mode = mode
	_feedback_controller = controller


# --- Select-page actions ---------------------------------------------------

func _on_enter_pressed() -> void:
	var ip := _ip_input.text.strip_edges()
	var port := _port_input.text.strip_edges().to_int()

	if ip.is_empty():
		_set_status(tr("UI_NO_HARDWARE_ADDRESS"))
		_play_ui_sound("error")
		_shake_control(_ip_input)
		return
	if port <= 0 or port > 65535:
		port = DEFAULT_PORT
		if _port_input:
			_port_input.text = str(port)

	_pending_ip = ip
	_pending_port = port
	_connected = false
	_update_ui()
	_play_ui_sound("click")
	_start_handshake(ip, port)
	connect_requested.emit(ip, port)


func _select_robot(robot_name: String) -> void:
	if not _robots.has(robot_name):
		return
	_selected_robot_name = robot_name
	var info: Dictionary = _robots[robot_name]
	if _ip_input:
		_ip_input.text = String(info.get("ip", ""))
	if _port_input:
		_port_input.text = str(int(info.get("pose_port", DEFAULT_PORT)))
	_refresh_robot_card_styles()


func _activate_robot(robot_name: String) -> void:
	_select_robot(robot_name)
	_on_enter_pressed()


func _on_robot_card_pressed(robot_name: String) -> void:
	_play_ui_sound("click")
	_select_robot(robot_name)


func _on_robot_card_gui_input(event: InputEvent, robot_name: String) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed and mouse_event.double_click:
			_activate_robot(robot_name)


func _on_robot_card_hover_enter(robot_name: String) -> void:
	_play_ui_sound("hover")
	_animate_robot_card(robot_name, true)
	_refresh_robot_card_styles(robot_name)


func _on_robot_card_hover_exit(robot_name: String) -> void:
	_animate_robot_card(robot_name, false)
	_refresh_robot_card_styles()


# --- Control-page actions --------------------------------------------------

func _on_disconnect_pressed() -> void:
	_play_ui_sound("click")
	disconnect_requested.emit()


# --- Discovery feed --------------------------------------------------------

## Add a discovered robot to the list.
func add_robot(robot_name: String, ip: String, pose_port: int, video_port: int, device_type: String = "", device_name: String = "") -> void:
	var is_new := not _robots.has(robot_name)
	_robots[robot_name] = {
		"ip": ip,
		"pose_port": pose_port,
		"video_port": video_port,
		"device_type": device_type,
		"device_name": device_name,
	}
	if is_new:
		_play_ui_sound("discovery_found")
	_refresh_robot_list()


## Remove a robot from the list.
func remove_robot(robot_name: String) -> void:
	_robots.erase(robot_name)
	if _selected_robot_name == robot_name:
		_selected_robot_name = ""
	_refresh_robot_list()


func _refresh_robot_list() -> void:
	if not _robot_grid:
		return

	for child in _robot_grid.get_children():
		child.queue_free()
	_robot_cards.clear()
	_robot_card_tweens.clear()

	var names: Array = _robots.keys()
	names.sort()
	if names.is_empty():
		var empty := Label.new()
		empty.text = tr("UI_NO_ROBOTS_DISCOVERED")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 17)
		empty.add_theme_color_override("font_color", COL_MUTED)
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_robot_grid.add_child(empty)
		return

	for robot_name in names:
		var info: Dictionary = _robots[robot_name]
		var card := _make_robot_card(robot_name, info)
		_robot_grid.add_child(card)
		_robot_cards[robot_name] = card

		if _selected_robot_name.is_empty():
			_select_robot(String(names[0]))
		else:
			_refresh_robot_card_styles()


func _make_robot_card(robot_name: String, info: Dictionary) -> Button:
	var device_type: String = String(info.get("device_type", ""))
	var device_name: String = String(info.get("device_name", ""))
	var head: String = device_name if device_name != "" else robot_name
	var display_type := _robot_type_display(device_type) if device_type != "" else tr("UI_UNKNOWN")
	var address := "%s:%d" % [String(info.get("ip", "?")), int(info.get("pose_port", 0))]

	var card := Button.new()
	card.text = ""
	card.flat = true
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = CARD_MIN_SIZE
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.clip_text = false
	card.add_theme_stylebox_override("normal", _robot_card_style(robot_name == _selected_robot_name, false))
	card.add_theme_stylebox_override("hover", _robot_card_style(robot_name == _selected_robot_name, true))
	card.add_theme_stylebox_override("pressed", _robot_card_style(true, true))
	card.add_theme_stylebox_override("focus", _robot_card_style(true, true))
	card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)
	card.pressed.connect(_on_robot_card_pressed.bind(robot_name))
	card.gui_input.connect(_on_robot_card_gui_input.bind(robot_name))
	card.mouse_entered.connect(_on_robot_card_hover_enter.bind(robot_name))
	card.mouse_exited.connect(_on_robot_card_hover_exit.bind(robot_name))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	var icon_box := PanelContainer.new()
	icon_box.custom_minimum_size = Vector2(56, 56)
	icon_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_box.add_theme_stylebox_override("panel", _icon_badge_style())
	row.add_child(icon_box)

	var icon := TextureRect.new()
	icon.texture = _icon_for_device(device_type)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_box.add_child(icon)

	var text_box := VBoxContainer.new()
	text_box.add_theme_constant_override("separation", 2)
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text_box)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_box.add_child(name_row)

	var dot := PanelContainer.new()
	dot.custom_minimum_size = Vector2(12, 12)
	dot.add_theme_stylebox_override("panel", _status_dot_style(COL_ONLINE))
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(dot)

	var name_label := Label.new()
	name_label.text = head
	name_label.add_theme_font_size_override("font_size", 21)
	name_label.add_theme_color_override("font_color", COL_TITLE)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(name_label)

	var type_label := Label.new()
	type_label.text = "%s | %s" % [display_type, robot_name]
	type_label.add_theme_font_size_override("font_size", 15)
	type_label.add_theme_color_override("font_color", COL_MUTED)
	type_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	type_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_box.add_child(type_label)

	var addr_label := Label.new()
	addr_label.text = address
	addr_label.add_theme_font_size_override("font_size", 14)
	addr_label.add_theme_color_override("font_color", COL_MUTED)
	addr_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_box.add_child(addr_label)

	return card


# --- State management ------------------------------------------------------

## Update connected state and UI. Called by main.gd from TcpHandler signals.
## Note: socket-level connect happens BEFORE the v2 descriptor handshake,
## so this only flips the status text. Page switching waits until
## `show_device_info` is called from `_on_device_connected`.
func set_connected(connected: bool) -> void:
	var was_connected := _connected
	_connected = connected
	if connected:
		_set_status(tr("UI_CONNECTED_HANDSHAKE"))
		if _handshake_active:
			_show_handshake_step(tr("UI_HANDSHAKE_STEP_WAITING"), "handshake")
	else:
		_pending_ip = ""
		_pending_port = 0
		if was_connected or _handshake_active:
			_play_ui_sound("disconnected")
		_hide_handshake_overlay()
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
		var addr := "%s:%d" % [_pending_ip, _pending_port] if _pending_ip != "" else "--"
		_device_address_label.text = tr("UI_ADDRESS_LABEL") % addr

	_connected = true
	_set_status(tr("UI_DRIVER_ACTIVE") % [dname, display_type])
	_show_handshake_step(tr("UI_HANDSHAKE_STEP_ONLINE") % dname, "check")
	_play_ui_sound("connected")
	await get_tree().create_timer(0.5).timeout
	if not _connected:
		return
	_hide_handshake_overlay()
	_set_state(State.CONTROL)
	_update_ui()


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
	# Select page: keep inputs locked while the socket/handshake is active.
	var busy := _connected or _handshake_active
	if _enter_button:
		_enter_button.disabled = busy
	if _ip_input:
		_ip_input.editable = not busy
	if _port_input:
		_port_input.editable = not busy


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
		_configure_button(_enter_button, "signal")
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
		_configure_button(_back_button, "arrow-left")
	if _disconnect_button:
		_disconnect_button.text = tr("UI_DISCONNECT")
		_configure_button(_disconnect_button, "plug")
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


# --- Handshake overlay -----------------------------------------------------

func _start_handshake(ip: String, port: int) -> void:
	_handshake_active = true
	_handshake_sequence_id += 1
	_update_ui()
	_set_status(tr("UI_CONNECTING_TO") % [ip, port])
	_show_handshake_step(tr("UI_HANDSHAKE_STEP_BROADCAST"), "signal")
	_advance_handshake_to_waiting(_handshake_sequence_id)


func _advance_handshake_to_waiting(sequence_id: int) -> void:
	await get_tree().create_timer(0.35).timeout
	if not _handshake_active or sequence_id != _handshake_sequence_id:
		return
	_show_handshake_step(tr("UI_HANDSHAKE_STEP_WAITING"), "handshake")


func _build_handshake_overlay() -> void:
	var viewport := $SubViewport as SubViewport
	if viewport == null:
		return

	_handshake_overlay = PanelContainer.new()
	_handshake_overlay.name = "HandshakeOverlay"
	_handshake_overlay.visible = false
	_handshake_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_handshake_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_handshake_overlay.add_theme_stylebox_override("panel", _overlay_style())
	viewport.add_child(_handshake_overlay)

	_handshake_card = PanelContainer.new()
	_handshake_card.custom_minimum_size = HANDSHAKE_CARD_SIZE
	_handshake_card.size = HANDSHAKE_CARD_SIZE
	_handshake_card.position = _handshake_card_base_position()
	_handshake_card.pivot_offset = HANDSHAKE_CARD_SIZE * 0.5
	_handshake_card.add_theme_stylebox_override("panel", _handshake_card_style())
	_handshake_overlay.add_child(_handshake_card)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	_handshake_card.add_child(margin)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 14)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(box)

	_handshake_icon = TextureRect.new()
	_handshake_icon.custom_minimum_size = Vector2(58, 58)
	_handshake_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_handshake_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_handshake_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_handshake_icon)

	_handshake_label = Label.new()
	_handshake_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_handshake_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_handshake_label.add_theme_font_size_override("font_size", 24)
	_handshake_label.add_theme_color_override("font_color", COL_TITLE)
	_handshake_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_handshake_label)

	_handshake_scan = HandshakeScan.new()
	_handshake_scan.accent_color = COL_ACCENT
	box.add_child(_handshake_scan)


func _show_handshake_step(text: String, icon_name: String) -> void:
	if _handshake_overlay == null or _handshake_card == null:
		return
	_handshake_active = true
	_handshake_overlay.visible = true
	_handshake_overlay.modulate.a = 1.0
	_update_ui()

	if _handshake_label:
		_handshake_label.text = text
	if _handshake_icon:
		_handshake_icon.texture = _load_icon(icon_name)
	if _handshake_scan:
		_handshake_scan.set_active(true)

	if _handshake_tween != null and _handshake_tween.is_valid():
		_handshake_tween.kill()
	_handshake_card.position = _handshake_card_base_position() + Vector2(42.0, 0.0)
	_handshake_card.scale = Vector2(0.96, 0.96)
	_handshake_card.modulate.a = 0.0
	_handshake_tween = _handshake_card.create_tween()
	_handshake_tween.set_parallel(true)
	_handshake_tween.set_trans(Tween.TRANS_BACK)
	_handshake_tween.set_ease(Tween.EASE_OUT)
	_handshake_tween.tween_property(_handshake_card, "position", _handshake_card_base_position(), 0.22)
	_handshake_tween.tween_property(_handshake_card, "scale", Vector2.ONE, 0.22)
	_handshake_tween.tween_property(_handshake_card, "modulate:a", 1.0, 0.18)


func _hide_handshake_overlay() -> void:
	_handshake_active = false
	_handshake_sequence_id += 1
	_update_ui()
	if _handshake_scan:
		_handshake_scan.set_active(false)
	if _handshake_overlay == null:
		return
	if _handshake_tween != null and _handshake_tween.is_valid():
		_handshake_tween.kill()
	var tween := _handshake_overlay.create_tween()
	tween.tween_property(_handshake_overlay, "modulate:a", 0.0, 0.12)
	tween.tween_callback(func() -> void:
		if _handshake_overlay:
			_handshake_overlay.visible = false
			_handshake_overlay.modulate.a = 1.0
	)


func _handshake_card_base_position() -> Vector2:
	return Vector2((600.0 - HANDSHAKE_CARD_SIZE.x) * 0.5, (450.0 - HANDSHAKE_CARD_SIZE.y) * 0.5)


# --- Styling / assets ------------------------------------------------------

func _configure_button(button: Button, icon_name: String) -> void:
	button.icon = _load_icon(icon_name)
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_constant_override("icon_max_width", 28)
	button.add_theme_font_size_override("font_size", 21)


func _icon_for_device(device_type: String) -> Texture2D:
	match device_type:
		"robot_arm":
			return _load_icon("robot-arm")
		"rc_car":
			return _load_icon("car")
		_:
			return _load_icon("signal")


func _load_icon(icon_name: String) -> Texture2D:
	if _icon_cache.has(icon_name):
		return _icon_cache[icon_name]
	var path := ICON_PATH % icon_name
	var texture: Texture2D = null
	if FileAccess.file_exists(path):
		var svg := FileAccess.get_file_as_string(path)
		var image := Image.new()
		if image.load_svg_from_string(svg, 1.0) == OK:
			texture = ImageTexture.create_from_image(image)
	_icon_cache[icon_name] = texture
	return texture


func _panel_style(bg: Color = COL_PANEL_BG, border: Color = COL_PANEL_BORDER, radius: int = 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(radius)
	return style


func _robot_card_style(selected: bool, hovered: bool) -> StyleBoxFlat:
	var bg := Color(0.070, 0.084, 0.100, 0.92)
	var border := Color(0.24, 0.28, 0.32, 1.0)
	if selected:
		bg = Color(0.115, 0.096, 0.060, 0.96)
		border = COL_ACCENT
	elif hovered:
		border = Color(1.0, 0.647, 0.169, 0.58)
	return _panel_style(bg, border, 7)


func _icon_badge_style() -> StyleBoxFlat:
	var style := _panel_style(COL_ACCENT_SOFT, Color(1.0, 0.647, 0.169, 0.38), 8)
	style.content_margin_left = 7
	style.content_margin_right = 7
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


func _status_dot_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(8)
	return style


func _overlay_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL_GLASS
	return style


func _handshake_card_style() -> StyleBoxFlat:
	return _panel_style(Color(0.070, 0.084, 0.100, 0.98), COL_ACCENT, 8)


func _refresh_robot_card_styles(hovered_name: String = "") -> void:
	for robot_name in _robot_cards.keys():
		var card := _robot_cards[robot_name] as Button
		if card == null:
			continue
		var selected := String(robot_name) == _selected_robot_name
		var hovered := String(robot_name) == hovered_name
		card.add_theme_stylebox_override("normal", _robot_card_style(selected, hovered))
		card.add_theme_stylebox_override("hover", _robot_card_style(selected, true))
		card.add_theme_stylebox_override("pressed", _robot_card_style(true, true))
		card.add_theme_stylebox_override("focus", _robot_card_style(true, true))


func _animate_robot_card(robot_name: String, hovered: bool) -> void:
	if not _robot_cards.has(robot_name):
		return
	var card := _robot_cards[robot_name] as Button
	if card == null:
		return
	if _robot_card_tweens.has(robot_name):
		var prev := _robot_card_tweens[robot_name] as Tween
		if prev != null and prev.is_valid():
			prev.kill()
	var tween := card.create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_BACK)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", CARD_HOVER_SCALE if hovered else CARD_NORMAL_SCALE, CARD_TWEEN_DURATION)
	tween.tween_property(card, "position:y", CARD_HOVER_Y_OFFSET if hovered else 0.0, CARD_TWEEN_DURATION)
	_robot_card_tweens[robot_name] = tween


func _play_ui_sound(action: String, volume_db: float = 0.0) -> void:
	if _feedback_input_mode == "hands":
		var sound_bus := _get_ui_sound_bus()
		if sound_bus != null and sound_bus.has_method("play"):
			sound_bus.call("play", action, volume_db)
	elif _feedback_input_mode == "controllers":
		var haptics := _get_haptics_bus()
		var use_haptics := _feedback_controller != null
		if haptics != null and haptics.has_method("should_use_controller_feedback"):
			use_haptics = bool(haptics.call("should_use_controller_feedback", _feedback_controller))
		if use_haptics and haptics != null and haptics.has_method("fire_ui_event"):
			haptics.call("fire_ui_event", action, _feedback_controller)
		else:
			var sound_bus := _get_ui_sound_bus()
			if sound_bus != null and sound_bus.has_method("play"):
				sound_bus.call("play", action, volume_db)


func _get_ui_sound_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("UISoundBus")


func _get_haptics_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Haptics")


func _shake_control(control: Control) -> void:
	if control == null:
		return
	var base_x := control.position.x
	var tween := control.create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	for offset in [6.0, -6.0, 4.0, -4.0, 0.0]:
		tween.tween_property(control, "position:x", base_x + offset, 0.045)
