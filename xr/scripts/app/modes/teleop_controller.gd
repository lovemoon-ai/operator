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
const TeleopControllerPanelScript = preload("res://scripts/ui/teleop_controller_panel.gd")

const SETTINGS_PANEL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const SETTINGS_BUTTON_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18, -0.5))
const TELEOP_CONTROLLER_OVERLAY_OFFSET := Transform3D.IDENTITY

@onready var _start_xr: XRToolsStartXR = get_node_or_null("StartXR")
@onready var _origin: XROrigin3D = $XROrigin3D
@onready var _camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var _left_controller: XRController3D = $XROrigin3D/LeftController
@onready var _right_controller: XRController3D = $XROrigin3D/RightController

# Axis overlay showing each arm's true control directions at the hand driving
# it. A dual-arm rig runs two arms at once from two controllers, so this is
# per-hand state: one gizmo per hand, each with its OWN control frame and mirror
# convention (the two SO-101 arms are configured with opposite `mirror`). A
# single-arm rig only ever populates the driving hand's slot.
const ControlFrameGizmoScript = preload("res://scripts/ui/control_frame_gizmo.gd")
const EEPoseTrajectoryScript = preload("res://scripts/ui/ee_pose_trajectory.gd")
const HAND_LEFT := 0
const HAND_RIGHT := 1
var _control_frame_gizmos := {}  # hand -> Node3D
var _control_frame := {HAND_LEFT: Quaternion.IDENTITY, HAND_RIGHT: Quaternion.IDENTITY}
var _control_frame_valid := {HAND_LEFT: false, HAND_RIGHT: false}
var _control_frame_mirror := {HAND_LEFT: true, HAND_RIGHT: true}
var _ee_pose_trajectory: EEPoseTrajectory
@onready var _tracking_provider: Node = $TrackingProvider
@onready var _tcp_handler: Node = $TcpHandler
@onready var _discovery: Node = $Discovery
@onready var _robot_view: Node = $XROrigin3D/RobotView

## v2 nodes (created programmatically)
var _session: Session
## WP5: teleop command emission goes through RobotControlSink (sinks/
## robot_control). The sink wraps the scene-owned CommandSender by
## composition — wire JSON, 72 Hz rate, enable prints all unchanged.
var _robot_control_sink: RobotControlSink
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
var _teleop_controller_panel: Node3D
# True while the settings panel is open: teleop is suspended — no commands
# stream to the robot and the controller overlay is hidden — so the panel
# owns the controllers exclusively.
var _teleop_suspended := false

var _xr_started: bool = false
var _launch_window_active: bool = false
var _launch_window_token: int = 0

# --- Synthetic (headless CI) teleop -------------------------------------------
# When launched with `operator.teleop.synthetic=true`, the OpenXR-backed
# TrackingProvider is swapped for a SyntheticTeleopSource that plays a canned
# right-controller trajectory, the client auto-connects (directly if a host is
# given, else via discovery), drives the REAL command path for a bounded window,
# self-asserts the arm moved via real telemetry, and quits with an exit code —
# no headset, no operator. A normal launch never sets the flag, so this is inert.
const SyntheticTeleopSourceScript = preload("res://scripts/xr/synthetic_teleop_source.gd")
# GodotApp.java surfaces these intent extras as `--kebab value` user args (the
# same convention as --operator-mode / --mujoco-duration), not `key=value`.
const SYNTH_KEY_ENABLE := "--operator-teleop-synthetic"
const SYNTH_KEY_DURATION := "--operator-teleop-duration"
const SYNTH_KEY_HOST := "--operator-teleop-host"
const SYNTH_KEY_PORT := "--operator-teleop-port"
const SYNTH_DEFAULT_DURATION := 25.0
const SYNTH_DEFAULT_PORT := 63901
## Minimum peak joint excursion (deg) that counts as "the arm tracked".
const SYNTH_MIN_JOINT_DELTA_DEG := 1.0
## Fail if the descriptor handshake (→ engage) has not happened this long after
## the autopilot starts driving the connection.
const SYNTH_CONNECT_TIMEOUT_SEC := 45.0

var _synthetic := false
var _synth_source: Node = null
var _synth_duration := SYNTH_DEFAULT_DURATION
var _synth_host := ""
var _synth_port := SYNTH_DEFAULT_PORT
var _synth_engaged := false
var _synth_finished := false
var _synth_telemetry_count := 0
var _synth_first_joints: Array = []
var _synth_last_joints: Array = []
var _synth_max_delta := 0.0
# Dual-arm run. Set from the descriptor device type at engage time, so the same
# synthetic launch drives one or two arms depending on the robot on the other
# end -- no separate flag. When dual, the PASS bar is that BOTH arms tracked,
# asserted from the per-side `left_joint_angles` / `right_joint_angles`
# telemetry, so a run where only the right arm moved cannot pass.
var _synth_dual := false
var _synth_left_first: Array = []
var _synth_right_first: Array = []
var _synth_left_max_delta := 0.0
var _synth_right_max_delta := 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# Must run before the command sender is wired (below) so it captures the
	# synthetic provider rather than the OpenXR one.
	_maybe_setup_synthetic()

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
	if _robot_view:
		_robot_view.follow_camera = bool(persisted.get("video_face_locked", true))
		# `show_video_panel` defaults to false: a fresh install should NOT
		# pop a placeholder quad in front of the operator before any robot
		# has sent a frame. The user opts in via the Settings panel toggle.
		if _robot_view.has_method("set_show_video_panel"):
			_robot_view.set_show_video_panel(bool(persisted.get("show_video_panel", false)))
	if _ee_pose_trajectory:
		_ee_pose_trajectory.set_enabled(bool(persisted.get("show_operation_trajectory", false)))

	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		call_deferred("_on_xr_started")

	print("[Operator] Main scene initialized (UI hidden — awaiting XR)")

	# Networking + command emission run in _physics_process regardless of the XR
	# session, so the autopilot does not wait on a headset/OpenXR to come up.
	if _synthetic:
		call_deferred("_start_synthetic_autopilot")


func _process(_delta: float) -> void:
	if _synthetic:
		_tick_synthetic()
	if _camera:
		if _settings_panel:
			_settings_panel.transform = _camera.transform * SETTINGS_PANEL_OFFSET
		if _settings_button:
			_settings_button.transform = _camera.transform * SETTINGS_BUTTON_OFFSET
	_apply_settings_input_indicator(_current_interaction_mode())
	_update_teleop_controller_panel()
	# Position refreshes every frame so the gizmo tracks the controller smoothly;
	# its orientation only changes when telemetry reports a new captured frame.
	_update_control_frame_gizmo()


# Push the detected input source down to the teleop settings panel so the
# title-bar indicator (defined on BaseSettingsPanel) stays in sync. Cheap
# because the panel only repaints when the mode actually changes.
var _last_indicator_mode := ""
func _apply_settings_input_indicator(mode: String) -> void:
	if _settings_ui == null or not _settings_ui.has_method("set_input_mode_indicator"):
		return
	if mode == _last_indicator_mode:
		return
	_last_indicator_mode = mode
	_settings_ui.call("set_input_mode_indicator", mode)


func _bind_operator_interaction() -> void:
	var interaction := _operator_interaction()
	if interaction == null:
		return
	if interaction.has_signal("input_mode_changed") \
			and not interaction.is_connected("input_mode_changed", Callable(self, "_on_global_interaction_mode_changed")):
		interaction.connect("input_mode_changed", Callable(self, "_on_global_interaction_mode_changed"))
	_apply_settings_input_indicator(_current_interaction_mode())


func _operator_interaction() -> Node:
	if get_tree() == null:
		return null
	return get_tree().root.get_node_or_null("OperatorInteraction")


func _current_interaction_mode() -> String:
	var interaction := _operator_interaction()
	if interaction != null and interaction.has_method("get_current_mode"):
		return str(interaction.call("get_current_mode"))
	return "controllers"


func _release_global_interaction_pointer() -> void:
	var interaction := _operator_interaction()
	if interaction != null and interaction.has_method("release_pointer"):
		interaction.call("release_pointer")


func _on_global_interaction_mode_changed(mode: String) -> void:
	_apply_settings_input_indicator(mode)


func _create_v2_nodes() -> void:
	_session = Session.new()
	_session.name = "Session"
	_session.tcp_handler = _tcp_handler
	add_child(_session)

	# WP6: command emission stack built by the teleop composition root
	# (CommandSender Node + RobotControlSink wrapper, behavior unchanged).
	var teleop := TeleopComposition.build(self)
	_command_sender = teleop.get("command_sender")
	_robot_control_sink = teleop.get("robot_control_sink")
	_ee_pose_trajectory = EEPoseTrajectoryScript.new()
	_ee_pose_trajectory.name = "EEPoseTrajectory"
	add_child(_ee_pose_trajectory)
	_command_sender.command_sent.connect(_on_command_sent)

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

	# Axis gizmos, in origin space like the panel: each one's global transform is
	# driven every frame from its hand's controller. One per hand so a dual-arm
	# rig can show both live arms at once; on a single-arm rig only the driving
	# hand's gizmo is ever made visible.
	for hand in [HAND_LEFT, HAND_RIGHT]:
		var gizmo: Node3D = ControlFrameGizmoScript.new()
		gizmo.name = "ControlFrameGizmo%s" % ("Left" if hand == HAND_LEFT else "Right")
		_origin.add_child(gizmo)
		_control_frame_gizmos[hand] = gizmo

	_bind_operator_interaction()


func _update_teleop_controller_panel() -> void:
	if _teleop_controller_panel == null:
		return
	if _teleop_suspended:
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

	# Synthetic runs own their own connection lifecycle and must never pop the
	# discovery/settings panel (which would suspend teleop and block sending).
	if not _synthetic:
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
## endpoint. The robot type is not a client setting — the DeviceDescriptor
## received on handshake defines what the client sends and displays.
func _on_settings_applied(
	ip: String,
	port: int,
	video_face_locked: bool,
	show_video_panel: bool,
	show_operation_trajectory: bool,
	show_on_launch: bool
) -> void:
	print("[Operator] Settings applied: ip=%s port=%d face_locked=%s show_video=%s show_trajectory=%s show_on_launch=%s" % [
		ip,
		port,
		video_face_locked,
		show_video_panel,
		show_operation_trajectory,
		show_on_launch,
	])
	_cancel_launch_window()

	# Apply video window mode immediately.
	if _robot_view:
		_robot_view.follow_camera = video_face_locked
		if _robot_view.has_method("set_show_video_panel"):
			_robot_view.set_show_video_panel(show_video_panel)
	if _ee_pose_trajectory:
		_ee_pose_trajectory.set_enabled(show_operation_trajectory)

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
	if _robot_control_sink:
		_robot_control_sink.set_sending(false)
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


## Pause/resume teleop around the settings panel. While suspended no
## DeviceCommands stream to the robot (the robot-side deadman/watchdog holds
## the arm) and the controller overlay hides, so panel interaction can't
## move the arm or show stale grip/trigger hints.
func _set_teleop_suspended(suspended: bool) -> void:
	if _teleop_suspended == suspended:
		return
	_teleop_suspended = suspended
	if _robot_control_sink:
		if suspended:
			_robot_control_sink.set_sending(false)
		elif _tcp_handler and _tcp_handler.is_connected_to_robot():
			_robot_control_sink.set_sending(true)
	if suspended and _ee_pose_trajectory:
		# Do not bridge the hand motion performed while settings owns the
		# controllers with one long segment when teleop resumes.
		_ee_pose_trajectory.break_all()
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_suspended"):
		_teleop_controller_panel.call("set_suspended", suspended)


func _show_settings_panel() -> void:
	_set_teleop_suspended(true)
	_release_global_interaction_pointer()
	# Re-push the latest discovery snapshot every time we open the panel —
	# robots may have appeared / disappeared while it was closed.
	_push_discovery_to_settings_ui()
	if _settings_ui and _settings_ui.has_method("set_discovering"):
		_settings_ui.set_discovering(false)
	if _settings_button and _settings_button.has_method("clear_pointer"):
		_settings_button.clear_pointer()
	if _settings_panel and _settings_panel.has_method("set_feedback_input_mode"):
		var mode := _current_interaction_mode()
		_settings_panel.set_feedback_input_mode(mode, _right_controller if mode == "controllers" else null)
	if _settings_panel and _settings_panel.has_method("open"):
		_settings_panel.open()
	else:
		_settings_panel.visible = true
	_settings_button.visible = false


func _hide_settings_panel() -> void:
	_release_global_interaction_pointer()
	if _settings_panel and _settings_panel.has_method("close"):
		_settings_panel.close()
	else:
		_settings_panel.visible = false
	_settings_button.visible = true
	_set_teleop_suspended(false)


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
	# video mode so the auto-path matches what OK would do.
	var persisted: Dictionary = SettingsUI.load_settings()
	if _robot_view:
		_robot_view.follow_camera = bool(persisted.get("video_face_locked", true))
		if _robot_view.has_method("set_show_video_panel"):
			_robot_view.set_show_video_panel(bool(persisted.get("show_video_panel", false)))
	if _settings_ui and _settings_ui.has_method("set_discovering"):
		_settings_ui.set_discovering(false)

	if _settings_panel and _settings_panel.has_method("close"):
		_settings_panel.close()
	else:
		_settings_panel.visible = false
	_settings_button.visible = true
	_set_teleop_suspended(false)
	print("[Operator] Auto-connecting to discovered robot @ %s:%d" % [ip, port])
	_connect_to_robot(ip, port)


func _show_settings_panel_with_status(text: String) -> void:
	_set_teleop_suspended(true)
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
	_set_teleop_suspended(true)
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


## Translate this controller's IP-keyed `_known_robots` into the name-keyed
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

func _on_command_sent(command: Dictionary) -> void:
	if _ee_pose_trajectory == null:
		return
	_ee_pose_trajectory.record_command(
		command,
		_driving_hand(),
		{
			HAND_LEFT: _is_deadman_held(HAND_LEFT),
			HAND_RIGHT: _is_deadman_held(HAND_RIGHT),
		}
	)


func _connect_to_robot(ip: String, port: int) -> void:
	if _ee_pose_trajectory:
		_ee_pose_trajectory.clear()
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
	_robot_control_sink.set_sending(false)
	if _ee_pose_trajectory:
		_ee_pose_trajectory.clear()
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
	print("[Operator] Connected to %s (type=%s per descriptor)" % [device_name, device_type])
	_robot_control_sink.configure_for_device(descriptor)
	if _ee_pose_trajectory:
		_ee_pose_trajectory.configure_for_device(descriptor)
	# If the settings panel is up, stay paused; _set_teleop_suspended(false)
	# re-enables sending when it closes.
	if not _teleop_suspended:
		_robot_control_sink.set_sending(true)
	# Synthetic: the descriptor has landed and sending is on — start the canned
	# operator trajectory now so the robot seeds its retarget reference cleanly.
	if _synthetic and _synth_source and not _synth_engaged:
		# The robot's descriptor decides one arm vs two. Drive both controllers
		# and raise the verdict bar to "both arms moved" when it is a dual rig.
		_synth_dual = device_type.to_lower().contains("dual")
		if _synth_source.has_method("set_dual"):
			_synth_source.call("set_dual", _synth_dual)
		_synth_engaged = true
		_synth_source.call("engage", _synth_duration)
		print("[TeleopSynthetic] descriptor device=%s dual=%s — engaging synthetic operator" % [
			device_type, str(_synth_dual),
		])
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
	_robot_control_sink.set_sending(false)
	if _ee_pose_trajectory:
		_ee_pose_trajectory.configure_for_device({})
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()


func _on_telemetry_received(_data: Dictionary) -> void:
	# Telemetry display panel was removed with the old DynamicHUD. Future
	# work: surface telemetry as an optional overlay or a Phase-2 panel
	# section. For now we just drop the data so the signal stays connected
	# (Session still parses telemetry frames so consumer can subscribe).
	_capture_control_frame(_data)
	if _synthetic:
		_synth_capture_telemetry(_data)


## Latch each arm's control frame for its axis gizmo.
##
## `operator_frame` is only present while the deadman is held -- the adapter
## clears it on release -- so its absence is the authoritative "not driving"
## signal. Orientation only changes when the operator re-squeezes, so latching it
## here at telemetry rate (~10Hz) is plenty; the gizmo's POSITION is refreshed
## every frame in `_update_control_frame_gizmo`.
##
## Two telemetry layouts are accepted. A dual-arm adapter publishes a prefixed
## block per side (`left_operator_frame`, `right_pose_mirror`, ...) because its
## arms hold independent frames and opposite mirror conventions. A single-arm
## adapter publishes one unprefixed pair, which belongs to whichever hand is
## driving. We detect dual by `*_pose_mirror`, not `*_operator_frame`: mirror is
## published unconditionally, whereas the frame vanishes on deadman release --
## keying off the frame would make a dual rig look single-arm the moment both
## operators let go.
func _capture_control_frame(data: Dictionary) -> void:
	var values: Dictionary = data.get("values", {})
	var dual := values.has("left_pose_mirror") or values.has("right_pose_mirror")
	for hand in [HAND_LEFT, HAND_RIGHT]:
		if dual:
			var prefix := "left_" if hand == HAND_LEFT else "right_"
			_capture_control_frame_for_hand(
				values, hand, prefix + "operator_frame", prefix + "pose_mirror"
			)
		elif hand == _driving_hand():
			_capture_control_frame_for_hand(values, hand, "operator_frame", "pose_mirror")
		else:
			_control_frame_valid[hand] = false


func _capture_control_frame_for_hand(
	values: Dictionary, hand: int, frame_key: String, mirror_key: String
) -> void:
	var frame_any: Variant = values.get(frame_key, null)
	if frame_any is Array and (frame_any as Array).size() == 4:
		var f: Array = frame_any
		_control_frame[hand] = Quaternion(
			float(f[0]), float(f[1]), float(f[2]), float(f[3])
		).normalized()
		_control_frame_valid[hand] = true
	else:
		_control_frame_valid[hand] = false
	_control_frame_mirror[hand] = bool(values.get(mirror_key, true))


func _update_control_frame_gizmo() -> void:
	for hand in [HAND_LEFT, HAND_RIGHT]:
		_update_control_frame_gizmo_for_hand(hand)


func _update_control_frame_gizmo_for_hand(hand: int) -> void:
	var gizmo: Node3D = _control_frame_gizmos.get(hand, null)
	if gizmo == null:
		return
	# Hide the moment the operator lets go. We use the LOCAL deadman state rather
	# than waiting for the next telemetry frame to drop `operator_frame`, so the
	# gizmo disappears with the release instead of up to a telemetry period later.
	# The deadman is queried PER HAND so that on a dual rig releasing one grip
	# drops only that arm's overlay while the other stays live.
	if not bool(_control_frame_valid.get(hand, false)) or not _is_deadman_held(hand):
		gizmo.visible = false
		return
	var controller := _controller_for_hand(hand)
	if controller == null or not controller.get_is_active():
		gizmo.visible = false
		return
	gizmo.visible = true
	gizmo.apply(
		controller.global_transform.origin,
		_control_frame.get(hand, Quaternion.IDENTITY),
		bool(_control_frame_mirror.get(hand, true)),
	)


## ControlMode owns both the driving-hand latch and the deadman hysteresis, so
## the gizmo asks it rather than re-deriving either. Re-thresholding the raw grip
## here duplicated the constants AND cost an extra controller-input read every
## rendered frame -- the same per-frame cost that had to be stripped out of this
## file after it measurably cut the delivered command rate.
func _active_control_mode():
	if _command_sender == null:
		return null
	return _command_sender.control_mode


## Which hand currently commands the arm on a single-arm rig. Meaningless for a
## dual rig, where both hands command their own arm.
func _driving_hand() -> int:
	var mode = _active_control_mode()
	if mode and mode.has_method("get_driving_hand"):
		return int(mode.get_driving_hand())
	return HAND_RIGHT


func _controller_for_hand(hand: int) -> XRController3D:
	return _left_controller if hand == HAND_LEFT else _right_controller


func _is_deadman_held(hand: int) -> bool:
	var mode = _active_control_mode()
	if mode == null:
		return false
	# Prefer the per-hand query. The any-target fallback reports true for both
	# hands once either grip is squeezed, which is right for a single-arm rig but
	# would leave a dual rig's idle overlay drawn as if that arm were live.
	if mode.has_method("is_deadman_engaged_for_hand"):
		return bool(mode.is_deadman_engaged_for_hand(hand))
	if mode.has_method("is_deadman_engaged"):
		return bool(mode.is_deadman_engaged())
	return false


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


# --- Synthetic (headless CI) autopilot ----------------------------------------

## Read an intent-extra / cmdline value. Android `--es KEY VAL` surfaces as the
## token `KEY=VAL`; the `KEY VAL` pair form is also accepted. Mirrors the
## convention used by mode_select and the mujoco device test.
func _synthetic_arg(key: String, fallback: String) -> String:
	var args: Array = []
	args.append_array(OS.get_cmdline_user_args())
	args.append_array(OS.get_cmdline_args())
	for i in range(args.size()):
		var arg := String(args[i]).strip_edges()
		if arg == key and i + 1 < args.size():
			return String(args[i + 1]).strip_edges()
		if arg.begins_with(key + "="):
			return arg.substr(key.length() + 1).strip_edges()
	return fallback


func _synthetic_flag_set() -> bool:
	var raw := _synthetic_arg(SYNTH_KEY_ENABLE, "").to_lower()
	return raw == "1" or raw == "true" or raw == "yes" or raw == "on"


## Swap the OpenXR TrackingProvider for the scripted source. Runs before the
## command sender is wired so it captures the synthetic provider.
func _maybe_setup_synthetic() -> void:
	if not _synthetic_flag_set():
		return
	_synthetic = true
	_synth_duration = float(_synthetic_arg(SYNTH_KEY_DURATION, str(SYNTH_DEFAULT_DURATION)))
	_synth_host = _synthetic_arg(SYNTH_KEY_HOST, "")
	_synth_port = int(_synthetic_arg(SYNTH_KEY_PORT, str(SYNTH_DEFAULT_PORT)))

	var src: Node = SyntheticTeleopSourceScript.new()
	src.name = "SyntheticTeleopSource"
	add_child(src)
	# Retire the real XR-backed provider so it does no OpenXR work.
	if is_instance_valid(_tracking_provider):
		_tracking_provider.queue_free()
	_tracking_provider = src
	_synth_source = src
	print("[TeleopSynthetic] started duration=%.1fs host=%s port=%d" % [
		_synth_duration, ("<discovery>" if _synth_host.is_empty() else _synth_host), _synth_port,
	])


func _start_synthetic_autopilot() -> void:
	if not _synthetic:
		return
	if not _synth_host.is_empty():
		print("[TeleopSynthetic] direct-connecting to %s:%d" % [_synth_host, _synth_port])
		_connect_to_robot(_synth_host, _synth_port)
	else:
		print("[TeleopSynthetic] no host set — relying on discovery + auto-connect")
	# Watchdog: if the descriptor handshake never engages the source, fail loud
	# instead of hanging until the outer CI timeout.
	get_tree().create_timer(SYNTH_CONNECT_TIMEOUT_SEC).timeout.connect(_synth_connect_watchdog)


func _synth_connect_watchdog() -> void:
	if _synth_finished or _synth_engaged:
		return
	_finish_synthetic("never engaged (no descriptor handshake within %ds)" % int(SYNTH_CONNECT_TIMEOUT_SEC))


func _tick_synthetic() -> void:
	if _synth_finished or not _synth_engaged or _synth_source == null:
		return
	var elapsed := float(_synth_source.call("elapsed"))
	if elapsed >= _synth_duration:
		_finish_synthetic("")


func _synth_capture_telemetry(data: Dictionary) -> void:
	var values: Dictionary = data.get("values", {})
	var joints_any: Variant = values.get("joint_angles", [])
	if not (joints_any is Array) or (joints_any as Array).is_empty():
		return
	var joints: Array = joints_any
	_synth_telemetry_count += 1
	_synth_last_joints = joints.duplicate()
	# Baseline = first joints seen AFTER the deadman engaged (so the home slew
	# does not count as "tracking").
	if _synth_first_joints.is_empty():
		if not _synth_engaged:
			return
		_synth_first_joints = joints.duplicate()
		print("[TeleopSynthetic] telemetry baseline joints=%s" % JSON.stringify(joints))
		if _synth_dual:
			_synth_capture_side_baseline(values)
		return
	_synth_max_delta = maxf(_synth_max_delta, _synth_joint_delta(_synth_first_joints, joints))
	if _synth_dual:
		_synth_capture_side_deltas(values)


## Latch each arm's first-seen (post-engage) joints so per-side motion is
## measured against the same baseline the combined check uses. Only the SIDE
## arrays gate a dual PASS; the combined array can hide a dead arm behind a
## live one.
func _synth_capture_side_baseline(values: Dictionary) -> void:
	var left: Variant = values.get("left_joint_angles", [])
	var right: Variant = values.get("right_joint_angles", [])
	if left is Array and not (left as Array).is_empty():
		_synth_left_first = (left as Array).duplicate()
	if right is Array and not (right as Array).is_empty():
		_synth_right_first = (right as Array).duplicate()


func _synth_capture_side_deltas(values: Dictionary) -> void:
	var left: Variant = values.get("left_joint_angles", [])
	var right: Variant = values.get("right_joint_angles", [])
	if left is Array and not _synth_left_first.is_empty():
		_synth_left_max_delta = maxf(
			_synth_left_max_delta, _synth_joint_delta(_synth_left_first, left)
		)
	if right is Array and not _synth_right_first.is_empty():
		_synth_right_max_delta = maxf(
			_synth_right_max_delta, _synth_joint_delta(_synth_right_first, right)
		)


func _synth_joint_delta(a: Array, b: Array) -> float:
	var n := mini(a.size(), b.size())
	var worst := 0.0
	for i in range(n):
		worst = maxf(worst, absf(float(a[i]) - float(b[i])))
	return worst


func _finish_synthetic(reason: String) -> void:
	if _synth_finished:
		return
	_synth_finished = true
	if _robot_control_sink:
		_robot_control_sink.set_sending(false)
	var connected: bool = _tcp_handler != null and _tcp_handler.is_connected_to_robot()
	# Single-arm: the combined delta is enough. Dual: require BOTH sides so a
	# stuck/uncommanded arm cannot ride the other's motion to a green.
	var moved: bool
	if _synth_dual:
		moved = _synth_left_max_delta >= SYNTH_MIN_JOINT_DELTA_DEG \
			and _synth_right_max_delta >= SYNTH_MIN_JOINT_DELTA_DEG
	else:
		moved = _synth_max_delta >= SYNTH_MIN_JOINT_DELTA_DEG
	print("[TeleopSynthetic] summary connected=%s engaged=%s dual=%s telemetry_frames=%d max_joint_delta_deg=%.3f left_delta=%.3f right_delta=%.3f first=%s last=%s" % [
		str(connected), str(_synth_engaged), str(_synth_dual), _synth_telemetry_count,
		_synth_max_delta, _synth_left_max_delta, _synth_right_max_delta,
		JSON.stringify(_synth_first_joints), JSON.stringify(_synth_last_joints),
	])
	if reason.is_empty() and connected and _synth_engaged and moved:
		if _synth_dual:
			print("[TeleopSynthetic] PASS both arms tracked synthetic operator (left=%.2f right=%.2f deg over %d frames)" % [
				_synth_left_max_delta, _synth_right_max_delta, _synth_telemetry_count,
			])
		else:
			print("[TeleopSynthetic] PASS arm tracked synthetic operator (max_joint_delta=%.2f deg over %d frames)" % [
				_synth_max_delta, _synth_telemetry_count,
			])
		_synth_quit(0)
	else:
		var why := reason
		if why.is_empty():
			if _synth_dual:
				why = "connected=%s engaged=%s moved=%s (left=%.2f right=%.2f, need >=%.2f deg on BOTH)" % [
					str(connected), str(_synth_engaged), str(moved),
					_synth_left_max_delta, _synth_right_max_delta, SYNTH_MIN_JOINT_DELTA_DEG,
				]
			else:
				why = "connected=%s engaged=%s moved=%s (max_delta=%.2f < %.2f deg)" % [
					str(connected), str(_synth_engaged), str(moved),
					_synth_max_delta, SYNTH_MIN_JOINT_DELTA_DEG,
				]
		push_error("[TeleopSynthetic] FAIL %s" % why)
		_synth_quit(2)


func _synth_quit(code: int) -> void:
	# Drop the deadman and the connection before quitting so the robot-side
	# watchdog safes the arm; the host script's trap de-energises regardless.
	if _tcp_handler and _tcp_handler.is_connected_to_robot():
		_tcp_handler.disconnect_from_robot()
	print("[TeleopSynthetic] exiting code=%d" % code)
	get_tree().quit(code)
