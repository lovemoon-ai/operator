extends Node3D
## Main scene controller for Teleoperate-Anything.
## Initializes XR with passthrough. Uses v2 protocol:
## Hello → DeviceDescriptor → DeviceCommand ↔ Telemetry.
##
## UI model (per issue 004 / settings redesign):
##  - At launch, view-locked composition-layer SettingsPanel is visible if
##    discovery needs manual confirmation. User fills IP / Port / Robot Type /
##    Video window mode, presses OK.
##  - OK → save to user://teleop_settings.cfg, hide panel, show face-locked
##    floating SettingsButton, kick off TCP connect.
##  - The floating button (face-locked, under XRCamera3D) re-opens the
##    panel when pressed.
##  - The old left-bottom HUD and right-bottom DynamicHUD are gone — all
##    status now goes to print() (logcat-visible) and the panel's own
##    status label while the panel is open.

const SettingsUI = preload("res://scripts/ui/teleop_settings_panel.gd")
const SettingsLauncherButtonScript = preload("res://scripts/ui/settings_launcher_button.gd")
const SettingsInteractionRouterScript = preload("res://scripts/ui/settings_interaction_router.gd")
const TeleopControllerPanelScript = preload("res://scripts/ui/teleop_controller_panel.gd")
const OperatorUIPointerVisualScript = preload("res://scripts/xr/operator_ui_pointer_visual.gd")

const SETTINGS_PANEL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const SETTINGS_BUTTON_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18, -0.5))
const TELEOP_CONTROLLER_OVERLAY_OFFSET := Transform3D.IDENTITY

@onready var _start_xr: XRToolsStartXR = get_node_or_null("StartXR")
@onready var _origin: XROrigin3D = $XROrigin3D
@onready var _camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var _left_controller: XRController3D = $XROrigin3D/LeftController
@onready var _right_controller: XRController3D = $XROrigin3D/RightController
@onready var _tracking_provider: Node = $TrackingProvider
@onready var _tcp_handler: Node = $TcpHandler
@onready var _discovery: Node = $Discovery
@onready var _robot_view: Node = $XROrigin3D/RobotView

## v2 nodes (created programmatically)
var _session: Session
var _command_sender: CommandSender
## TCP video handler — used when the descriptor selects "tcp" or as the
## fallback for "auto"-mode descriptors that didn't supply a UDP port.
var _video_tcp_handler: TcpHandler
## [issue 005 / item 1] UDP video handler. Created lazily in
## `_create_v2_nodes`; only `connect_to_video_stream` when the
## descriptor advertises `transport=udp` (or `transport=auto` plus a
## non-zero `udp_port`).
var _video_udp_handler: UdpVideoHandler
var _active_video_transport: String = "tcp"  # "tcp" or "udp"
var _last_video_feed: Dictionary = {}
var _clock_sync: RobotClockSync
var _known_robots: Dictionary = {}

var _settings_panel: Node3D
var _settings_button: Node3D
var _settings_ui: Node = null
var _settings_interaction_router: Node
var _settings_pointer_visual: Node3D
var _teleop_controller_panel: Node3D

## Selected by the user in the Settings UI; used as a hint until the
## DeviceDescriptor arrives and overrides it.
var _user_robot_type_hint: String = "robot_arm"

var _xr_started: bool = false
var _launch_window_active: bool = false
var _launch_window_token: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	_configure_passthrough()
	_create_v2_nodes()
	_create_settings_ui_nodes()

	if _start_xr:
		_start_xr.xr_started.connect(_on_xr_started)
		# XRToolsStartXR in newer godot-xr-tools no longer exposes
		# `xr_failed`; previously this raised a hard SCRIPT ERROR that
		# aborted _ready() BEFORE the TcpHandler signal wiring below
		# ran. has_signal() guards us.
		if _start_xr.has_signal("xr_failed"):
			_start_xr.xr_failed.connect(_on_xr_failed)

	# Wire up subsystem connections
	_tcp_handler.connected_to_server.connect(_on_connected)
	_tcp_handler.disconnected_from_server.connect(_on_disconnected)
	_tcp_handler.connection_failed.connect(_on_connection_failed)
	_tcp_handler.command_received.connect(_on_command_received)

	_video_tcp_handler.connected_to_server.connect(_on_video_connected)
	_video_tcp_handler.disconnected_from_server.connect(_on_video_disconnected)
	_video_tcp_handler.connection_failed.connect(_on_video_connection_failed)
	_video_tcp_handler.video_frame_received.connect(_on_video_frame_received)

	# [issue 005 / item 1] UDP signal wiring. The handler is dormant until
	# `_connect_video_stream` actually calls connect_to_video_stream on it.
	_video_udp_handler.connected_to_server.connect(_on_video_connected)
	_video_udp_handler.disconnected_from_server.connect(_on_video_disconnected)
	_video_udp_handler.connection_failed.connect(_on_video_connection_failed)
	_video_udp_handler.video_frame_received.connect(_on_video_frame_received)

	_discovery.robot_found.connect(_on_robot_found)
	_discovery.robot_lost.connect(_on_robot_lost)

	# Wire up Session signals
	_session.device_connected.connect(_on_device_connected)
	_session.device_disconnected.connect(_on_device_disconnected)
	_session.telemetry_received.connect(_on_telemetry_received)

	# Configure command sender references
	_command_sender.tracking_provider = _tracking_provider
	_command_sender.tcp_handler = _tcp_handler

	# Start discovery scanning in the background; the Settings panel opens
	# as soon as XR is ready and shows discovery progress while this runs.
	_discovery.start_scan()

	# Initial UI state: hide both until XR is ready enough to place
	# composition layers. `_begin_launch_window` opens the panel immediately
	# instead of waiting for discovery to finish.
	_settings_panel.visible = false
	_settings_button.visible = false

	# Apply persisted video-mode immediately so RobotView starts in the
	# user's preferred orientation (face-locked vs world-locked) without
	# waiting for a fresh OK press.
	var persisted: Dictionary = SettingsUI.load_settings()
	_user_robot_type_hint = persisted.get("robot_type", "robot_arm")
	if _robot_view:
		_robot_view.follow_camera = bool(persisted.get("video_face_locked", true))
		# `show_video_panel` defaults to false: a fresh install should NOT
		# pop a placeholder quad in front of the operator before any robot
		# has sent a frame. The user opts in via the Settings panel toggle.
		if _robot_view.has_method("set_show_video_panel"):
			_robot_view.set_show_video_panel(bool(persisted.get("show_video_panel", false)))

	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		call_deferred("_on_xr_started")

	print("[Operator] Main scene initialized (UI hidden — awaiting XR)")


func _process(_delta: float) -> void:
	if _camera:
		if _settings_panel:
			_settings_panel.transform = _camera.transform * SETTINGS_PANEL_OFFSET
		if _settings_button:
			_settings_button.transform = _camera.transform * SETTINGS_BUTTON_OFFSET
	if _settings_interaction_router:
		_settings_interaction_router.interaction_mode = "controllers"
		_settings_interaction_router.busy = false
		_settings_interaction_router.set_targets([_settings_panel, _settings_button])
		_settings_interaction_router.update_pointer()
	_update_teleop_controller_panel()


func _create_v2_nodes() -> void:
	_session = Session.new()
	_session.name = "Session"
	_session.tcp_handler = _tcp_handler
	add_child(_session)

	_command_sender = CommandSender.new()
	_command_sender.name = "CommandSender"
	add_child(_command_sender)

	# Dedicated video stream handler. [issue 005 / item 6] Bumped to
	# 32 MiB so a freshly connected client surviving a brief WiFi
	# stall doesn't trip the overflow-disconnect cycle on the next IDR.
	_video_tcp_handler = TcpHandler.new()
	_video_tcp_handler.name = "VideoTcpHandler"
	_video_tcp_handler.set_max_recv_buffer(32 * 1024 * 1024)
	add_child(_video_tcp_handler)

	# [issue 005 / item 1] UDP video handler — same API surface as the
	# TCP one (connect_to_video_stream / video_frame_received signal)
	# so swap-in is mechanical. Stays idle until the descriptor asks for it.
	_video_udp_handler = UdpVideoHandler.new()
	_video_udp_handler.name = "VideoUdpHandler"
	add_child(_video_udp_handler)

	# [opt 5] Clock-sync helper. Sends ClockPing on the command channel
	# every second; the offset it learns is read by VideoLatencyTracker
	# to make `tx=` honest.
	_clock_sync = RobotClockSync.new()
	_clock_sync.name = "ClockSync"
	_clock_sync.tcp_handler = _tcp_handler
	add_child(_clock_sync)


# --- Settings UI wiring -------------------------------------------------------

func _create_settings_ui_nodes() -> void:
	_settings_pointer_visual = OperatorUIPointerVisualScript.new()
	_settings_pointer_visual.name = "SettingsPointerVisual"
	_origin.add_child(_settings_pointer_visual)

	_settings_panel = SettingsUI.new()
	_settings_panel.name = "TeleopSettingsPanel"
	_settings_panel.settings_applied.connect(_on_settings_applied)
	_settings_panel.exit_requested.connect(_on_settings_exit_requested)
	_origin.add_child(_settings_panel)
	_settings_ui = _settings_panel

	_settings_button = SettingsLauncherButtonScript.new()
	_settings_button.name = "TeleopSettingsButton"
	_settings_button.pressed.connect(_on_settings_button_pressed)
	_origin.add_child(_settings_button)

	_teleop_controller_panel = TeleopControllerPanelScript.new()
	_teleop_controller_panel.name = "TeleopControllerPanel"
	# Keep the controller overlay in origin space and drive its global transform
	# from the right controller so it stays aligned with the physical controller.
	_origin.add_child(_teleop_controller_panel)
	_update_teleop_controller_panel_transform()

	_settings_interaction_router = SettingsInteractionRouterScript.new()
	_settings_interaction_router.name = "SettingsInteractionRouter"
	_settings_interaction_router.configure(_origin, _camera, _left_controller, _right_controller, _settings_pointer_visual)
	_settings_interaction_router.set_targets([_settings_panel, _settings_button])
	_origin.add_child(_settings_interaction_router)


func _update_teleop_controller_panel() -> void:
	if _teleop_controller_panel == null:
		return
	var controller_active := _is_right_controller_mode_active()
	_teleop_controller_panel.call("set_controller_active", controller_active)
	_update_teleop_controller_panel_transform(controller_active)
	var connected: bool = _tcp_handler != null and _tcp_handler.is_connected_to_robot()
	var grip_value := 0.0
	var trigger_value := 0.0
	var a_pressed := false
	if controller_active and _tracking_provider and _tracking_provider.has_method("get_controller_input"):
		var input_any: Variant = _tracking_provider.call("get_controller_input", 1)
		if input_any is Dictionary:
			grip_value = maxf(
				float(input_any.get("grip", 0.0)),
				maxf(float(input_any.get("grip_click", 0.0)), float(input_any.get("grip_force", 0.0)))
			)
			trigger_value = float(input_any.get("trigger", 0.0))
			a_pressed = float(input_any.get("ax_button", 0.0)) >= 0.5
	_teleop_controller_panel.call("set_bridge_connected", connected)
	_teleop_controller_panel.call("set_grip_value", grip_value)
	_teleop_controller_panel.call("set_trigger_value", trigger_value)
	_teleop_controller_panel.call("set_a_button_pressed", a_pressed)


func _update_teleop_controller_panel_transform(controller_active: bool = true) -> void:
	if _teleop_controller_panel == null or _right_controller == null:
		return
	if not controller_active:
		return
	_teleop_controller_panel.global_transform = _right_controller.global_transform * TELEOP_CONTROLLER_OVERLAY_OFFSET


func _is_right_controller_mode_active() -> bool:
	if _tracking_provider and _tracking_provider.has_method("is_controller_mode_active"):
		return bool(_tracking_provider.call("is_controller_mode_active", 1))
	return _right_controller != null and _right_controller.get_is_active() and _right_controller.get_has_tracking_data()


# --- XR lifecycle -------------------------------------------------------------

func _on_xr_started() -> void:
	if _xr_started:
		return
	_xr_started = true
	_configure_passthrough()
	_robot_view.initialize()
	print("[Operator] XR Ready — XR started successfully")

	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface:
		# XRRuntimeName comes back as Nil on Pico's OpenXR build; strict
		# typing was crashing this _ready in the past — keep the Variant
		# dance.
		var runtime_any: Variant = xr_interface.get("XRRuntimeName")
		if typeof(runtime_any) == TYPE_STRING and not String(runtime_any).is_empty():
			print("[Operator] OpenXR runtime: %s" % String(runtime_any))

	_begin_launch_window()


func _on_xr_failed() -> void:
	_set_status(tr("UI_XR_FAILED_START"))


func _configure_passthrough() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.transparent_bg = true
		viewport.physics_object_picking = false
		var world := viewport.get_world_3d()
		if world and world.environment:
			world.environment.background_mode = Environment.BG_CLEAR_COLOR
			world.environment.background_color = Color(0, 0, 0, 0)

	if _start_xr and _start_xr.xr_interface:
		_start_xr.xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND


# --- Settings flow ------------------------------------------------------------

## Called by SettingsUI when the user presses Confirm.
## Saves the panel state, hides it, then connects/reconnects with the chosen
## endpoint. robot_type is a hint that the descriptor will override on handshake.
func _on_settings_applied(ip: String, port: int, robot_type: String, video_face_locked: bool, show_video_panel: bool, show_on_launch: bool) -> void:
	print("[Operator] Settings applied: ip=%s port=%d type=%s face_locked=%s show_video=%s show_on_launch=%s" % [
		ip, port, robot_type, video_face_locked, show_video_panel, show_on_launch,
	])
	_cancel_launch_window()
	_user_robot_type_hint = robot_type

	# Apply video window mode immediately.
	if _robot_view:
		_robot_view.follow_camera = video_face_locked
		if _robot_view.has_method("set_show_video_panel"):
			_robot_view.set_show_video_panel(show_video_panel)

	_hide_settings_panel()

	# Tear down any existing session before reconnecting (handles "user
	# pressed OK twice with different IP" without leaking sockets).
	if _tcp_handler.is_connected_to_robot():
		_tcp_handler.disconnect_from_robot()
		_video_tcp_handler.disconnect_from_robot()
		_video_udp_handler.disconnect_from_robot()

	_connect_to_robot(ip, port)


func _on_settings_button_pressed() -> void:
	_show_settings_panel()


## Legacy close signal: hide it and re-show the floating settings button so
## the user can reopen later.
func _on_settings_close_requested() -> void:
	_hide_settings_panel()


## Exit on the panel returns to the mode-select / launcher scene so the
## user can pick a different mode without restarting the app. The session
## is torn down cleanly first; the Exit *card* on the launcher itself is
## what actually quits the process.
func _on_settings_exit_requested() -> void:
	print("[Operator] Settings exit requested — returning to mode select")
	_cancel_launch_window()
	if _command_sender:
		_command_sender.set_sending(false)
	if _clock_sync:
		_clock_sync.stop()
	if _discovery and _discovery.has_method("stop_scan"):
		_discovery.stop_scan()
	if _tcp_handler:
		_tcp_handler.disconnect_from_robot()
	if _video_tcp_handler:
		_video_tcp_handler.disconnect_from_robot()
	if _video_udp_handler:
		_video_udp_handler.disconnect_from_robot()
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _show_settings_panel() -> void:
	# Re-push the latest discovery snapshot every time we open the panel —
	# robots may have appeared / disappeared while it was closed.
	_push_discovery_to_settings_ui()
	if _settings_ui and _settings_ui.has_method("set_discovering"):
		_settings_ui.set_discovering(false)
	if _settings_button and _settings_button.has_method("clear_pointer"):
		_settings_button.clear_pointer()
	if _settings_panel and _settings_panel.has_method("set_feedback_input_mode"):
		_settings_panel.set_feedback_input_mode("controllers", _right_controller)
	if _settings_panel and _settings_panel.has_method("open"):
		_settings_panel.open()
	else:
		_settings_panel.visible = true
	_settings_button.visible = false


func _hide_settings_panel() -> void:
	if _settings_panel and _settings_panel.has_method("close"):
		_settings_panel.close()
	else:
		_settings_panel.visible = false
	_settings_button.visible = true


# --- Launch decision (D: hybrid auto-discover) -------------------------------
#
# The panel opens immediately with a spinner while discovery gets a 3s window
# to find robot(s), then we pick one of:
#
#   show_on_launch == true   → always show panel
#   0 robots                 → show panel (manual fallback, status hints why)
#   1 robot == last_used_ip  → auto-connect after spinner, close panel
#   1 robot, last_used_ip is loopback default → auto-connect after spinner
#   1 robot, different IP    → show panel pre-filled with the new IP
#   N robots                 → show panel with the dropdown populated
#
# `last_used_ip` lives in user://teleop_settings.cfg. The robot agent broadcasts on
# 255.255.255.255:63900 every 3s, so a 3s window catches one beacon under
# normal conditions.

const _LAUNCH_DISCOVERY_WINDOW_SEC: float = 3.0


func _begin_launch_window() -> void:
	_launch_window_token += 1
	_launch_window_active = true
	print("[Operator] Discovery window started (%.1fs)" % _LAUNCH_DISCOVERY_WINDOW_SEC)
	_show_settings_panel_discovering()
	get_tree().create_timer(_LAUNCH_DISCOVERY_WINDOW_SEC).timeout.connect(_finalize_launch.bind(_launch_window_token))


func _cancel_launch_window() -> void:
	_launch_window_active = false
	_launch_window_token += 1
	if _settings_ui and _settings_ui.has_method("set_discovering"):
		_settings_ui.set_discovering(false)


func _finalize_launch(token: int) -> void:
	if token != _launch_window_token or not _launch_window_active:
		return
	_launch_window_active = false
	var persisted: Dictionary = SettingsUI.load_settings()
	var show_on_launch: bool = bool(persisted.get("show_on_launch", false))
	var last_ip: String = String(persisted.get("ip", ""))
	var n_robots: int = _known_robots.size()

	print("[Operator] Launch decision: known=%d show_on_launch=%s last_ip=%s" % [
		n_robots, show_on_launch, last_ip,
	])

	if show_on_launch:
		_show_settings_panel_with_status(tr("UI_SHOW_ON_LAUNCH_ENABLED"))
		return

	if n_robots == 0:
		_show_settings_panel_with_status(tr("UI_NO_ROBOTS_DISCOVERED"))
		return

	# Try to match last-used IP first — that's the "silent auto-connect" case.
	if n_robots == 1:
		var only_ip := String(_known_robots.keys()[0])
		var only_info: Dictionary = _known_robots[only_ip]
		if only_ip == last_ip or _is_loopback_host(last_ip):
			_auto_connect_to_discovered(only_ip, int(only_info.get("pose_port", 63901)), only_info)
			return
		# Single robot but it's not the one we used before — surface it for confirmation.
		_show_settings_panel_with_status(tr("UI_FOUND_ROBOT_CONFIRM") % only_ip)
		return

	# Multiple robots. If one matches last_ip, the panel will pre-select it
	# (set_discovery_state honors `prefer_ip`).
	_show_settings_panel_with_status(tr("UI_ROBOTS_FOUND_PICK") % n_robots)


func _is_loopback_host(host: String) -> bool:
	var trimmed := host.strip_edges().to_lower()
	return trimmed == "" \
			or trimmed == "localhost" \
			or trimmed == "::1" \
			or trimmed == "0:0:0:0:0:0:0:1" \
			or trimmed.begins_with("127.")


func _auto_connect_to_discovered(ip: String, port: int, info: Dictionary) -> void:
	# Mirror what _on_settings_applied does for the connection bits, minus
	# the panel-hide step (panel was never shown). Also apply persisted
	# video mode + type hint so the auto-path matches what OK would do.
	var persisted: Dictionary = SettingsUI.load_settings()
	if _robot_view:
		_robot_view.follow_camera = bool(persisted.get("video_face_locked", true))
		if _robot_view.has_method("set_show_video_panel"):
			_robot_view.set_show_video_panel(bool(persisted.get("show_video_panel", false)))
	_user_robot_type_hint = String(info.get("device_type", persisted.get("robot_type", "robot_arm")))
	if _settings_ui and _settings_ui.has_method("set_discovering"):
		_settings_ui.set_discovering(false)

	if _settings_panel and _settings_panel.has_method("close"):
		_settings_panel.close()
	else:
		_settings_panel.visible = false
	_settings_button.visible = true
	print("[Operator] Auto-connecting to discovered robot @ %s:%d" % [ip, port])
	_connect_to_robot(ip, port)


func _show_settings_panel_with_status(text: String) -> void:
	_push_discovery_to_settings_ui()
	if _settings_ui and _settings_ui.has_method("set_discovering"):
		_settings_ui.set_discovering(false)
	if _settings_panel and _settings_panel.has_method("open"):
		_settings_panel.open()
	else:
		_settings_panel.visible = true
	_settings_button.visible = false
	if _settings_ui and _settings_ui.has_method("set_status"):
		_settings_ui.set_status(text)


func _show_settings_panel_discovering() -> void:
	_push_discovery_to_settings_ui()
	if _settings_button and _settings_button.has_method("clear_pointer"):
		_settings_button.clear_pointer()
	if _settings_panel and _settings_panel.has_method("open"):
		_settings_panel.open()
	else:
		_settings_panel.visible = true
	_settings_button.visible = false
	if _settings_ui and _settings_ui.has_method("set_discovering"):
		_settings_ui.set_discovering(true, tr("UI_DISCOVERING_ROBOTS"))


## Translate main.gd's IP-keyed `_known_robots` into the name-keyed
## structure SettingsUI expects, then push it down with the user's
## preferred IP so the dropdown auto-selects the right row.
func _push_discovery_to_settings_ui() -> void:
	if not _settings_ui or not _settings_ui.has_method("set_discovery_state"):
		return
	var by_name: Dictionary = {}
	for ip in _known_robots:
		var raw: Dictionary = _known_robots[ip]
		var info: Dictionary = {
			"ip": ip,
			"pose_port": raw.get("pose_port", 63901),
			"video_port": raw.get("video_port", 0),
			"device_type": raw.get("device_type", ""),
			"device_name": raw.get("device_name", ""),
		}
		var rname: String = String(raw.get("name", ip))
		by_name[rname] = info
	var persisted: Dictionary = SettingsUI.load_settings()
	_settings_ui.set_discovery_state(by_name, String(persisted.get("ip", "")))


## Single-path "show this status" helper. Goes to logcat always; goes
## to the settings panel's status label too iff the panel is open and
## its inner UI has surfaced a set_status method.
func _set_status(text: String) -> void:
	print("[Operator] %s" % text)
	if _settings_ui and _settings_panel.visible and _settings_ui.has_method("set_status"):
		_settings_ui.set_status(text)


# --- Connection lifecycle -----------------------------------------------------

func _connect_to_robot(ip: String, port: int) -> void:
	_set_status(tr("UI_CONNECTING_TO") % [ip, port])
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)
	_tcp_handler.connect_to_robot(ip, port)


func _on_connected() -> void:
	_set_status(tr("UI_CONNECTED_HANDSHAKE"))
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", true)
	_session.on_connected()
	_connect_video_stream(_tcp_handler.get_host())
	if _clock_sync:
		_clock_sync.start()


func _on_disconnected() -> void:
	_set_status(tr("UI_DISCONNECTED"))
	_command_sender.set_sending(false)
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)
	_video_tcp_handler.disconnect_from_robot()
	_video_udp_handler.disconnect_from_robot()
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()
	_session.on_disconnected()
	if _clock_sync:
		_clock_sync.stop()


func _on_connection_failed(reason: String) -> void:
	_set_status(tr("UI_CONNECTION_FAILED") % reason)
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)


func _on_command_received(command: String, data: PackedByteArray) -> void:
	if _clock_sync and _clock_sync.handle_command(command, data):
		return
	if _session.handle_command(command, data):
		return
	match command:
		"VideoFrame":
			pass
		_:
			print("[Operator] Unknown command: %s" % command)


func _on_video_connected() -> void:
	print("[Operator] Video stream connected")


func _on_video_disconnected() -> void:
	print("[Operator] Video stream disconnected")
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()


func _on_video_connection_failed(reason: String) -> void:
	print("[Operator] Video connection failed: %s" % reason)


func _on_video_frame_received(packet: Dictionary) -> void:
	if _robot_view and _robot_view.has_method("set_clock_offset"):
		_robot_view.set_clock_offset(RobotClockSync.offset_ns, RobotClockSync.samples)
	if _robot_view and _robot_view.has_method("report_video_packet"):
		_robot_view.report_video_packet(packet)
	elif _robot_view and _robot_view.has_method("report_video_frame"):
		_robot_view.report_video_frame(packet)


func _on_device_connected(descriptor: Dictionary) -> void:
	var device_name: String = descriptor.get("device", {}).get("name", tr("UI_UNKNOWN"))
	var device_type: String = descriptor.get("device", {}).get("type", tr("UI_UNKNOWN"))
	_set_status(tr("UI_DRIVER_ACTIVE") % [device_name, _robot_type_display(device_type)])
	if device_type != _user_robot_type_hint:
		print("[Operator] Robot type hint (%s) differs from descriptor (%s) — descriptor wins" % [
			_user_robot_type_hint, device_type,
		])
	_command_sender.configure_for_device(descriptor)
	_command_sender.set_sending(true)
	if _teleop_controller_panel and _teleop_controller_panel.has_method("configure_for_device"):
		_teleop_controller_panel.call("configure_for_device", descriptor)
		_update_teleop_controller_panel()
	_configure_robot_video_stream(descriptor)
	# [issue 005 / item 1] After the descriptor arrives we now know
	# whether the robot is offering UDP. Re-call `_connect_video_stream`
	# so we can upgrade to UDP if the descriptor advertises it.
	if _tcp_handler.is_connected_to_robot():
		_connect_video_stream(_tcp_handler.get_host())


func _on_device_disconnected() -> void:
	_command_sender.set_sending(false)
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()


func _on_telemetry_received(_data: Dictionary) -> void:
	# Telemetry display panel was removed with the old DynamicHUD. Future
	# work: surface telemetry as an optional overlay or a Phase-2 panel
	# section. For now we just drop the data so the signal stays connected
	# (Session still parses telemetry frames so consumer can subscribe).
	pass


func _configure_robot_video_stream(descriptor: Dictionary) -> void:
	if not _robot_view or not _robot_view.has_method("configure_video_stream"):
		return
	var feed := _extract_primary_video_feed(descriptor)
	if feed.is_empty():
		feed = {
			"width": 1280,
			"height": 720,
			"stereo": false,
		}
	_last_video_feed = feed
	_robot_view.configure_video_stream(feed)


func _extract_primary_video_feed(descriptor: Dictionary) -> Dictionary:
	var feeds: Array = descriptor.get("video_feeds", [])
	for feed_variant in feeds:
		if feed_variant is Dictionary:
			var feed: Dictionary = feed_variant
			if int(feed.get("port", 0)) > 0:
				return feed
	return {}


## [issue 005 / item 1+2] Decide which transport to use for the
## negotiated video feed.
func _select_video_transport(feed: Dictionary) -> String:
	var transport := str(feed.get("transport", "tcp")).to_lower()
	var udp_port := int(feed.get("udp_port", 0))
	if transport == "udp" and udp_port > 0:
		return "udp"
	if transport == "auto" and udp_port > 0:
		return "udp"
	return "tcp"


func _on_robot_found(robot_name: String, ip: String, pose_port: int, video_port: int, device_type: String, device_name: String) -> void:
	# Discovery feed drives both (1) auto-reconnect of the video stream
	# when the descriptor matches the currently connected host, and (2)
	# the SettingsPanel's "Discovered" dropdown (per the D launch flow).
	_known_robots[ip] = {
		"name": robot_name,
		"pose_port": pose_port,
		"video_port": video_port,
		"device_type": device_type,
		"device_name": device_name,
	}
	# Push live update to the panel iff it's currently visible — when the
	# panel is open, the dropdown should mirror discovery in real time.
	if _settings_panel and _settings_panel.visible and _settings_ui and _settings_ui.has_method("add_discovered"):
		_settings_ui.add_discovered(robot_name, {
			"ip": ip,
			"pose_port": pose_port,
			"video_port": video_port,
			"device_type": device_type,
			"device_name": device_name,
		})
	if _tcp_handler.is_connected_to_robot() and _tcp_handler.get_host() == ip:
		_connect_video_stream(ip)


func _on_robot_lost(robot_name: String) -> void:
	for ip in _known_robots.keys():
		var info: Dictionary = _known_robots[ip]
		if info.get("name", "") == robot_name:
			_known_robots.erase(ip)
			if _video_tcp_handler.is_connected_to_robot() and _video_tcp_handler.get_host() == ip:
				_video_tcp_handler.disconnect_from_robot()
			if _video_udp_handler.is_connected_to_robot() and _video_udp_handler.get_host() == ip:
				_video_udp_handler.disconnect_from_robot()
			break
	if _settings_panel and _settings_panel.visible and _settings_ui and _settings_ui.has_method("remove_discovered"):
		_settings_ui.remove_discovered(robot_name)


func _connect_video_stream(ip: String) -> void:
	if ip.is_empty():
		return

	# Resolve the TCP port: prefer the descriptor's primary feed, then
	# the discovery announcement, then the legacy default.
	var tcp_port := 12345
	if _known_robots.has(ip):
		var info: Dictionary = _known_robots[ip]
		tcp_port = int(info.get("video_port", tcp_port))
	if int(_last_video_feed.get("port", 0)) > 0:
		tcp_port = int(_last_video_feed["port"])

	var transport := _select_video_transport(_last_video_feed)
	var udp_port := int(_last_video_feed.get("udp_port", 0))

	# If the active transport is already pointed at the right host+port,
	# don't churn the connection — that flushes decoder state.
	if transport == "tcp":
		if _video_tcp_handler.is_connected_to_robot() \
				and _video_tcp_handler.get_host() == ip \
				and _video_tcp_handler.get_port() == tcp_port:
			_video_udp_handler.disconnect_from_robot()
			_active_video_transport = "tcp"
			return
	else:
		if _video_udp_handler.is_connected_to_robot() \
				and _video_udp_handler.get_host() == ip \
				and _video_udp_handler.get_port() == udp_port:
			_video_tcp_handler.disconnect_from_robot()
			_active_video_transport = "udp"
			return

	# Tear down whichever handler is currently active before bringing up
	# the new one — never run both at once or we'd see duplicate frames.
	_video_tcp_handler.disconnect_from_robot()
	_video_udp_handler.disconnect_from_robot()

	# Reconfigure the decoder for the new transport. We must NOT pass an empty
	# descriptor: it falls through to the hard-coded {1280x720} default feed,
	# which has no `codec` field and so silently resets the decoder MIME from
	# `video/hevc` back to `video/avc` — feeding HEVC NALs into an AVC
	# MediaCodec produces zero output frames. Wrap the cached `_last_video_feed`
	# (which carries codec/stereo/dimensions from the real descriptor) in a
	# descriptor-shape envelope so the same feed is re-extracted unchanged.
	var configure_arg: Dictionary = {}
	if not _last_video_feed.is_empty():
		configure_arg = {"video_feeds": [_last_video_feed]}

	if transport == "udp":
		print("[Operator] Connecting video stream (UDP) to %s:%d" % [ip, udp_port])
		_active_video_transport = "udp"
		_configure_robot_video_stream(configure_arg)
		_video_udp_handler.connect_to_video_stream(ip, udp_port)
		if _robot_view and _robot_view.has_method("set_packet_source"):
			_robot_view.set_packet_source(_video_udp_handler)
	else:
		print("[Operator] Connecting video stream (TCP) to %s:%d" % [ip, tcp_port])
		_active_video_transport = "tcp"
		_configure_robot_video_stream(configure_arg)
		_video_tcp_handler.connect_to_video_stream(ip, tcp_port)
		if _robot_view and _robot_view.has_method("set_packet_source"):
			_robot_view.set_packet_source(_video_tcp_handler)


func _robot_type_display(robot_type: String) -> String:
	match robot_type:
		"robot_arm":
			return tr("UI_DEVICE_TYPE_ROBOT_ARM")
		"rc_car":
			return tr("UI_DEVICE_TYPE_RC_CAR")
		_:
			return robot_type
