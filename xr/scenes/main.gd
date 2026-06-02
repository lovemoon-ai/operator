extends Node3D
## Main scene controller for Teleoperate-Anything.
## Initializes XR with passthrough. Uses v2 protocol:
## Hello → DeviceDescriptor → DeviceCommand ↔ Telemetry.
##
## UI model (per issue 004 / settings redesign):
##  - At launch, world-locked SettingsPanel is visible. User fills IP /
##    Port / Robot Type / Video window mode, presses OK.
##  - OK → save to user://settings.cfg, hide panel, show face-locked
##    floating SettingsButton, kick off TCP connect.
##  - The floating button (face-locked, under XRCamera3D) re-opens the
##    panel when pressed.
##  - The old left-bottom HUD and right-bottom DynamicHUD are gone — all
##    status now goes to print() (logcat-visible) and the panel's own
##    status label while the panel is open.

const SettingsUI = preload("res://scenes/ui/settings_ui.gd")

@onready var _start_xr: XRToolsStartXR = get_node_or_null("StartXR")
@onready var _tracking_provider: Node = $TrackingProvider
@onready var _tcp_handler: Node = $TcpHandler
@onready var _discovery: Node = $Discovery
@onready var _robot_view: Node = $XROrigin3D/RobotView
@onready var _settings_panel: Node3D = $XROrigin3D/XRCamera3D/SettingsPanel
@onready var _settings_button: Node3D = $XROrigin3D/XRCamera3D/SettingsButton

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

## Inner 2D Control instance loaded inside the SettingsPanel's
## Viewport2DIn3D. Lazily fetched in _on_xr_started after the
## Viewport2DIn3D has had a frame to spawn its scene.
var _settings_ui: Control = null
var _settings_button_ui: Control = null

## Selected by the user in the Settings UI; used as a hint until the
## DeviceDescriptor arrives and overrides it.
var _user_robot_type_hint: String = "robot_arm"

var _xr_started: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	_configure_passthrough()
	_create_v2_nodes()

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

	# Start discovery scanning (background — no longer surfaced in the UI,
	# but kept running so we can react to robot_lost and so future UI
	# affordances can re-introduce a "pick from discovered" dropdown).
	_discovery.start_scan()

	# Initial UI state: BOTH panel and button hidden. Discovery has 3s to
	# find a robot; the launch decision in `_finalize_launch` will reveal
	# either the panel (if the user needs to pick / fill IP) or the
	# floating button (if we auto-connect successfully). Done after the
	# Viewport2DIn3D scenes have spawned (`_wire_settings_ui` is deferred
	# to `_on_xr_started`).
	_settings_panel.visible = false
	_settings_button.visible = false

	# Apply persisted video-mode immediately so RobotView starts in the
	# user's preferred orientation (face-locked vs world-locked) without
	# waiting for a fresh OK press.
	var persisted: Dictionary = SettingsUI.load_settings()
	_user_robot_type_hint = persisted.get("robot_type", "robot_arm")
	if _robot_view:
		_robot_view.follow_camera = bool(persisted.get("video_face_locked", true))

	print("[Operator] Main scene initialized (UI hidden — awaiting discovery)")


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


# --- Settings UI wiring (deferred until Viewport2DIn3D has spawned scene) -----

func _wire_settings_ui() -> void:
	# Viewport2DIn3D.get_scene_instance() returns the root Control of the
	# inner 2D scene. It's null on the first frame after Viewport2DIn3D
	# itself is _ready; we defer the lookup until xr_started.
	if _settings_panel and _settings_panel.has_method("get_scene_instance"):
		_settings_ui = _settings_panel.get_scene_instance() as Control
	if _settings_button and _settings_button.has_method("get_scene_instance"):
		_settings_button_ui = _settings_button.get_scene_instance() as Control

	if _settings_ui and _settings_ui.has_signal("settings_applied"):
		_settings_ui.settings_applied.connect(_on_settings_applied)
		if _settings_ui.has_signal("close_requested"):
			_settings_ui.close_requested.connect(_on_settings_close_requested)
	else:
		push_warning("[Operator] SettingsPanel inner UI not ready — falling back to defaults")
	if _settings_button_ui and _settings_button_ui.has_signal("pressed"):
		_settings_button_ui.pressed.connect(_on_settings_button_pressed)


# --- XR lifecycle -------------------------------------------------------------

func _on_xr_started() -> void:
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

	# Wait for Viewport2DIn3D to spawn its inner `scene`. One process_frame
	# is enough on the desktop but Pico's first few frames are noisy
	# (XR session begin, swapchains, etc.) and get_scene_instance() can
	# return null for several frames. Poll up to ~1 s, bail out otherwise.
	for i in range(60):
		await get_tree().process_frame
		var panel_ready: bool = _settings_panel.has_method("get_scene_instance") \
				and _settings_panel.get_scene_instance() != null
		var button_ready: bool = _settings_button.has_method("get_scene_instance") \
				and _settings_button.get_scene_instance() != null
		if panel_ready and button_ready:
			print("[Operator] Viewport2DIn3D scenes ready after %d frame(s)" % (i + 1))
			break
	_wire_settings_ui()
	_begin_launch_window()


func _on_xr_failed() -> void:
	_set_status("XR Failed to Start")


func _configure_passthrough() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.transparent_bg = true
		var world := viewport.get_world_3d()
		if world and world.environment:
			world.environment.background_mode = Environment.BG_CLEAR_COLOR
			world.environment.background_color = Color(0, 0, 0, 0)

	if _start_xr and _start_xr.xr_interface:
		_start_xr.xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND


# --- Settings flow ------------------------------------------------------------

## Called by SettingsUI when the user presses OK.
## Q1 / Q2 answer: A + A — save + auto-connect; robot_type is a hint
## that the descriptor will override on handshake.
## show_on_launch is persisted only; we don't act on it during this run.
func _on_settings_applied(ip: String, port: int, robot_type: String, video_face_locked: bool, show_on_launch: bool) -> void:
	print("[Operator] Settings applied: ip=%s port=%d type=%s face_locked=%s show_on_launch=%s" % [
		ip, port, robot_type, video_face_locked, show_on_launch,
	])
	_user_robot_type_hint = robot_type

	# Apply video window mode immediately.
	if _robot_view:
		_robot_view.follow_camera = video_face_locked

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


## "Close" button on the panel: just hide it (no connect) and re-show the
## floating ⚙ button so the user can reopen later.
func _on_settings_close_requested() -> void:
	_hide_settings_panel()


func _show_settings_panel() -> void:
	# Re-push the latest discovery snapshot every time we open the panel —
	# robots may have appeared / disappeared while it was closed.
	_push_discovery_to_settings_ui()
	_settings_panel.visible = true
	_settings_button.visible = false


func _hide_settings_panel() -> void:
	_settings_panel.visible = false
	_settings_button.visible = true


# --- Launch decision (D: hybrid auto-discover) -------------------------------
#
# Both the panel and the floating button start hidden. We give discovery a 3s
# window to find robot(s), then pick one of:
#
#   show_on_launch == true   → always show panel
#   0 robots                 → show panel (manual fallback, status hints why)
#   1 robot == last_used_ip  → silent auto-connect, no panel
#   1 robot, last_used_ip is loopback default → silent auto-connect
#   1 robot, different IP    → show panel pre-filled with the new IP
#   N robots                 → show panel with the dropdown populated
#
# `last_used_ip` lives in user://settings.cfg. The robot agent broadcasts on
# 255.255.255.255:63900 every 3s, so a 3s window catches one beacon under
# normal conditions.

const _LAUNCH_DISCOVERY_WINDOW_SEC: float = 3.0


func _begin_launch_window() -> void:
	print("[Operator] Discovery window started (%.1fs)" % _LAUNCH_DISCOVERY_WINDOW_SEC)
	get_tree().create_timer(_LAUNCH_DISCOVERY_WINDOW_SEC).timeout.connect(_finalize_launch)


func _finalize_launch() -> void:
	var persisted: Dictionary = SettingsUI.load_settings()
	var show_on_launch: bool = bool(persisted.get("show_on_launch", false))
	var last_ip: String = String(persisted.get("ip", ""))
	var n_robots: int = _known_robots.size()

	print("[Operator] Launch decision: known=%d show_on_launch=%s last_ip=%s" % [
		n_robots, show_on_launch, last_ip,
	])

	if show_on_launch:
		_show_settings_panel_with_status("Show-on-launch enabled")
		return

	if n_robots == 0:
		_show_settings_panel_with_status("No robots discovered — check WiFi or enter IP manually")
		return

	# Try to match last-used IP first — that's the "silent auto-connect" case.
	if n_robots == 1:
		var only_ip := String(_known_robots.keys()[0])
		var only_info: Dictionary = _known_robots[only_ip]
		if only_ip == last_ip or _is_loopback_host(last_ip):
			_auto_connect_to_discovered(only_ip, int(only_info.get("pose_port", 63901)), only_info)
			return
		# Single robot but it's not the one we used before — surface it for confirmation.
		_show_settings_panel_with_status("Found robot @ %s — confirm to connect" % only_ip)
		return

	# Multiple robots. If one matches last_ip, the panel will pre-select it
	# (set_discovery_state honors `prefer_ip`).
	_show_settings_panel_with_status("%d robots found — pick one" % n_robots)


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
	_user_robot_type_hint = String(info.get("device_type", persisted.get("robot_type", "robot_arm")))

	_settings_panel.visible = false
	_settings_button.visible = true
	print("[Operator] Auto-connecting to discovered robot @ %s:%d" % [ip, port])
	_connect_to_robot(ip, port)


func _show_settings_panel_with_status(text: String) -> void:
	_push_discovery_to_settings_ui()
	_settings_panel.visible = true
	_settings_button.visible = false
	if _settings_ui and _settings_ui.has_method("set_status"):
		_settings_ui.set_status(text)


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
	_set_status("Connecting to %s:%d..." % [ip, port])
	_tcp_handler.connect_to_robot(ip, port)


func _on_connected() -> void:
	_set_status("Connected — handshake…")
	_session.on_connected()
	_connect_video_stream(_tcp_handler.get_host())
	if _clock_sync:
		_clock_sync.start()


func _on_disconnected() -> void:
	_set_status("Disconnected")
	_command_sender.set_sending(false)
	_video_tcp_handler.disconnect_from_robot()
	_video_udp_handler.disconnect_from_robot()
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()
	_session.on_disconnected()
	if _clock_sync:
		_clock_sync.stop()


func _on_connection_failed(reason: String) -> void:
	_set_status("Connection failed: %s" % reason)


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
	var device_name: String = descriptor.get("device", {}).get("name", "Unknown")
	var device_type: String = descriptor.get("device", {}).get("type", "unknown")
	_set_status("Driver active: %s (%s)" % [device_name, device_type])
	if device_type != _user_robot_type_hint:
		print("[Operator] Robot type hint (%s) differs from descriptor (%s) — descriptor wins" % [
			_user_robot_type_hint, device_type,
		])
	_command_sender.configure_for_device(descriptor)
	_command_sender.set_sending(true)
	_configure_robot_video_stream(descriptor)
	# [issue 005 / item 1] After the descriptor arrives we now know
	# whether the robot is offering UDP. Re-call `_connect_video_stream`
	# so we can upgrade to UDP if the descriptor advertises it.
	if _tcp_handler.is_connected_to_robot():
		_connect_video_stream(_tcp_handler.get_host())


func _on_device_disconnected() -> void:
	_command_sender.set_sending(false)
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

	if transport == "udp":
		print("[Operator] Connecting video stream (UDP) to %s:%d" % [ip, udp_port])
		_active_video_transport = "udp"
		_configure_robot_video_stream({})
		_video_udp_handler.connect_to_video_stream(ip, udp_port)
		if _robot_view and _robot_view.has_method("set_packet_source"):
			_robot_view.set_packet_source(_video_udp_handler)
	else:
		print("[Operator] Connecting video stream (TCP) to %s:%d" % [ip, tcp_port])
		_active_video_transport = "tcp"
		_configure_robot_video_stream({})
		_video_tcp_handler.connect_to_video_stream(ip, tcp_port)
		if _robot_view and _robot_view.has_method("set_packet_source"):
			_robot_view.set_packet_source(_video_tcp_handler)
