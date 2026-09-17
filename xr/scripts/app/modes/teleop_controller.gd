extends Node3D
## Main scene controller for Teleoperate-Anything.
## Initializes XR with passthrough. Outside Robot can use either the native v2
## session (Hello → DeviceDescriptor → DeviceCommand ↔ Telemetry) or the
## separate XRoboToolkit-compatible tracking stream.
##
## UI model:
##  - At launch, view-locked composition-layer SettingsPanel is visible if
##    discovery needs manual confirmation. The user chooses Inside Robot or
##    Outside Robot, fills only that target's settings, and presses OK.
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
const BodyPoseProviderScript = preload("res://scripts/robot_constraint/body_pose_provider.gd")
const BodyPoseDebugOverlayScript = preload(
	"res://scripts/robot_constraint/body_pose_debug_overlay.gd"
)
const ControllerShellScript := preload("res://scripts/blueprint/system_menu_host.gd")
const BlueprintRuntimeScript = preload(
	"res://scripts/blueprint/blueprint_runtime.gd"
)
const OUTSIDE_ROBOT_TARGET_PATH := "res://scripts/teleop/targets/outside_robot_target.gd"
const XROBOT_TOOLKIT_TARGET_PATH := "res://scripts/teleop/targets/xrobot_toolkit_target.gd"
const XROBOT_TOOLKIT_VIDEO_SESSION_PATH := (
	"res://scripts/compat/xrobot_toolkit/xrt_video_session.gd"
)
const XROBOT_TOOLKIT_DISCOVERY_PATH := (
	"res://scripts/compat/xrobot_toolkit/xrt_discovery.gd"
)
const XROBOT_TOOLKIT_DEVICE_TYPE := "xrobot_toolkit"
const INSIDE_ROBOT_TARGET_PATH := "res://scripts/teleop/targets/inside_robot_target.gd"

const VIDEO_PROTOCOL_OPERATOR := "operator_timed_h264"
const VIDEO_PROTOCOL_XROBOT_TOOLKIT := "xrobot_toolkit_fpv"
const VIDEO_TEST_FIRST_FRAME_TIMEOUT_SEC := 8.0

const SETTINGS_PANEL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const SETTINGS_BUTTON_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18, -0.5))
const VIDEO_PREVIEW_CLOSE_INSET := Vector2(0.13, 0.13)
const VIDEO_PREVIEW_CLOSE_Z_OFFSET := 0.04
const TELEOP_CONTROLLER_OVERLAY_OFFSET := Transform3D.IDENTITY
const DEFAULT_TELEMETRY_PORT := 63903
const TELEMETRY_PORT_OFFSET := 2
const TELEMETRY_RETRY_DELAY_SEC := 1.0
const REVO2_DEVICE_TYPE := "revo2_dual_hand"
const PASSTHROUGH_BACKGROUND_MODE := Environment.BG_COLOR
const BLUEPRINT_EXTERNAL_VIEW_IMPLEMENTATIONS := [
	"video_panel", "controller_help", "control_frame", "operation_trajectory"
]
const BLUEPRINT_EXTERNAL_VIEW_CONTRACTS := {
	"video_panel": {
		"properties": ["visible", "settings_label", "follow_camera", "distance"],
		"bindings": ["visible", "follow_camera"],
		"events": [],
	},
	"controller_help": {
		"properties": ["visible", "settings_label"],
		"bindings": ["visible"],
		"events": [],
	},
	"control_frame": {
		"properties": ["visible", "settings_label"],
		"bindings": ["visible"],
		"events": [],
	},
	"operation_trajectory": {
		"properties": ["visible", "settings_label"],
		"bindings": ["visible"],
		"events": [],
	},
}
const REVO2_HAND_CHANNELS := [
	"thumb_aux",
	"thumb_flex",
	"index_flex",
	"middle_flex",
	"ring_flex",
	"pinky_flex",
]

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
const DexterousHandFeedbackOverlayScript = preload(
	"res://scripts/ui/dexterous_hand_feedback_overlay.gd"
)
const DexterousHandTactileOverlayScript = preload(
	"res://scripts/ui/dexterous_hand_tactile_overlay.gd"
)
const HandControlIndicatorScript = preload(
	"res://scripts/ui/hand_control_indicator.gd"
)
const HAND_LEFT := 0
const HAND_RIGHT := 1
var _control_frame_gizmos := {}  # hand -> Node3D
var _control_frame := {HAND_LEFT: Quaternion.IDENTITY, HAND_RIGHT: Quaternion.IDENTITY}
var _control_frame_valid := {HAND_LEFT: false, HAND_RIGHT: false}
var _control_frame_mirror := {HAND_LEFT: true, HAND_RIGHT: true}
var _ee_pose_trajectory: EEPoseTrajectory
var _hand_feedback_overlay: DexterousHandFeedbackOverlay
var _hand_tactile_overlay: DexterousHandTactileOverlay
var _hand_control_indicators := {}
var _revo2_hand_runtime_enabled := false
var _revo2_hand_control_unlocked := false
@onready var _tracking_provider: Node = $TrackingProvider
@onready var _tcp_handler: Node = $TcpHandler
@onready var _discovery: Node = $Discovery
@onready var _robot_view: Node = $XROrigin3D/RobotView

## v2 nodes (created programmatically)
var _session: Session
var _blueprint_runtime: BlueprintRuntime
## WP5: teleop command emission goes through RobotControlSink (sinks/
## robot_control). The sink wraps the scene-owned CommandSender by
## composition — wire JSON, 72 Hz rate, enable prints all unchanged.
var _robot_control_sink: RobotControlSink
var _command_sender: CommandSender
## Raw atomic state publisher, enabled only when the descriptor advertises
## `xr_stream` (the embedded pyoperator SDK mode).
var _xr_state_sender: XrStateSender
## Dedicated telemetry connection. xr-bridge intentionally separates the
## command and telemetry sockets so slow UI consumers cannot delay commands.
var _telemetry_tcp_handler: TcpHandler
## TCP video handler — used when the descriptor selects "tcp" or as the
## fallback for "auto"-mode descriptors that didn't supply a UDP port.
var _video_tcp_handler: TcpHandler
## [issue 005 / item 1] UDP video handler. Created lazily in
## `_create_v2_nodes`; only `connect_to_video_stream` when the
## descriptor advertises `transport=udp` (or `transport=auto` plus a
## non-zero `udp_port`).
var _video_udp_handler: UdpVideoHandler
var _xrt_video_session: Node
var _active_video_transport: String = "tcp"  # "tcp" or "udp"
var _last_video_feed: Dictionary = {}
var _active_telemetry_port := DEFAULT_TELEMETRY_PORT
var _telemetry_retry_remaining := 0.0
var _clock_sync: RobotClockSync
## Discovery identity -> endpoint metadata. Identity includes the protocol so an
## Operator service and an XRoboToolkit RoboticsService may coexist on one host.
var _known_robots: Dictionary = {}
## Node listening for XRoboToolkit's own 1 Hz robot beacon. Separate port and
## separate wire format from `_discovery`, so it is a separate listener that
## merges into the same protocol-aware `_known_robots` map.
var _xrt_discovery: Node = null
var _outside_target: Node
var _xrt_target: Node
var _inside_target: Node
var _active_target: Node

var _settings_panel: Node3D
var _settings_button: Node3D
var _settings_ui: Node = null
var _teleop_controller_panel: Node3D
var _blueprint_external_view_visibility: Dictionary = {}
var _robot_authored_views_active := false
var _local_video_panel_distance := 3.0
var _control_frame_visualization_enabled := false
## "Show VR Pose" for a session that has no in-headset robot to stand next
## to. The Inside target builds its own skeleton anchored beside the robot;
## these two cover every other scope, where the toggle previously did
## nothing at all.
var _vr_pose_provider: Node
var _vr_pose_overlay: Node3D
## Main menu placement. View-locked (default) re-seats the panel in front of
## the head every frame; world-locked leaves it where it was opened.
var _menu_world_locked := false
## True while the settings page (the system menu) is open. The controller
## menu is a runtime menu and steps aside for it; Blueprint UI pauses too.
var _settings_menu_open := false
## Connect/Disconnect state and the outgoing frame rate it displays. Opening
## or closing the page does not touch either.
var _link_active := false
var _send_frame_count := 0
var _send_rate_elapsed := 0.0
var _manual_video_protocol := ""
var _manual_video_options: Dictionary = {}
var _video_test_active := false
var _video_test_generation := 0
# Teleop suspension gate: while set, DeviceCommand, XrStateFrame and
# XRoboToolkit Tracking are all disabled and the controller overlay is hidden.
# The settings page no longer sets it: the link and its streams stay live, and
# the page neutralises controller input through pointer capture instead (see
# TeleopSettingsPanel.captures_teleop_input), so only tests drive it today.
var _teleop_suspended := false
# Android lifecycle, tracked separately from _teleop_suspended: suspension is a
# local gate, while these two mean the headset itself is no longer driving.
# Only the XRoboToolkit stream carries this on the wire (appState.focus).
var _app_paused := false
var _app_unfocused := false
# Persisted from the active descriptor. SDK mode and robot-control mode are
# mutually exclusive across every suspend/resume transition.
var _sdk_mode := false

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
const TELEOP_KEY_HOST := "--operator-teleop-host"
const TELEOP_KEY_PORT := "--operator-teleop-port"
const TELEOP_KEY_PROTOCOL := "--operator-teleop-protocol"
const TELEOP_KEY_SHOW_VIDEO_PANEL := "--operator-teleop-show-video-panel"
const TELEOP_KEY_XROBOT_TOOLKIT_DEVICE_SN := "--operator-xrobot-toolkit-device-sn"
const TELEOP_KEY_PICO_BODY_CALIBRATE := "--operator-teleop-pico-body-calibrate"
## Inside Robot launch overrides. Inside is otherwise only reachable by hand in
## the headset, which leaves its startup — profile load, embodiment creation,
## solver binding — impossible to exercise or diagnose from a device test.
const TELEOP_KEY_SCOPE := "--operator-teleop-scope"
const TELEOP_KEY_PROFILE := "--operator-teleop-profile"
const TELEOP_KEY_BACKEND := "--operator-teleop-backend"
const SYNTH_DEFAULT_DURATION := 25.0
const SYNTH_DEFAULT_PORT := 63901
## Minimum peak joint excursion (deg) that counts as "the arm tracked".
const SYNTH_MIN_JOINT_DELTA_DEG := 1.0
## Fail if the descriptor handshake (→ engage) has not happened this long after
## the autopilot starts driving the connection.
const SYNTH_CONNECT_TIMEOUT_SEC := 45.0

var _synthetic := false
## Settings last applied by Connect or a launch override.
var _applied_options: Dictionary = {}
var _controller_shell: Node
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

	_telemetry_tcp_handler.connected_to_server.connect(_on_telemetry_connected)
	_telemetry_tcp_handler.disconnected_from_server.connect(_on_telemetry_disconnected)
	_telemetry_tcp_handler.connection_failed.connect(_on_telemetry_connection_failed)
	_telemetry_tcp_handler.command_received.connect(_on_telemetry_command_received)

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
	for controller in [_left_controller, _right_controller]:
		if controller != null:
			controller.button_pressed.connect(_on_video_test_exit_button_pressed)

	_discovery.robot_found.connect(_on_robot_found)
	_discovery.robot_lost.connect(_on_robot_lost)
	_start_xrt_discovery()

	# Wire up Session signals
	_session.device_connected.connect(_on_device_connected)
	_session.device_disconnected.connect(_on_device_disconnected)
	_session.telemetry_received.connect(_on_telemetry_received)
	_session.blueprint_received.connect(_on_blueprint_received)
	_session.blueprint_cleared.connect(_clear_blueprint_runtime)
	_session.blueprint_state_received.connect(
		_on_blueprint_runtime_state_received
	)

	# Configure command sender references
	_command_sender.tracking_provider = _tracking_provider
	_command_sender.tcp_handler = _tcp_handler
	_command_sender.transport = _outside_target
	_xr_state_sender.tracking_provider = _tracking_provider
	_xr_state_sender.tcp_handler = _tcp_handler

	# Start discovery scanning in the background; the Settings panel opens
	# as soon as XR is ready and shows discovery progress while this runs.
	_discovery.start_scan()

	# Initial UI state: hide both until XR is ready enough to place
	# composition layers. `_begin_launch_window` opens the panel immediately
	# instead of waiting for discovery to finish.
	_settings_panel.visible = false
	_settings_button.visible = false

	# Apply persisted runtime options immediately. The settings page's Test
	# actions are previews only; the confirmed options own the working page.
	var persisted: Dictionary = SettingsUI.load_settings()
	_applied_options = persisted.duplicate(true)
	_apply_runtime_settings(persisted)

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
		if _settings_panel and not _menu_world_locked:
			_settings_panel.transform = _camera.transform * SETTINGS_PANEL_OFFSET
		if _settings_button:
			if (
				_video_test_active
				and _robot_view
				and _robot_view.has_method("get_panel_anchor_transform")
			):
				var panel_size := _video_panel_size()
				_settings_button.global_transform = _robot_view.call(
					"get_panel_anchor_transform",
					Vector3(
						panel_size.x * 0.5 - VIDEO_PREVIEW_CLOSE_INSET.x,
						panel_size.y * 0.5 - VIDEO_PREVIEW_CLOSE_INSET.y,
						VIDEO_PREVIEW_CLOSE_Z_OFFSET,
					)
				)
			else:
				_settings_button.transform = _camera.transform * SETTINGS_BUTTON_OFFSET
	_tick_send_rate(_delta)
	_apply_settings_input_indicator(_current_interaction_mode())
	_update_teleop_controller_panel()
	_update_controller_shell()
	_tick_telemetry_reconnect(_delta)
	# Position refreshes every frame so the gizmo tracks the controller smoothly;
	# its orientation only changes when telemetry reports a new captured frame.
	_update_control_frame_gizmo()


# Push the detected input source down to the teleop settings panel so the
# title-bar indicator (defined on BaseSettingsPanel) stays in sync. Cheap
# because the panel only repaints when the mode actually changes.
var _last_indicator_mode := ""


func _apply_settings_input_indicator(mode: String) -> void:
	if mode == _last_indicator_mode:
		return
	_last_indicator_mode = mode
	if _settings_ui != null and _settings_ui.has_method("set_input_mode_indicator"):
		_settings_ui.call("set_input_mode_indicator", mode)
	var controller := _right_controller if mode == "controllers" else null
	if _settings_button and _settings_button.has_method("set_feedback_input_mode"):
		_settings_button.call("set_feedback_input_mode", mode, controller)


func _bind_operator_interaction() -> void:
	var interaction := _operator_interaction()
	if interaction == null:
		return
	if (
		interaction.has_signal("input_mode_changed")
		and not interaction.is_connected(
			"input_mode_changed", Callable(self, "_on_global_interaction_mode_changed")
		)
	):
		interaction.connect(
			"input_mode_changed", Callable(self, "_on_global_interaction_mode_changed")
		)
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
	var outside_script := load(OUTSIDE_ROBOT_TARGET_PATH)
	if outside_script == null:
		push_error("[Operator] Cannot load Outside Robot target")
		return
	var outside_instance: Variant = outside_script.new()
	if outside_instance == null:
		push_error("[Operator] Cannot instantiate Outside Robot target")
		return
	_outside_target = outside_instance
	_outside_target.name = "OutsideRobotTarget"
	_outside_target.configure(_tcp_handler)
	_bind_target_signals(_outside_target)
	add_child(_outside_target)

	# XRoboToolkit compatibility is Pico-only. Elsewhere the target simply
	# does not exist, so a stale persisted setting or a
	# `--operator-teleop-protocol xrobot_toolkit_v1` launch extra degrades to
	# the "runtime unavailable" status instead of opening a dead TCP stream.
	if PicoPlatformAdapter.is_pico_build():
		var xrt_script := load(XROBOT_TOOLKIT_TARGET_PATH)
		if xrt_script == null:
			push_error("[Operator] Cannot load XRoboToolkit-compatible target")
		else:
			var xrt_instance: Variant = xrt_script.new()
			if xrt_instance == null:
				push_error("[Operator] Cannot instantiate XRoboToolkit-compatible target")
			else:
				_xrt_target = xrt_instance
		if _xrt_target != null:
			_xrt_target.name = "XRobotToolkitTarget"
			_xrt_target.configure(_tracking_provider)
			# Counts toward the send rate shown on the settings page; the XRT
			# sender is the only thing on the wire in that mode.
			var xrt_sender: Node = _xrt_target.get("sender")
			if xrt_sender != null and xrt_sender.has_signal("frame_sent"):
				xrt_sender.connect("frame_sent", Callable(self, "_on_xrt_frame_sent"))
			_bind_target_signals(_xrt_target)
			add_child(_xrt_target)
			# The target can be built after a pause/focus notification has already
			# landed, so hand it the current lifecycle state instead of letting it
			# assume focus until the next transition.
			_sync_app_focus()

	var inside_script := load(INSIDE_ROBOT_TARGET_PATH)
	if inside_script == null:
		push_error("[Operator] Cannot load Inside Robot target")
	else:
		var inside_instance: Variant = inside_script.new()
		if inside_instance == null:
			push_error("[Operator] Cannot instantiate Inside Robot target")
		else:
			_inside_target = inside_instance
	if _inside_target != null:
		_inside_target.name = "InsideRobotTarget"
		_inside_target.configure_runtime(self, _origin, _camera, _tracking_provider)
		_bind_target_signals(_inside_target)
		add_child(_inside_target)
	_active_target = _outside_target

	_session = Session.new()
	_session.name = "Session"
	_session.tcp_handler = _tcp_handler
	add_child(_session)
	_blueprint_runtime = BlueprintRuntimeScript.new()
	_blueprint_runtime.name = "BlueprintRuntime"
	var blueprint_external_views: Array[String] = []
	for implementation_v in BLUEPRINT_EXTERNAL_VIEW_IMPLEMENTATIONS:
		blueprint_external_views.append(str(implementation_v))
	_blueprint_runtime.configure(
		_origin,
		_camera,
		_left_controller,
		_right_controller,
		_tracking_provider,
		blueprint_external_views,
	)
	_blueprint_runtime.event_emitted.connect(_on_blueprint_runtime_event)
	_blueprint_runtime.warning_raised.connect(_on_blueprint_runtime_warning)
	_blueprint_runtime.external_view_changed.connect(_on_blueprint_external_view_changed)
	_origin.add_child(_blueprint_runtime)

	# WP6: command emission stack built by the teleop composition root
	# (CommandSender Node + RobotControlSink wrapper, behavior unchanged).
	var teleop := TeleopComposition.build(self)
	_command_sender = teleop.get("command_sender")
	_robot_control_sink = teleop.get("robot_control_sink")
	_ee_pose_trajectory = EEPoseTrajectoryScript.new()
	_ee_pose_trajectory.name = "EEPoseTrajectory"
	add_child(_ee_pose_trajectory)
	_hand_feedback_overlay = DexterousHandFeedbackOverlayScript.new()
	_hand_feedback_overlay.name = "DexterousHandFeedbackOverlay"
	_camera.add_child(_hand_feedback_overlay)
	_hand_feedback_overlay.set_enabled(false)
	_hand_tactile_overlay = DexterousHandTactileOverlayScript.new()
	_hand_tactile_overlay.name = "DexterousHandTactileOverlay"
	_hand_tactile_overlay.set_tracking_provider(_tracking_provider)
	_origin.add_child(_hand_tactile_overlay)
	_hand_tactile_overlay.set_enabled(false)
	for hand in [HAND_LEFT, HAND_RIGHT]:
		var indicator := HandControlIndicatorScript.new()
		indicator.name = "LeftHandControlIndicator" if hand == HAND_LEFT else "RightHandControlIndicator"
		_origin.add_child(indicator)
		_hand_control_indicators[hand] = indicator
	_command_sender.command_sent.connect(_on_command_sent)

	_xr_state_sender = XrStateSender.new()
	_xr_state_sender.name = "XrStateSender"
	_xr_state_sender.frame_sent.connect(_on_xr_state_frame_sent)
	_xr_state_sender.tracking_blocked.connect(_on_tracking_blocked)
	add_child(_xr_state_sender)

	_telemetry_tcp_handler = TcpHandler.new()
	_telemetry_tcp_handler.name = "TelemetryTcpHandler"
	add_child(_telemetry_tcp_handler)

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

	# Same Pico-only gate as the XRT target above: no FPV session object at
	# all on other platforms.
	if PicoPlatformAdapter.is_pico_build():
		var xrt_video_script := load(XROBOT_TOOLKIT_VIDEO_SESSION_PATH)
		if xrt_video_script == null:
			push_error("[Operator] Cannot load XRobotToolkit video session")
		else:
			var xrt_video_instance: Variant = xrt_video_script.new()
			if xrt_video_instance == null:
				push_error("[Operator] Cannot instantiate XRobotToolkit video session")
			else:
				_xrt_video_session = xrt_video_instance
		if _xrt_video_session != null:
			_xrt_video_session.name = "XRobotToolkitVideoSession"
			_xrt_video_session.connect("connected", Callable(self, "_on_xrt_video_connected"))
			_xrt_video_session.connect("disconnected", Callable(self, "_on_xrt_video_disconnected"))
			_xrt_video_session.connect("failed", Callable(self, "_on_xrt_video_failed"))
			_xrt_video_session.connect(
				"video_frame_received", Callable(self, "_on_xrt_video_frame_received")
			)
			add_child(_xrt_video_session)

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
	_settings_panel.disconnect_requested.connect(_on_settings_disconnect_requested)
	_settings_panel.close_requested.connect(_on_settings_close_requested)
	_settings_panel.display_options_changed.connect(_on_display_options_changed)
	_settings_panel.video_connect_requested.connect(_on_video_connect_requested)
	_settings_panel.pico_body_calibration_requested.connect(
		_on_pico_body_calibration_requested
	)
	_settings_panel.tracker_calibration_confirm_requested.connect(_on_tracking_calibration_confirm_requested)
	_settings_panel.blueprint_visibility_override_requested.connect(
		_on_blueprint_visibility_override_requested
	)
	_settings_panel.exit_requested.connect(_on_settings_exit_requested)
	_origin.add_child(_settings_panel)
	_settings_ui = _settings_panel
	var tracking_sessions := TrackingSessionService.shared()
	if tracking_sessions != null:
		tracking_sessions.changed.connect(_on_tracking_sessions_changed)
		_on_tracking_sessions_changed()

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
	_controller_shell = ControllerShellScript.new()
	_controller_shell.name = "SystemMenuHost"
	add_child(_controller_shell)
	_controller_shell.call("configure", _origin, _camera, _left_controller, _right_controller, _tracking_provider, _blueprint_runtime)
	_controller_shell.connect("connection_requested", _on_controller_connection_requested)


func _update_controller_shell() -> void:
	if _controller_shell == null:
		return
	var outside_operator := str(_applied_options.get("target_scope", "outside")) == "outside" \
		and str(_applied_options.get("protocol", "operator")) == "operator"
	var transport_connected: bool = _tcp_handler != null and bool(_tcp_handler.call("is_connected_to_robot"))
	var connected: bool = transport_connected and _active_target == _outside_target and _outside_target.is_ready()
	var connecting: bool = _tcp_handler != null and (int(_tcp_handler.call("get_state")) == TcpHandler.State.CONNECTING or (transport_connected and not connected))
	_controller_shell.call("update_context", connected, connecting,
		outside_operator and _xr_started and not _teleop_suspended and not _settings_menu_open
		and not _app_paused and not _app_unfocused)


func _on_controller_connection_requested(connect_requested: bool) -> void:
	if connect_requested:
		# The controller menu never connects on its own: choosing the robot and
		# connecting belong to the settings page, so send the operator there.
		# Deferred because this runs inside the menu runtime's own dispatch.
		call_deferred("_open_settings_to_connect")
	else:
		_on_settings_disconnect_requested()
	_update_controller_shell()


func _open_settings_to_connect() -> void:
	_show_settings_panel()
	if _settings_ui and _settings_ui.has_method("select_group"):
		_settings_ui.call("select_group", "robot")


func _update_teleop_controller_panel() -> void:
	if _teleop_controller_panel == null:
		return
	if _teleop_suspended:
		return
	if (
		_teleop_controller_panel.has_method("is_blueprint_enabled")
		and not bool(_teleop_controller_panel.call("is_blueprint_enabled"))
	):
		return
	var controller_active := _is_right_controller_mode_active()
	_teleop_controller_panel.call("set_controller_active", controller_active)
	_update_teleop_controller_panel_transform(controller_active)
	var connected: bool = _active_target != null and _active_target.is_ready()
	var grip_value := 0.0
	var trigger_value := 0.0
	var a_pressed := false
	if (
		controller_active
		and _tracking_provider
		and _tracking_provider.has_method("get_controller_input")
	):
		var input_any: Variant = _tracking_provider.call("get_controller_input", 1)
		if input_any is Dictionary:
			grip_value = maxf(
				float(input_any.get("grip", 0.0)),
				maxf(
					float(input_any.get("grip_click", 0.0)), float(input_any.get("grip_force", 0.0))
				)
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
	_teleop_controller_panel.global_transform = (
		_right_controller.global_transform * TELEOP_CONTROLLER_OVERLAY_OFFSET
	)


func _is_right_controller_mode_active() -> bool:
	if _tracking_provider and _tracking_provider.has_method("is_controller_mode_active"):
		return bool(_tracking_provider.call("is_controller_mode_active", 1))
	return (
		_right_controller != null
		and _right_controller.get_is_active()
		and _right_controller.get_has_tracking_data()
	)


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
	if not _synthetic and _teleop_arg(TELEOP_KEY_SCOPE, "") == "inside":
		_start_inside_from_launch_args()
		return

	var launch_host := _teleop_arg(TELEOP_KEY_HOST, "")
	if not _synthetic and not launch_host.is_empty():
		var launch_options: Dictionary = SettingsUI.load_settings()
		var launch_port := int(_teleop_arg(TELEOP_KEY_PORT, str(SYNTH_DEFAULT_PORT)))
		launch_options["target_scope"] = "outside"
		launch_options["protocol"] = _teleop_arg(
			TELEOP_KEY_PROTOCOL, str(launch_options.get("protocol", "operator")))
		_apply_common_launch_overrides(launch_options)
		launch_options["ip"] = launch_host
		launch_options["port"] = launch_port
		launch_options["xrobot_toolkit_device_sn"] = _teleop_arg(
			TELEOP_KEY_XROBOT_TOOLKIT_DEVICE_SN,
			str(launch_options.get("xrobot_toolkit_device_sn", "")),
		)
		if _settings_panel and _settings_panel.has_method("close"):
			_settings_panel.close()
		else:
			_settings_panel.visible = false
		_settings_button.visible = true
		_set_menu_guards(false)
		_apply_runtime_settings(launch_options)
		print(
			"[Operator] Direct-connect launch override %s:%d via %s"
			% [launch_host, launch_port, str(launch_options.get("protocol", "operator"))]
		)
		_set_link_active(_start_outside_with_options(launch_options))
		if _teleop_flag_set(TELEOP_KEY_PICO_BODY_CALIBRATE):
			call_deferred("_on_pico_body_calibration_requested")
	elif not _synthetic:
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
			world.environment.background_mode = PASSTHROUGH_BACKGROUND_MODE
			world.environment.background_color = Color(0, 0, 0, 0)

	if _start_xr and _start_xr.xr_interface:
		_start_xr.xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND


# --- Settings flow ------------------------------------------------------------


## Called by SettingsUI when the user presses Confirm.
## Saves the panel state, hides it, then connects/reconnects with the chosen
## endpoint. The robot type is not a client setting — the DeviceDescriptor
## received on handshake defines what the client sends and displays.
func _on_settings_applied(options: Dictionary) -> void:
	_end_video_test()
	var target_scope := str(options.get("target_scope", "outside"))
	print(
		(
			"[Operator] Settings applied: target=%s options=%s"
			% [
				target_scope,
				JSON.stringify(options),
			]
		)
	)
	_cancel_launch_window()
	_applied_options = options.duplicate(true)

	# A manual video override is only meaningful for the endpoint it was
	# configured against. `_connect_video_stream()` short-circuits to it
	# whenever it is non-empty, so without this re-seed one "Connect video"
	# press would pin every later auto-connect to that host -- even after the
	# operator confirmed a different robot, whose descriptor-advertised video
	# endpoint would then be ignored for the rest of the session. Only touch
	# an override that is already active, so confirming settings never starts
	# pinning video for an operator who never asked for one.
	if not _manual_video_options.is_empty():
		var next_video_ip := str(options.get("video_ip", "")).strip_edges()
		var next_video_port := int(options.get("video_port", 0))
		if next_video_ip.is_empty() or next_video_port <= 0 or next_video_port > 65535:
			_manual_video_options.clear()
		else:
			_manual_video_options = options.duplicate(true)

	_stop_active_target()
	# A per-item Test action is only a preview. Confirm is the ownership
	# boundary where every persisted option becomes part of the working page.
	# Apply after stopping the old target: clearing its Blueprint emits hide
	# gates, which must not overwrite the newly selected Inside/XRT settings.
	_apply_runtime_settings(options)
	if target_scope == "inside":
		_set_revo2_hand_runtime_enabled(false)
		if _inside_target == null:
			_show_settings_panel_with_status(tr("UI_INSIDE_RUNTIME_UNAVAILABLE"))
			_set_link_active(false)
			return
		_active_target = _inside_target
		_command_sender.transport = null
		_robot_control_sink.set_sending(false)
		_disconnect_outside_media()
		_inside_target.start(options)
	else:
		if not _start_outside_with_options(options):
			_set_link_active(false)
			return
	# The page stays open: Connect owns the link, not the operator's place in
	# the UI. Leaving for the work page is the bottom Close action's job.
	_set_link_active(true)


func _apply_runtime_settings(options: Dictionary) -> void:
	var robot_authored_views := _options_use_robot_authored_blueprint(options)
	# Owners of `show_video_panel`:
	#   - `_begin_video_test` (visible while a Test Video preview is running)
	#   - this function (visible after the operator confirms to start teleop,
	#     iff the form's `show_video_panel` toggle is on)
	#   - `_apply_blueprint_video_panel` (a robot-authored blueprint declares
	#     `video_panel` visibility for outside/operator sessions; that path is
	#     skipped here so blueprint decisions are not clobbered by Confirm).
	var show_video_panel := false
	if not robot_authored_views:
		show_video_panel = bool(options.get("show_video_panel", false))
	if _robot_view:
		if robot_authored_views and not _robot_authored_views_active:
			var distance_value: Variant = _robot_view.get("follow_distance")
			if distance_value is float or distance_value is int:
				_local_video_panel_distance = float(distance_value)
		elif not robot_authored_views and _robot_authored_views_active \
				and _robot_view.has_method("set_panel_distance"):
			_robot_view.call("set_panel_distance", _local_video_panel_distance)
		if not robot_authored_views:
			_robot_view.follow_camera = bool(options.get("video_face_locked", true))
		if _robot_view.has_method("set_show_video_panel"):
			_robot_view.set_show_video_panel(show_video_panel)
	_robot_authored_views_active = robot_authored_views
	if _ee_pose_trajectory:
		_ee_pose_trajectory.set_enabled(
			false
			if robot_authored_views
			else bool(options.get("show_operation_trajectory", false))
		)
	_control_frame_visualization_enabled = not robot_authored_views
	if not _control_frame_visualization_enabled:
		_hide_control_frame_gizmos()
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_blueprint_enabled"):
		_teleop_controller_panel.call("set_blueprint_enabled", not robot_authored_views)
	_menu_world_locked = bool(options.get("menu_world_locked", false))
	_set_vr_pose_enabled(
		bool(options.get("show_vr_pose", false))
		and str(options.get("target_scope", "outside")) != "inside"
	)


static func _options_use_robot_authored_blueprint(options: Dictionary) -> bool:
	return (
		str(options.get("target_scope", "outside")) == "outside"
		and str(options.get("protocol", "operator")) == "operator"
	)


func _on_settings_button_pressed() -> void:
	_end_video_test()
	_show_settings_panel()


func _set_revo2_hand_control_unlocked(unlocked: bool) -> void:
	var transport_connected: bool = (
		_active_target == _outside_target
		and _tcp_handler != null
		and _tcp_handler.is_connected_to_robot()
	)
	var target_ready: bool = (
		_outside_target != null
		and _outside_target.has_method("is_ready")
		and _outside_target.is_ready()
	)
	_revo2_hand_control_unlocked = (
		unlocked
		and _revo2_hand_runtime_enabled
		and transport_connected
		and target_ready
		and not _teleop_suspended
	)
	_sync_revo2_hand_command_gate()
	print("[Operator] Revo2 hand control unlocked=%s" % str(_revo2_hand_control_unlocked))


func _revo2_uses_robot_authored_blueprint() -> bool:
	return (
		_revo2_hand_runtime_enabled
		and _blueprint_runtime != null
		and _blueprint_runtime.has_blueprint()
	)


func _sync_revo2_hand_command_gate() -> void:
	var mode = _active_control_mode()
	if mode != null and mode.has_method("set_hand_control_unlocked"):
		var was_streaming: bool = (
			mode.has_method("is_hand_control_unlocked")
			and bool(mode.call("is_hand_control_unlocked"))
		)
		var authored_stream_enabled: bool = (
			_revo2_uses_robot_authored_blueprint()
			and _active_target == _outside_target
			and not _teleop_suspended
			and _tcp_handler != null
			and _tcp_handler.is_connected_to_robot()
			and _outside_target != null
			and _outside_target.has_method("is_ready")
			and _outside_target.is_ready()
		)
		var should_stream: bool = authored_stream_enabled or _revo2_hand_control_unlocked
		mode.call("set_hand_control_unlocked", should_stream)
		if was_streaming and not should_stream and _command_sender != null:
			_command_sender.send_immediate_command()


func _set_revo2_hand_runtime_enabled(enabled: bool) -> void:
	_revo2_hand_runtime_enabled = enabled
	if not enabled:
		_set_revo2_hand_control_unlocked(false)
		if _hand_feedback_overlay:
			_hand_feedback_overlay.clear()
		if _hand_tactile_overlay:
			_hand_tactile_overlay.clear()
	_refresh_revo2_visualization_ownership()
	if not enabled:
		for indicator_v in _hand_control_indicators.values():
			var indicator = indicator_v
			if indicator != null:
				indicator.update_state(null, false, false, false)


func _refresh_revo2_visualization_ownership() -> void:
	if _hand_feedback_overlay:
		_hand_feedback_overlay.set_enabled(false)
	if _hand_tactile_overlay:
		_hand_tactile_overlay.set_enabled(false)
	for indicator_v in _hand_control_indicators.values():
		var indicator = indicator_v
		if indicator != null:
			indicator.update_state(null, false, false, false)
	_sync_revo2_hand_command_gate()


static func _operator_discovery_key(ip: String, pose_port: int) -> String:
	return "operator|%s|%d" % [ip, pose_port]


static func _xrt_discovery_key(ip: String, port: int) -> String:
	return "xrobot_toolkit_v1|%s|%d" % [ip, port]


static func _known_robot_ip(key: Variant, info: Dictionary) -> String:
	var endpoint_ip := str(info.get("ip", "")).strip_edges()
	if endpoint_ip.is_empty() and str(key).is_valid_ip_address():
		endpoint_ip = str(key)
	return endpoint_ip


func _find_known_robot(ip: String, protocol := "", pose_port := 0) -> Dictionary:
	for key in _known_robots:
		var info_v: Variant = _known_robots[key]
		if not info_v is Dictionary:
			continue
		var info := info_v as Dictionary
		if _known_robot_ip(key, info) != ip:
			continue
		if not protocol.is_empty() and str(info.get("protocol", "operator")) != protocol:
			continue
		if pose_port > 0 and int(info.get("pose_port", 0)) != pose_port:
			continue
		return info
	return {}


static func _discovery_matches_options(info: Dictionary, options: Dictionary) -> bool:
	return (
		str(info.get("ip", "")).strip_edges() == str(options.get("ip", "")).strip_edges()
		and int(info.get("pose_port", 0)) == int(options.get("port", 0))
		and str(info.get("protocol", "operator")) == str(options.get("protocol", "operator"))
	)


static func _can_auto_connect_discovered(info: Dictionary, options: Dictionary) -> bool:
	return bool(options.get("loaded", false)) and _discovery_matches_options(info, options)


func _prepare_outside_runtime_features(ip: String, pose_port: int) -> void:
	var info := _find_known_robot(ip, "operator", pose_port)
	_set_revo2_hand_runtime_enabled(
		str(info.get("device_type", "")) == REVO2_DEVICE_TYPE
	)


static func _descriptor_supports_revo2_hand_runtime(descriptor: Dictionary) -> bool:
	var device_v: Variant = descriptor.get("device", {})
	var device: Dictionary = device_v if device_v is Dictionary else {}
	if str(device.get("type", "")) == REVO2_DEVICE_TYPE:
		return true

	var schema_v: Variant = descriptor.get("control_schema", {})
	var schema: Dictionary = schema_v if schema_v is Dictionary else {}
	var missing_axes := {}
	for side in ["left", "right"]:
		for channel in REVO2_HAND_CHANNELS:
			missing_axes["revo2_%s_%s" % [side, channel]] = true
	for axis_v in schema.get("axes", []):
		if not axis_v is Dictionary:
			continue
		var axis_name := str((axis_v as Dictionary).get("name", ""))
		missing_axes.erase(axis_name)

	var telemetry_v: Variant = descriptor.get("telemetry_schema", {})
	var telemetry_schema: Dictionary = telemetry_v if telemetry_v is Dictionary else {}
	var telemetry_names := {}
	for value_v in telemetry_schema.get("values", []):
		if value_v is Dictionary:
			telemetry_names[str((value_v as Dictionary).get("name", ""))] = true
	return (
		missing_axes.is_empty()
		and telemetry_names.has("revo2_left_position")
		and telemetry_names.has("revo2_right_position")
	)


## Close signal: hide the page and re-show the floating settings button so
## the user can reopen later. The link is untouched.
func _on_settings_close_requested() -> void:
	_hide_settings_panel()


## Display preferences are the live view rather than a staged form, so the
## page applies them as they change instead of folding them into Connect.
## Only the display bits are read here: the scope and endpoint belong to the
## session that is actually running, not to whatever the form currently says.
func _on_display_options_changed(options: Dictionary) -> void:
	_menu_world_locked = bool(options.get("menu_world_locked", false))
	if _menu_world_locked:
		_place_settings_panel()
	var show_vr_pose := bool(options.get("show_vr_pose", false))
	# A running Inside embodiment owns its skeleton, anchored beside the robot;
	# every other case, including no session at all, gets the head-tracked one.
	var inside_running: bool = (
		_inside_target != null
		and _active_target == _inside_target
		and not _inside_target.is_stopped()
	)
	if inside_running:
		_inside_target.call("set_show_vr_pose", show_vr_pose)
	_set_vr_pose_enabled(show_vr_pose and not inside_running)
	if _ee_pose_trajectory and not _robot_authored_views_active:
		_ee_pose_trajectory.set_enabled(
			bool(options.get("show_operation_trajectory", false))
		)


## Connect / Disconnect own this flag; opening or closing the page does not.
func _set_link_active(active: bool) -> void:
	_link_active = active
	if not active:
		_send_frame_count = 0
		_send_rate_elapsed = 0.0
	if _settings_ui and _settings_ui.has_method("set_link_active"):
		_settings_ui.call("set_link_active", active)


## Outgoing frames per second, averaged over half a second so the number on
## the page is readable rather than jittering with every frame. An Inside
## robot sends nothing over a socket — its retargeting runs per rendered
## frame — so that scope counts frames it actually drives instead.
func _tick_send_rate(delta: float) -> void:
	if not _link_active:
		return
	if (
		_inside_target != null
		and _active_target == _inside_target
		and _inside_target.is_ready()
		and bool(_inside_target.control_enabled)
	):
		_send_frame_count += 1
	_send_rate_elapsed += delta
	if _send_rate_elapsed < 0.5:
		return
	var hz := float(_send_frame_count) / _send_rate_elapsed
	_send_frame_count = 0
	_send_rate_elapsed = 0.0
	if _settings_ui and _settings_ui.has_method("set_send_rate"):
		_settings_ui.call("set_send_rate", hz)


func _on_xr_state_frame_sent(_frame_id: int, _timestamp_ns: int) -> void:
	_send_frame_count += 1


func _on_xrt_frame_sent(_timestamp_ns: int) -> void:
	_send_frame_count += 1


## Build or tear down the canonical VR-pose skeleton this controller owns.
## It tracks the head rather than a robot visual, because an Outside session
## has no in-headset robot to stand the skeleton next to.
func _set_vr_pose_enabled(enabled: bool) -> void:
	if enabled == (_vr_pose_overlay != null):
		return
	if not enabled:
		if is_instance_valid(_vr_pose_overlay):
			_vr_pose_overlay.queue_free()
		_vr_pose_overlay = null
		if is_instance_valid(_vr_pose_provider):
			_vr_pose_provider.call("set_enabled", false)
			_vr_pose_provider.queue_free()
		_vr_pose_provider = null
		return
	if _tracking_provider == null or _origin == null or _camera == null:
		return
	var bridge := _pico_body_bridge()
	# The provider owns one shared tracking lease; removing this overlay cannot
	# stop a tracker still used by the sender or another body consumer.
	_vr_pose_provider = BodyPoseProviderScript.new()
	_vr_pose_provider.name = "TeleopVrPoseProvider"
	_vr_pose_provider.configure(_tracking_provider, bridge)
	# Diagnostic overlay, not a control input: a headset without body
	# tracking still gets the head/hand-derived fallback skeleton rather than
	# a toggle that silently does nothing.
	_vr_pose_provider.allow_fallback = true
	_vr_pose_provider.source_mode = BodyPoseProviderScript.SourceMode.AUTO
	_vr_pose_provider.sample_rate_hz = 60.0
	_origin.add_child(_vr_pose_provider)
	_vr_pose_provider.set_enabled(true)
	_vr_pose_overlay = BodyPoseDebugOverlayScript.new()
	_vr_pose_overlay.name = "TeleopVrPoseOverlay"
	_vr_pose_overlay.call("set_head_camera", _camera)
	_origin.add_child(_vr_pose_overlay)
	_vr_pose_overlay.call("configure", _vr_pose_provider)


func _pico_body_bridge() -> Object:
	if get_tree() == null:
		return null
	var autoload := get_tree().root.get_node_or_null("PicoOpenXRBridge")
	if autoload != null and autoload.has_method("get_bridge"):
		return autoload.call("get_bridge")
	return null


func _on_settings_disconnect_requested() -> void:
	print("[Operator] Settings disconnect requested")
	_end_video_test()
	_cancel_launch_window()
	_set_link_active(false)
	_set_revo2_hand_control_unlocked(false)
	_stop_active_target()
	_disconnect_outside_media()
	if _clock_sync:
		_clock_sync.stop()
	if _command_sender:
		_command_sender.transport = null
	_active_target = null
	_sdk_mode = false
	_set_status(tr("UI_DISCONNECTED"))


func _on_pico_body_calibration_requested() -> void:
	var sessions := TrackingSessionService.shared()
	if sessions == null:
		var unavailable := tr("UI_PICO_BODY_CALIBRATION_UNAVAILABLE")
		push_warning("[Operator] %s" % unavailable)
		_set_status(unavailable)
		return
	var opened := sessions.begin_calibration()
	if opened:
		print("[Operator] PICO Body Calibration opened")
		_set_status(tr("UI_PICO_BODY_CALIBRATION_OPENED"))
	else:
		var failed := tr("UI_PICO_BODY_CALIBRATION_FAILED")
		push_warning("[Operator] %s" % failed)
		_set_status(failed)


func _on_tracking_calibration_confirm_requested() -> void:
	var sessions := TrackingSessionService.shared()
	if sessions == null or not sessions.confirm_calibration():
		_set_status(tr("UI_TRACKING_CONFIRM_REJECTED"))
	else:
		_set_status(tr("UI_TRACKING_CALIBRATION_CONFIRMED"))
	_on_tracking_sessions_changed()


func _on_tracking_sessions_changed() -> void:
	if _settings_panel != null:
		_settings_panel.set_tracking_status(_robot_tracking_report(), _optional_tracking_report())
	# Lease release can happen inside target.stop(). Do not re-enable a target
	# reentrantly while its teardown is still running.
	# Detached controllers cannot own live senders. In particular, don't queue
	# work during scene destruction or for an unattached contract-test instance.
	if is_inside_tree():
		call_deferred("_sync_stream_senders")


func _robot_tracking_report() -> Dictionary:
	# Use the active consumer's lease, not the global summary: a local body
	# overlay must never make a controller-only robot require calibration.
	if _active_target == _outside_target and _active_target != null and _xr_state_sender != null:
		# Keep the interlocked lease visible after an SDK safety disconnect so
		# calibration can be completed before an explicit Connect/re-arm.
		return _xr_state_sender.tracking_report()
	if _active_target != null and _active_target.has_method("tracking_report"):
		return _active_target.call("tracking_report")
	return {"needed": false, "allowed": true, "phase": "off"}


func _optional_tracking_report() -> Dictionary:
	if _active_target == _inside_target and _inside_target != null and _inside_target.has_method("tracking_report"):
		return _inside_target.tracking_report(true)
	if is_instance_valid(_vr_pose_provider):
		var report: Dictionary = _vr_pose_provider.call("tracking_status")
		return report
	return {"needed": false, "allowed": true, "phase": "off"}


func _on_tracking_blocked(report: Dictionary) -> void:
	_set_link_active(false)
	_on_tracking_sessions_changed()
	_show_settings_panel_with_status(tr("UI_TRACKING_REARM_REQUIRED"))
	if _settings_ui and _settings_ui.has_method("select_group"):
		_settings_ui.call("select_group", "robot")
	print("[TeleopTracking] required-tracking-blocked phase=%s settings=robot" % str(report.get("phase", "unavailable")))


## Exit on the panel returns to the mode-select / launcher scene so the
## user can pick a different mode without restarting the app. The session
## is torn down cleanly first; the Exit *card* on the launcher itself is
## what actually quits the process.
func _on_settings_exit_requested() -> void:
	print("[Operator] Settings exit requested — returning to mode select")
	_set_link_active(false)
	_clear_blueprint_runtime()
	_set_revo2_hand_control_unlocked(false)
	_cancel_launch_window()
	if _robot_control_sink:
		_robot_control_sink.set_sending(false)
	if _active_target:
		_active_target.stop()
	if _clock_sync:
		_clock_sync.stop()
	if _discovery and _discovery.has_method("stop_scan"):
		_discovery.stop_scan()
	if _xrt_discovery != null and _xrt_discovery.has_method("stop_scan"):
		_xrt_discovery.call("stop_scan")
	if _tcp_handler:
		_tcp_handler.disconnect_from_robot()
	if _video_tcp_handler:
		_video_tcp_handler.disconnect_from_robot()
	if _video_udp_handler:
		_video_udp_handler.disconnect_from_robot()
	if _xrt_video_session:
		_xrt_video_session.call("stop")
	get_tree().change_scene_to_file("res://scenes/main.tscn")


## Mirrors the Android app lifecycle onto the XRoboToolkit stream. The reference
## client reports focus on every frame and the receiver uses it to tell "the
## operator let go" from "the headset went away", so a doffed or backgrounded
## headset must stop reading as a live operator. Pause and focus arrive as
## separate notifications and either one alone means not-live, so both are
## tracked and the sender sees their conjunction.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_app_paused = true
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_app_paused = false
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_app_unfocused = true
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_app_unfocused = false
	else:
		return
	_sync_app_focus()


func _sync_app_focus() -> void:
	_sync_blueprint_suspension()
	_update_controller_shell()
	if _xrt_target != null and _xrt_target.has_method("set_app_focused"):
		_xrt_target.call("set_app_focused", not _app_paused and not _app_unfocused)


## Pause/resume teleop around the settings panel. While suspended neither
## DeviceCommands nor XrStateFrames stream (the robot-side deadman/watchdog
## holds the arm) and the controller overlay hides, so panel interaction can't
## move the arm or show stale grip/trigger hints.
func _set_teleop_suspended(suspended: bool) -> void:
	if suspended:
		_set_revo2_hand_control_unlocked(false)
	if _blueprint_runtime:
		_blueprint_runtime.set_suspended(
			suspended or _settings_menu_open or _app_paused or _app_unfocused
		)
	if _teleop_suspended == suspended:
		return
	_teleop_suspended = suspended
	_sync_revo2_hand_command_gate()
	_sync_stream_senders()
	if suspended and _ee_pose_trajectory:
		# Do not bridge the hand motion performed while settings owns the
		# controllers with one long segment when teleop resumes.
		_ee_pose_trajectory.break_all()
	if _hand_feedback_overlay:
		_hand_feedback_overlay.set_suspended(suspended)
	if _hand_tactile_overlay:
		_hand_tactile_overlay.set_suspended(suspended)
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_suspended"):
		_teleop_controller_panel.call("set_suspended", suspended)


## Apply the single stream-selection invariant at connection, descriptor and
## UI-suspension boundaries. Exactly one of DeviceCommand, XrStateFrame, or
## XRoboToolkit Tracking may be active at a time.
func _sync_stream_senders() -> void:
	# _tcp_handler is scene-typed as Node, so its method result is a Variant.
	# Keep these booleans explicit: Godot 4.5 cannot infer `:=` through the
	# dynamic call when this base script is compiled from an exported APK.
	var connected: bool = _tcp_handler != null and bool(_tcp_handler.call("is_connected_to_robot"))
	var operator_outside_active: bool = (
		connected and _active_target == _outside_target and not _teleop_suspended
	)
	var xrt_active: bool = (
		_xrt_target != null
		and _active_target == _xrt_target
		and _xrt_target.is_ready()
		and not _teleop_suspended
	)
	if _robot_control_sink:
		_robot_control_sink.set_sending(operator_outside_active and not _sdk_mode)
	if _xr_state_sender:
		_xr_state_sender.set_sending(operator_outside_active and _sdk_mode)
	if _xrt_target != null:
		_xrt_target.set_control_enabled(xrt_active)
	if _inside_target != null:
		_inside_target.set_control_enabled(
			_active_target == _inside_target and not _teleop_suspended and _inside_target.is_ready()
		)


## Opening the page is a view change, nothing more: the link, the streams
## and any running Inside embodiment all carry on, so the send rate on the
## page reports a live session rather than one the page just paused.
## Connect / Disconnect are the only things that start or stop a link. What
## the page does guard is input: see `_set_menu_guards` and the page's pointer
## capture.
func _show_settings_panel() -> void:
	_place_settings_panel()
	_set_menu_guards(true)
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
		_settings_panel.set_feedback_input_mode(
			mode, _right_controller if mode == "controllers" else null
		)
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
	_set_menu_guards(false)


## Seat the page in front of the operator. View-locked placement repeats
## this every frame in `_process`; world-locked placement calls it once, at
## open, and then leaves the panel where the operator can walk around it.
func _place_settings_panel() -> void:
	if _settings_panel != null and _camera != null:
		_settings_panel.transform = _camera.transform * SETTINGS_PANEL_OFFSET


## Inputs that must not stay live under an open page. Controller keys are
## already neutralised while the pointer is on the page, but some inputs never
## go through that pointer: touch-driven Blueprint widgets, the Revo2 palm
## unlock and the controller menu. Suspend, re-lock and disable them while the
## page is open.
func _set_menu_guards(open: bool) -> void:
	_settings_menu_open = open
	if open:
		_set_revo2_hand_control_unlocked(false)
	_sync_blueprint_suspension()
	_update_controller_shell()


## Robot Blueprint UI pauses while the settings page is open, while teleop is
## suspended, and while the app is backgrounded or unfocused.
func _sync_blueprint_suspension() -> void:
	if _blueprint_runtime != null:
		_blueprint_runtime.set_suspended(
			_teleop_suspended or _settings_menu_open or _app_paused or _app_unfocused
		)


# --- Launch decision (D: hybrid auto-discover) -------------------------------
#
# The panel opens immediately with a spinner while discovery gets a 3s window
# to find robot(s), then we pick one of:
#
#   show_on_launch == true   → always show panel
#   0 robots                 → show panel (manual fallback, status hints why)
#   1 robot == saved endpoint → auto-connect after spinner, close panel
#   fresh/default settings    → show panel and keep Manual editable
#   1 different endpoint      → show panel for confirmation
#   N robots                 → show panel with the dropdown populated
#
# `last_used_ip` lives in user://teleop_settings.cfg. The robot agent broadcasts on
# 255.255.255.255:63900 every 3s, so a 3s window catches one beacon under
# normal conditions.

const _LAUNCH_DISCOVERY_WINDOW_SEC: float = 3.0


func _begin_launch_window() -> void:
	var persisted: Dictionary = SettingsUI.load_settings()
	if str(persisted.get("target_scope", "outside")) == "inside":
		print("[Operator] Inside Robot selected — opening embodiment setup")
		_show_settings_panel_with_status(tr("UI_INSIDE_ROBOT"))
		return
	if (
		PicoPlatformAdapter.is_pico_build()
		and str(persisted.get("protocol", "operator")) == "xrobot_toolkit_v1"
	):
		var saved_host := str(persisted.get("ip", "")).strip_edges()
		var show_on_launch := bool(persisted.get("show_on_launch", false))
		if show_on_launch or _is_loopback_host(saved_host):
			_show_settings_panel_with_status(
				"XRoboToolkit mode uses the configured RoboticsService endpoint"
			)
			return
		_settings_button.visible = true
		_set_menu_guards(false)
		print(
			"[Operator] Auto-connecting XRoboToolkit compatibility target @ %s:%d"
			% [saved_host, int(persisted.get("port", 63901))]
		)
		_set_link_active(_start_outside_with_options(persisted))
		return
	_launch_window_token += 1
	_launch_window_active = true
	print("[Operator] Discovery window started (%.1fs)" % _LAUNCH_DISCOVERY_WINDOW_SEC)
	_show_settings_panel_discovering()
	get_tree().create_timer(_LAUNCH_DISCOVERY_WINDOW_SEC).timeout.connect(
		_finalize_launch.bind(_launch_window_token)
	)


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

	print(
		(
			"[Operator] Launch decision: known=%d show_on_launch=%s last_ip=%s"
			% [
				n_robots,
				show_on_launch,
				last_ip,
			]
		)
	)

	if show_on_launch:
		_show_settings_panel_with_status(tr("UI_SHOW_ON_LAUNCH_ENABLED"))
		return

	if n_robots == 0:
		_show_settings_panel_with_status(tr("UI_NO_ROBOTS_DISCOVERED"))
		return

	# Silent auto-connect is allowed only for an endpoint the operator previously
	# confirmed. A fresh install's loopback default must never grant ownership to
	# whichever unrelated debug service happens to be the sole broadcaster.
	if n_robots == 1:
		var only_key: Variant = _known_robots.keys()[0]
		var only_info: Dictionary = _known_robots[only_key]
		var only_ip := _known_robot_ip(only_key, only_info)
		if _can_auto_connect_discovered(only_info, persisted):
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
	return (
		trimmed == ""
		or trimmed == "localhost"
		or trimmed == "::1"
		or trimmed == "0:0:0:0:0:0:0:1"
		or trimmed.begins_with("127.")
	)


func _auto_connect_to_discovered(ip: String, port: int, info: Dictionary) -> void:
	# Mirror what _on_settings_applied does for the connection bits, minus
	# the panel-hide step (panel was never shown). Also apply persisted
	# video mode so the auto-path matches what OK would do.
	var persisted: Dictionary = SettingsUI.load_settings()
	var options := persisted.duplicate(true)
	options["target_scope"] = "outside"
	options["protocol"] = str(info.get("protocol", "operator"))
	options["ip"] = ip
	options["port"] = port
	_applied_options = options.duplicate(true)
	_apply_runtime_settings(options)
	if _settings_ui and _settings_ui.has_method("set_discovering"):
		_settings_ui.set_discovering(false)

	if _settings_panel and _settings_panel.has_method("close"):
		_settings_panel.close()
	else:
		_settings_panel.visible = false
	_settings_button.visible = true
	_set_menu_guards(false)
	print(
		"[Operator] Auto-connecting to discovered %s endpoint @ %s:%d"
		% [str(options.get("protocol", "operator")), ip, port]
	)
	_set_link_active(_start_outside_with_options(options))


func _show_settings_panel_with_status(text: String) -> void:
	_place_settings_panel()
	_set_menu_guards(true)
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
	_place_settings_panel()
	_set_menu_guards(true)
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


## Translate the protocol-aware discovery map into the name-keyed structure
## SettingsUI expects. Only an explicitly saved endpoint is preselected; fresh
## defaults stay on Manual so the endpoint fields remain immediately usable.
func _push_discovery_to_settings_ui() -> void:
	if not _settings_ui or not _settings_ui.has_method("set_discovery_state"):
		return
	var by_endpoint: Dictionary = {}
	for key in _known_robots:
		var raw: Dictionary = _known_robots[key]
		var ip := _known_robot_ip(key, raw)
		var info: Dictionary = {
			"name": raw.get("name", ip),
			"ip": ip,
			"pose_port": raw.get("pose_port", 63901),
			"video_port": raw.get("video_port", 0),
			"telemetry_port": raw.get("telemetry_port", DEFAULT_TELEMETRY_PORT),
			"device_type": raw.get("device_type", ""),
			"device_name": raw.get("device_name", ""),
		}
		info["protocol"] = raw.get("protocol", "operator")
		by_endpoint[str(key)] = info
	var persisted: Dictionary = SettingsUI.load_settings()
	if bool(persisted.get("loaded", false)):
		_settings_ui.set_discovery_state(
			by_endpoint,
			String(persisted.get("ip", "")),
			String(persisted.get("protocol", "operator")),
			int(persisted.get("port", 63901)),
		)
	else:
		_settings_ui.set_discovery_state(by_endpoint)


## Single-path "show this status" helper. Goes to logcat always; goes
## to the settings panel's status label too iff the panel is open and
## its inner UI has surfaced a set_status method.
func _set_status(text: String) -> void:
	print("[Operator] %s" % text)
	if _settings_ui and _settings_panel.visible and _settings_ui.has_method("set_status"):
		_settings_ui.set_status(text)


# --- Connection lifecycle -----------------------------------------------------


func _on_command_sent(command: Dictionary) -> void:
	_send_frame_count += 1
	if _ee_pose_trajectory == null:
		return
	(
		_ee_pose_trajectory
		. record_command(
			command,
			_driving_hand(),
			{
				HAND_LEFT: _is_deadman_held(HAND_LEFT),
				HAND_RIGHT: _is_deadman_held(HAND_RIGHT),
			}
		)
	)


func _connect_to_robot(ip: String, port: int) -> void:
	_set_revo2_hand_control_unlocked(false)
	_clear_blueprint_runtime()
	_prepare_outside_runtime_features(ip, port)
	if _ee_pose_trajectory:
		_ee_pose_trajectory.clear()
	if _hand_feedback_overlay:
		_hand_feedback_overlay.clear()
	if _hand_tactile_overlay:
		_hand_tactile_overlay.clear()
	_set_status(tr("UI_CONNECTING_TO") % [ip, port])
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)
	_active_target = _outside_target
	_command_sender.transport = _outside_target
	_active_telemetry_port = _telemetry_port_for(ip, port)
	_outside_target.start({"host": ip, "port": port})


func _start_outside_with_options(options: Dictionary) -> bool:
	# Explicit Connect (or the initial launch attempt), not transport auto-
	# reconnection, is the only path that releases the tracking safety latch.
	if _xr_state_sender != null:
		_xr_state_sender.rearm_tracking()
	var protocol := str(options.get("protocol", "operator"))
	if protocol == "xrobot_toolkit_v1":
		if _xrt_target == null:
			_show_settings_panel_with_status(tr("UI_XROBOT_TOOLKIT_RUNTIME_UNAVAILABLE"))
			return false
		_active_target = _xrt_target
		_clear_blueprint_runtime()
		_command_sender.transport = null
		_robot_control_sink.set_sending(false)
		_xr_state_sender.set_sending(false)
		_disconnect_outside_media()
		_xrt_target.start({
			"host": str(options.get("ip", "")),
			"port": int(options.get("port", 63901)),
			"device_sn": str(options.get("xrobot_toolkit_device_sn", "")),
		})
		return true
	_active_target = _outside_target
	_command_sender.transport = _outside_target
	_connect_to_robot(str(options.get("ip", "")), int(options.get("port", 63901)))
	return true


func _on_connected() -> void:
	if _controller_shell != null:
		_controller_shell.call("set_error", "")
	_set_revo2_hand_control_unlocked(false)
	_set_status(tr("UI_CONNECTED_HANDSHAKE"))
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", true)
	_session.on_connected()
	if _outside_target:
		_outside_target.mark_transport_connected()
	_connect_telemetry_stream(_tcp_handler.get_host())
	_connect_video_stream(_tcp_handler.get_host(), _tcp_handler.get_port())
	if _clock_sync:
		_clock_sync.start()


func _on_disconnected() -> void:
	_set_revo2_hand_control_unlocked(false)
	_clear_blueprint_runtime()
	_set_status(tr("UI_DISCONNECTED"))
	_robot_control_sink.set_sending(false)
	_xr_state_sender.set_sending(false)
	if _ee_pose_trajectory:
		_ee_pose_trajectory.clear()
	if _hand_feedback_overlay:
		_hand_feedback_overlay.clear()
	if _hand_tactile_overlay:
		_hand_tactile_overlay.clear()
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)
	_video_tcp_handler.disconnect_from_robot()
	_video_udp_handler.disconnect_from_robot()
	_telemetry_tcp_handler.disconnect_from_robot()
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()
	_session.on_disconnected()
	if _outside_target:
		_outside_target.mark_transport_disconnected()
	if _clock_sync:
		_clock_sync.stop()


func _on_connection_failed(reason: String) -> void:
	if _controller_shell != null:
		_controller_shell.call("set_error", reason)
	_set_revo2_hand_control_unlocked(false)
	_clear_blueprint_runtime()
	_telemetry_tcp_handler.disconnect_from_robot()
	_set_status(tr("UI_CONNECTION_FAILED") % reason)
	if _outside_target:
		_outside_target.mark_connection_failed(reason)
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


func _on_blueprint_received(blueprint: Dictionary) -> void:
	if _active_target != _outside_target or _blueprint_runtime == null:
		print(
			"[Operator] Dropped Blueprint before runtime ownership target_outside=%s runtime=%s"
			% [str(_active_target == _outside_target), str(_blueprint_runtime != null)]
		)
		return
	_blueprint_runtime.asset_host = _tcp_handler.get_host()
	if _blueprint_runtime.apply_blueprint(blueprint):
		print(
			"[Operator] Blueprint active components=%d suspended=%s"
			% [_blueprint_runtime.component_count(), str(_teleop_suspended)]
		)
		_refresh_revo2_visualization_ownership()
		_sync_blueprint_visibility_options()


func _on_blueprint_runtime_state_received(state: Dictionary) -> void:
	if _active_target != _outside_target or _blueprint_runtime == null:
		print(
			"[Operator] Dropped BlueprintState before runtime ownership target_outside=%s runtime=%s"
			% [str(_active_target == _outside_target), str(_blueprint_runtime != null)]
		)
		return
	var applied := _blueprint_runtime.apply_state(state)
	if int(state.get("sequence", 0)) == 1:
		print("[Operator] Initial BlueprintState applied=%s" % str(applied))


func _on_blueprint_runtime_event(event: Dictionary) -> void:
	if (
		_active_target != _outside_target
		or _teleop_suspended
		or _session == null
	):
		return
	var error := _session.send_blueprint_event(event)
	if error != OK:
		push_warning("[Operator] Could not send BlueprintEvent: %s" % error_string(error))


func _on_blueprint_runtime_warning(message: String) -> void:
	push_warning("[Operator] %s" % message)
	if _controller_shell != null:
		_controller_shell.call("set_error", message)


func _on_blueprint_external_view_changed(
	component_id: String,
	component_type: String,
	visible: bool,
	properties: Dictionary,
) -> void:
	var primitive_spec := BlueprintContract.primitive(component_type)
	var implementation := str(primitive_spec.get("implementation", ""))
	_blueprint_external_view_visibility[implementation] = visible
	match implementation:
		"video_panel":
			_apply_blueprint_video_panel(visible, properties)
		"controller_help":
			if (
				_teleop_controller_panel
				and _teleop_controller_panel.has_method("set_blueprint_enabled")
			):
				_teleop_controller_panel.call("set_blueprint_enabled", visible)
		"control_frame":
			_control_frame_visualization_enabled = visible
			if not visible:
				_hide_control_frame_gizmos()
		"operation_trajectory":
			if _ee_pose_trajectory:
				_ee_pose_trajectory.set_enabled(visible)
		_:
			push_warning(
				"[Operator] Ignoring unknown external Blueprint implementation %s for %s (%s)"
				% [implementation, component_type, component_id]
			)


func _apply_blueprint_video_panel(visible: bool, properties: Dictionary) -> void:
	if _robot_view == null:
		return
	if properties.has("follow_camera"):
		_robot_view.follow_camera = bool(properties["follow_camera"])
	if properties.has("distance") and _robot_view.has_method("set_panel_distance"):
		_robot_view.call("set_panel_distance", float(properties["distance"]))
	if not _video_test_active and _robot_view.has_method("set_show_video_panel"):
		_robot_view.call("set_show_video_panel", visible)


func _on_blueprint_visibility_override_requested(
	component_id: String,
	visible: Variant,
) -> void:
	if _blueprint_runtime == null:
		return
	_blueprint_runtime.set_user_visibility_override(component_id, visible)
	_sync_blueprint_visibility_options()


func _sync_blueprint_visibility_options() -> void:
	if _settings_ui == null or not _settings_ui.has_method("set_blueprint_visibility_options"):
		return
	var options: Array = []
	if _blueprint_runtime != null:
		options = _blueprint_runtime.user_visibility_options()
	_settings_ui.call("set_blueprint_visibility_options", options)


func _clear_blueprint_runtime() -> void:
	if _blueprint_runtime != null:
		_blueprint_runtime.clear()
	_blueprint_external_view_visibility.clear()
	_refresh_revo2_visualization_ownership()
	_sync_blueprint_visibility_options()


func _connect_telemetry_stream(ip: String) -> void:
	if ip.is_empty() or _active_telemetry_port <= 0 or _active_telemetry_port > 65535:
		return
	if (
		_telemetry_tcp_handler.is_connected_to_robot()
		and _telemetry_tcp_handler.get_host() == ip
		and _telemetry_tcp_handler.get_port() == _active_telemetry_port
	):
		return
	_telemetry_tcp_handler.disconnect_from_robot()
	_telemetry_retry_remaining = TELEMETRY_RETRY_DELAY_SEC
	print("[Operator] Connecting telemetry stream to %s:%d" % [ip, _active_telemetry_port])
	_telemetry_tcp_handler.connect_to_robot(ip, _active_telemetry_port)


func _on_telemetry_connected() -> void:
	_telemetry_retry_remaining = 0.0
	print("[Operator] Telemetry stream connected")


func _on_telemetry_disconnected() -> void:
	_telemetry_retry_remaining = TELEMETRY_RETRY_DELAY_SEC
	print("[Operator] Telemetry stream disconnected")
	if _hand_feedback_overlay:
		_hand_feedback_overlay.clear()
	if _hand_tactile_overlay:
		_hand_tactile_overlay.clear()


func _on_telemetry_connection_failed(reason: String) -> void:
	_telemetry_retry_remaining = TELEMETRY_RETRY_DELAY_SEC
	print("[Operator] Telemetry connection failed: %s" % reason)


func _tick_telemetry_reconnect(delta: float) -> void:
	if _telemetry_tcp_handler == null or _tcp_handler == null:
		return
	if _active_target != _outside_target or not _tcp_handler.is_connected_to_robot():
		return
	if _telemetry_tcp_handler.get_state() != TcpHandler.State.DISCONNECTED:
		return
	_telemetry_retry_remaining = maxf(_telemetry_retry_remaining - maxf(delta, 0.0), 0.0)
	if _telemetry_retry_remaining > 0.0:
		return
	_connect_telemetry_stream(_tcp_handler.get_host())


func _on_telemetry_command_received(command: String, data: PackedByteArray) -> void:
	if _session.handle_command(command, data):
		return
	print("[Operator] Unknown telemetry command: %s" % command)


func _telemetry_port_for(ip: String, pose_port: int) -> int:
	var info := _find_known_robot(ip, "operator", pose_port)
	var discovered_port := int(info.get("telemetry_port", 0))
	if discovered_port > 0 and discovered_port <= 65535:
		return discovered_port
	var derived := pose_port + TELEMETRY_PORT_OFFSET
	return derived if derived > 0 and derived <= 65535 else DEFAULT_TELEMETRY_PORT


func _on_video_connected() -> void:
	print("[Operator] Video stream connected")
	if _manual_video_protocol == VIDEO_PROTOCOL_OPERATOR:
		_set_video_status(tr("UI_VIDEO_STATUS_OPERATOR_CONNECTED"))


func _on_video_disconnected() -> void:
	print("[Operator] Video stream disconnected")
	if _manual_video_protocol == VIDEO_PROTOCOL_OPERATOR:
		_set_video_status(tr("UI_VIDEO_STATUS_OPERATOR_DISCONNECTED"))
		_return_from_failed_video_test()
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()


func _on_video_connection_failed(reason: String) -> void:
	print("[Operator] Video connection failed: %s" % reason)
	if _manual_video_protocol == VIDEO_PROTOCOL_OPERATOR:
		_set_video_status(tr("UI_VIDEO_STATUS_OPERATOR_FAILED") % reason)
		_return_from_failed_video_test()


func _on_video_frame_received(packet: Dictionary) -> void:
	if _robot_view and _robot_view.has_method("set_clock_offset"):
		_robot_view.set_clock_offset(RobotClockSync.offset_ns, RobotClockSync.samples)
	if _robot_view and _robot_view.has_method("report_video_packet"):
		_robot_view.report_video_packet(packet)
	elif _robot_view and _robot_view.has_method("report_video_frame"):
		_robot_view.report_video_frame(packet)


func _on_video_connect_requested(options: Dictionary) -> void:
	_connect_configured_video(options, true)


func _video_preview_close_button_offset() -> Transform3D:
	var panel_size := _video_panel_size()
	var panel_distance := 3.0
	if _robot_view:
		var distance_value: Variant = _robot_view.get("follow_distance")
		if distance_value != null:
			panel_distance = float(distance_value)
	return Transform3D(
		Basis.IDENTITY,
		Vector3(
			panel_size.x * 0.5 - VIDEO_PREVIEW_CLOSE_INSET.x,
			panel_size.y * 0.5 - VIDEO_PREVIEW_CLOSE_INSET.y,
			-panel_distance + VIDEO_PREVIEW_CLOSE_Z_OFFSET,
		)
	)


func _video_panel_size() -> Vector2:
	var panel_size := Vector2(3.2, 1.8)
	if _robot_view:
		var size_value: Variant = _robot_view.get("display_size")
		if size_value is Vector2:
			panel_size = size_value
	return panel_size


func _connect_configured_video(options: Dictionary, show_test: bool) -> void:
	var protocol := str(options.get("video_protocol", VIDEO_PROTOCOL_OPERATOR))
	var host := str(options.get("video_ip", "")).strip_edges()
	var port := int(options.get("video_port", 0))
	if host.is_empty() or port <= 0 or port > 65535:
		_set_video_status(tr("UI_VIDEO_STATUS_INVALID_ENDPOINT"))
		return
	_manual_video_options = options.duplicate(true)

	var feed := {
		"width": 1280,
		"height": 720,
		"codec": "h264",
		"stereo": bool(options.get("video_sbs", false)),
	}
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()

	if protocol == VIDEO_PROTOCOL_XROBOT_TOOLKIT:
		if _xrt_video_session == null:
			_set_video_status(tr("UI_VIDEO_STATUS_XROBOT_TOOLKIT_UNAVAILABLE"))
			return
		_video_tcp_handler.disconnect_from_robot()
		_video_udp_handler.disconnect_from_robot()
		if _robot_view and _robot_view.has_method("configure_video_stream"):
			_robot_view.configure_video_stream(feed)
		_manual_video_protocol = VIDEO_PROTOCOL_XROBOT_TOOLKIT
		_active_video_transport = "xrobot_toolkit"
		if _robot_view and _robot_view.has_method("set_packet_source"):
			_robot_view.set_packet_source(_xrt_video_session)
		_xrt_video_session.call("start", {
			"host": host,
			"command_port": port,
			"width": 1280,
			"height": 720,
			"fps": 30,
			"bitrate": 6_000_000,
			"camera_name": "UNITREE_HEAD",
		})
		_set_video_status(tr("UI_VIDEO_STATUS_XROBOT_TOOLKIT_CONNECTING") % [host, port])
	else:
		if _xrt_video_session:
			_xrt_video_session.call("stop")
		_video_udp_handler.disconnect_from_robot()
		# Disconnect before configuring, exactly as the XRobotToolkit branch
		# above does. disconnect_from_robot() emits disconnected_from_server
		# synchronously and _on_video_disconnected() unconditionally calls
		# clear_video_stream(), so configuring first would stop the decoder we
		# just started and no frame would ever decode. Leaving the socket
		# already DISCONNECTED also stops connect_to_video_stream() from
		# re-entering disconnect_from_robot() and re-emitting the signal.
		_video_tcp_handler.disconnect_from_robot()
		if _robot_view and _robot_view.has_method("configure_video_stream"):
			_robot_view.configure_video_stream(feed)
		_manual_video_protocol = VIDEO_PROTOCOL_OPERATOR
		_active_video_transport = "tcp"
		if _robot_view and _robot_view.has_method("set_packet_source"):
			_robot_view.set_packet_source(_video_tcp_handler)
		_video_tcp_handler.connect_to_video_stream(host, port)
		_set_video_status(tr("UI_VIDEO_STATUS_OPERATOR_CONNECTING") % [host, port])

	if show_test:
		_begin_video_test(options)


func _begin_video_test(_options: Dictionary) -> void:
	_video_test_active = true
	_video_test_generation += 1
	if _robot_view and _robot_view.has_method("set_show_video_panel"):
		_robot_view.set_show_video_panel(true)
	_release_global_interaction_pointer()
	if _settings_panel and _settings_panel.has_method("close"):
		_settings_panel.close()
	elif _settings_panel:
		_settings_panel.visible = false
	if _settings_button:
		if _settings_button.has_method("set_video_preview_mode"):
			_settings_button.call("set_video_preview_mode", true)
		_settings_button.visible = true
	_watch_video_test_first_frame(_video_test_generation)


func _watch_video_test_first_frame(generation: int) -> void:
	if not is_inside_tree():
		return
	await get_tree().create_timer(VIDEO_TEST_FIRST_FRAME_TIMEOUT_SEC).timeout
	_handle_video_test_first_frame_timeout(generation)


func _handle_video_test_first_frame_timeout(generation: int) -> void:
	if not _video_test_active or generation != _video_test_generation:
		return
	if _video_is_streaming():
		# Streaming means the preview succeeded; leave the operator in test
		# mode with video visible until they dismiss it with × or Confirm.
		return
	_set_video_status(tr("UI_VIDEO_STATUS_TEST_TIMEOUT"))
	_end_video_test()
	_show_settings_panel()


func _end_video_test() -> void:
	if not _video_test_active:
		return
	_video_test_active = false
	_video_test_generation += 1
	# The video panel should only be visible while a test is running, while the
	# operator has confirmed to start teleop (see `_apply_runtime_settings`), or
	# when a robot-authored blueprint declares it visible. Ending the test drops
	# it back to hidden unless a blueprint owns visibility for the active
	# outside/operator session — in that case restore what the blueprint said.
	if _robot_view and _robot_view.has_method("set_show_video_panel"):
		var restore_visible := false
		if _active_target == _outside_target:
			restore_visible = bool(
				_blueprint_external_view_visibility.get("video_panel", false)
			)
		_robot_view.set_show_video_panel(restore_visible)
	if _settings_button and _settings_button.has_method("set_video_preview_mode"):
		_settings_button.call("set_video_preview_mode", false)


func _video_is_streaming() -> bool:
	return (
		_robot_view != null
		and _robot_view.has_method("is_receiving_video")
		and bool(_robot_view.call("is_receiving_video"))
	)


func _return_from_failed_video_test() -> void:
	if not _video_test_active:
		return
	_end_video_test()
	_show_settings_panel()


func _on_video_test_exit_button_pressed(action: StringName) -> void:
	if not _video_test_active:
		return
	if action != &"menu_button" and action != &"by_button":
		return
	_end_video_test()
	_show_settings_panel()


func _set_video_status(text: String) -> void:
	print("[Operator] %s" % text)
	if _settings_ui and _settings_ui.has_method("set_video_status"):
		_settings_ui.call("set_video_status", text)


func _on_xrt_video_connected() -> void:
	if _manual_video_protocol != VIDEO_PROTOCOL_XROBOT_TOOLKIT:
		return
	_set_video_status(tr("UI_VIDEO_STATUS_XROBOT_TOOLKIT_CONNECTED"))


func _on_xrt_video_disconnected(reason: String = "") -> void:
	if _manual_video_protocol != VIDEO_PROTOCOL_XROBOT_TOOLKIT:
		return
	_set_video_status(
		tr("UI_VIDEO_STATUS_XROBOT_TOOLKIT_DISCONNECTED_REASON") % reason
		if not reason.is_empty()
		else tr("UI_VIDEO_STATUS_XROBOT_TOOLKIT_DISCONNECTED")
	)
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()
	_return_from_failed_video_test()


func _on_xrt_video_failed(reason: String) -> void:
	if _manual_video_protocol != VIDEO_PROTOCOL_XROBOT_TOOLKIT:
		return
	_set_video_status(tr("UI_VIDEO_STATUS_XROBOT_TOOLKIT_FAILED") % reason)
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()
	_return_from_failed_video_test()


func _on_xrt_video_frame_received(packet: Dictionary) -> void:
	if _manual_video_protocol != VIDEO_PROTOCOL_XROBOT_TOOLKIT:
		return
	var compatible_packet := packet.duplicate(true)
	compatible_packet["transport_loss_available"] = false
	if _robot_view and _robot_view.has_method("report_video_packet"):
		_robot_view.report_video_packet(compatible_packet)


func _on_device_connected(descriptor: Dictionary) -> void:
	var device_name: String = descriptor.get("device", {}).get("name", tr("UI_UNKNOWN"))
	var device_type: String = descriptor.get("device", {}).get("type", tr("UI_UNKNOWN"))
	_set_status(tr("UI_DRIVER_ACTIVE") % [device_name, _robot_type_display(device_type)])
	print("[Operator] Connected to %s (type=%s per descriptor)" % [device_name, device_type])
	if _outside_target:
		_outside_target.apply_descriptor(descriptor)
	_robot_control_sink.configure_for_device(descriptor)
	# The descriptor is authoritative. Activate the same hand controls and
	# feedback used by the feature test in the normal working-page lifecycle.
	_set_revo2_hand_runtime_enabled(
		_descriptor_supports_revo2_hand_runtime(descriptor)
	)
	_set_revo2_hand_control_unlocked(false)
	var xr_stream: Variant = descriptor.get("xr_stream", null)
	_sdk_mode = xr_stream is Dictionary
	if _sdk_mode:
		_xr_state_sender.configure(xr_stream as Dictionary)
	if _ee_pose_trajectory:
		_ee_pose_trajectory.configure_for_device(descriptor)
	# SDK mode consumes raw state in Python; robot-control mode emits
	# DeviceCommand. `_sync_stream_senders` keeps exactly one of them live.
	_sync_stream_senders()
	_on_tracking_sessions_changed()
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
		print(
			(
				"[TeleopSynthetic] descriptor device=%s dual=%s — engaging synthetic operator"
				% [
					device_type,
					str(_synth_dual),
				]
			)
		)
	if _teleop_controller_panel and _teleop_controller_panel.has_method("configure_for_device"):
		_teleop_controller_panel.call("configure_for_device", descriptor)
		_update_teleop_controller_panel()
	_configure_robot_video_stream(descriptor)
	# [issue 005 / item 1] After the descriptor arrives we now know
	# whether the robot is offering UDP. Re-call `_connect_video_stream`
	# so we can upgrade to UDP if the descriptor advertises it.
	if _tcp_handler.is_connected_to_robot():
		_connect_video_stream(_tcp_handler.get_host(), _tcp_handler.get_port())


func _on_device_disconnected() -> void:
	_set_revo2_hand_control_unlocked(false)
	_clear_blueprint_runtime()
	_sdk_mode = false
	_robot_control_sink.set_sending(false)
	_xr_state_sender.set_sending(false)
	if _ee_pose_trajectory:
		_ee_pose_trajectory.configure_for_device({})
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()
	if _outside_target:
		_outside_target.mark_transport_disconnected()


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
		for component in f:
			if (typeof(component) != TYPE_INT and typeof(component) != TYPE_FLOAT) \
				or not is_finite(float(component)):
				_control_frame_valid[hand] = false
				return
		var frame := Quaternion(float(f[0]), float(f[1]), float(f[2]), float(f[3]))
		var frame_length_squared := frame.length_squared()
		if is_finite(frame_length_squared) and frame_length_squared > 0.000001:
			_control_frame[hand] = frame.normalized()
			_control_frame_valid[hand] = true
		else:
			_control_frame_valid[hand] = false
	else:
		_control_frame_valid[hand] = false
	_control_frame_mirror[hand] = bool(values.get(mirror_key, true))


func _update_control_frame_gizmo() -> void:
	if not _control_frame_visualization_enabled:
		return
	for hand in [HAND_LEFT, HAND_RIGHT]:
		_update_control_frame_gizmo_for_hand(hand)


func _update_control_frame_gizmo_for_hand(hand: int) -> void:
	var gizmo: Node3D = _control_frame_gizmos.get(hand, null)
	if gizmo == null:
		return
	if not _control_frame_visualization_enabled:
		gizmo.visible = false
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
	(
		gizmo
		. apply(
			controller.global_transform.origin,
			_control_frame.get(hand, Quaternion.IDENTITY),
			bool(_control_frame_mirror.get(hand, true)),
		)
	)


func _hide_control_frame_gizmos() -> void:
	for gizmo_v in _control_frame_gizmos.values():
		var gizmo := gizmo_v as Node3D
		if gizmo != null:
			gizmo.visible = false


## ControlMode owns both the driving-hand latch and the deadman hysteresis, so
## the gizmo asks it rather than re-deriving either. Re-thresholding the raw grip
## here duplicated the constants AND cost an extra controller-input read every
## rendered frame -- the same per-frame cost that had to be stripped out of this
## file after it measurably cut the delivered command rate.
func _active_control_mode():
	if (
		_active_target == _inside_target
		and _inside_target != null
		and _inside_target.has_method("get_control_mode")
	):
		return _inside_target.call("get_control_mode")
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


func _on_robot_found(
	robot_name: String,
	ip: String,
	pose_port: int,
	video_port: int,
	telemetry_port: int,
	device_type: String,
	device_name: String
) -> void:
	# Discovery feed drives both (1) auto-reconnect of the video stream
	# when the descriptor matches the currently connected host, and (2)
	# the SettingsPanel's "Discovered" dropdown (per the D launch flow).
	if telemetry_port <= 0:
		telemetry_port = pose_port + TELEMETRY_PORT_OFFSET
	_known_robots[_operator_discovery_key(ip, pose_port)] = {
		"name": robot_name,
		"ip": ip,
		"pose_port": pose_port,
		"video_port": video_port,
		"telemetry_port": telemetry_port,
		"device_type": device_type,
		"device_name": device_name,
		"protocol": "operator",
		# Marks which listener owns this entry. The XRoboToolkit beacon defers to
		# native announcements only for metadata, not for endpoint identity.
		"source": "operator",
	}
	# Push live update to the panel iff it's currently visible — when the
	# panel is open, the dropdown should mirror discovery in real time.
	if (
		_settings_panel
		and _settings_panel.visible
		and _settings_ui
		and _settings_ui.has_method("set_discovery_state")
	):
		_push_discovery_to_settings_ui()
	if (
		_tcp_handler.is_connected_to_robot()
		and _tcp_handler.get_host() == ip
		and _tcp_handler.get_port() == pose_port
	):
		_active_telemetry_port = telemetry_port
		_connect_telemetry_stream(ip)
		_connect_video_stream(ip, pose_port)


## XRoboToolkit's beacon carries only an address and a clock reading — no name,
## no ports, no device type. Everything else is filled from the protocol's fixed
## service port so the entry can sit in the same dropdown as native robots.
func _start_xrt_discovery() -> void:
	# XRoboToolkit compatibility is Pico-only; other platforms never listen for
	# its beacon, so its hosts never appear in the discovery dropdown.
	if not PicoPlatformAdapter.is_pico_build():
		return
	var script: Variant = load(XROBOT_TOOLKIT_DISCOVERY_PATH)
	if script == null:
		push_warning("[Operator] Cannot load the XRoboToolkit discovery listener")
		return
	var instance: Variant = script.new()
	if not (instance is Node):
		push_warning("[Operator] Cannot instantiate the XRoboToolkit discovery listener")
		return
	_xrt_discovery = instance
	_xrt_discovery.name = "XRobotToolkitDiscovery"
	_xrt_discovery.connect("host_found", Callable(self, "_on_xrt_host_found"))
	_xrt_discovery.connect("host_lost", Callable(self, "_on_xrt_host_lost"))
	add_child(_xrt_discovery)
	_xrt_discovery.call("start_scan")


func _xrt_robot_name(ip: String) -> String:
	return "XRoboToolkit %s" % ip


func _on_xrt_host_found(ip: String, port: int, _timestamp_ms: int) -> void:
	var robot_name := _xrt_robot_name(ip)
	var info := {
		"name": robot_name,
		"ip": ip,
		"pose_port": port,
		"video_port": 0,
		"telemetry_port": 0,
		"device_type": XROBOT_TOOLKIT_DEVICE_TYPE,
		"device_name": "",
		"source": XROBOT_TOOLKIT_DEVICE_TYPE,
		# Consumed by the settings panel to preselect the matching protocol, so
		# picking a beacon from the dropdown connects without a second manual
		# choice the user has no way to know they need to make.
		"protocol": "xrobot_toolkit_v1",
	}
	_known_robots[_xrt_discovery_key(ip, port)] = info
	if (
		_settings_panel
		and _settings_panel.visible
		and _settings_ui
		and _settings_ui.has_method("set_discovery_state")
	):
		_push_discovery_to_settings_ui()


func _on_xrt_host_lost(ip: String) -> void:
	var removed := false
	for key in _known_robots.keys():
		var existing: Dictionary = _known_robots[key]
		if (
			str(existing.get("source", "")) == XROBOT_TOOLKIT_DEVICE_TYPE
			and _known_robot_ip(key, existing) == ip
		):
			_known_robots.erase(key)
			removed = true
	if not removed:
		return
	if (
		_settings_panel
		and _settings_panel.visible
		and _settings_ui
		and _settings_ui.has_method("set_discovery_state")
	):
		_push_discovery_to_settings_ui()


func _on_robot_lost(_robot_name: String, ip: String, pose_port: int) -> void:
	var key := _operator_discovery_key(ip, pose_port)
	var info: Dictionary = _known_robots.get(key, {})
	if info.is_empty():
		return
	var endpoint_was_active: bool = (
		_tcp_handler.is_connected_to_robot()
		and _tcp_handler.get_host() == ip
		and _tcp_handler.get_port() == pose_port
	)
	if not _known_robots.erase(key):
		return
	if endpoint_was_active and _video_tcp_handler.is_connected_to_robot():
		_video_tcp_handler.disconnect_from_robot()
	if endpoint_was_active and _video_udp_handler.is_connected_to_robot():
		_video_udp_handler.disconnect_from_robot()
	if endpoint_was_active and _telemetry_tcp_handler.is_connected_to_robot():
		_telemetry_tcp_handler.disconnect_from_robot()
	if (
		_settings_panel
		and _settings_panel.visible
		and _settings_ui
		and _settings_ui.has_method("set_discovery_state")
	):
		_push_discovery_to_settings_ui()


func _connect_video_stream(ip: String, pose_port: int = 0) -> void:
	if not _manual_video_options.is_empty():
		_connect_configured_video(_manual_video_options, false)
		return
	if ip.is_empty():
		return

	# Resolve the TCP port: prefer the descriptor's primary feed, then
	# the discovery announcement, then the legacy default.
	var tcp_port := 12345
	var info := _find_known_robot(ip, "operator", pose_port)
	if not info.is_empty():
		tcp_port = int(info.get("video_port", tcp_port))
	if int(_last_video_feed.get("port", 0)) > 0:
		tcp_port = int(_last_video_feed["port"])

	var transport := _select_video_transport(_last_video_feed)
	var udp_port := int(_last_video_feed.get("udp_port", 0))

	# If the active transport is already pointed at the right host+port,
	# don't churn the connection — that flushes decoder state.
	if transport == "tcp":
		if (
			_video_tcp_handler.is_connected_to_robot()
			and _video_tcp_handler.get_host() == ip
			and _video_tcp_handler.get_port() == tcp_port
		):
			_video_udp_handler.disconnect_from_robot()
			_active_video_transport = "tcp"
			return
	else:
		if (
			_video_udp_handler.is_connected_to_robot()
			and _video_udp_handler.get_host() == ip
			and _video_udp_handler.get_port() == udp_port
		):
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


# --- Target lifecycle --------------------------------------------------------


func _bind_target_signals(target: Node) -> void:
	target.target_ready.connect(_on_target_ready.bind(target))
	target.state_changed.connect(_on_target_state_changed.bind(target))
	target.telemetry_received.connect(_on_target_telemetry.bind(target))
	target.warning_raised.connect(_on_target_warning.bind(target))
	target.faulted.connect(_on_target_fault.bind(target))


func _on_target_ready(descriptor: Dictionary, target: Node) -> void:
	if target != _active_target:
		return
	var execution: Dictionary = descriptor.get("execution", {})
	var kind := str(execution.get("kind", target.get("target_kind")))
	var environment := str(execution.get("environment", ""))
	_set_status(
		(
			"%s ready%s"
			% [
				"Inside Robot" if kind == "inside" else "Outside Robot",
				(" (%s)" % environment) if not environment.is_empty() else "",
			]
		)
	)
	if _teleop_controller_panel and _teleop_controller_panel.has_method("configure_for_device"):
		_teleop_controller_panel.call("configure_for_device", descriptor)
		_teleop_controller_panel.call("set_bridge_connected", true)
	_sync_stream_senders()
	_on_tracking_sessions_changed()


func _on_target_state_changed(_state: int, detail: String, target: Node) -> void:
	if target == _active_target and not detail.is_empty():
		_set_status(detail)


func _on_target_telemetry(data: Dictionary, target: Node) -> void:
	if target != _active_target:
		return
	if target == _inside_target:
		_on_telemetry_received(data)


func _on_target_warning(code: String, message: String, target: Node) -> void:
	if target != _active_target:
		return
	if code == "tracking_not_ready":
		_on_tracking_blocked({})
		return
	# Recoverable solve errors stay in the active session. Surface them in
	# logcat/the current status UI without opening Settings or suspending input.
	_set_status("%s: %s" % [code, message])


func _on_target_fault(code: String, message: String, target: Node) -> void:
	if target != _active_target:
		return
	_set_status("%s: %s" % [code, message])
	_show_settings_panel_with_status(message)


func _stop_active_target() -> void:
	_clear_blueprint_runtime()
	_robot_control_sink.set_sending(false)
	_xr_state_sender.shutdown()
	if _xrt_target != null:
		_xrt_target.set_control_enabled(false)
	if _teleop_controller_panel and _teleop_controller_panel.has_method("set_bridge_connected"):
		_teleop_controller_panel.call("set_bridge_connected", false)
	if _active_target != null:
		_active_target.stop()


func _disconnect_outside_media() -> void:
	if _tcp_handler:
		_tcp_handler.disconnect_from_robot()
	if _video_tcp_handler:
		_video_tcp_handler.disconnect_from_robot()
	if _video_udp_handler:
		_video_udp_handler.disconnect_from_robot()
	if _telemetry_tcp_handler:
		_telemetry_tcp_handler.disconnect_from_robot()
	# The XRobotToolkit FPV session is outside media too. Leaving it running
	# across a target switch kept its socket open to the old host and left it
	# wired up as the robot view's packet source, so the next target rendered
	# stale frames from the robot we just left.
	if _xrt_video_session:
		_xrt_video_session.call("stop")
	if _robot_view and _robot_view.has_method("clear_video_stream"):
		_robot_view.clear_video_stream()


# --- Synthetic (headless CI) autopilot ----------------------------------------


## Read an intent-extra / cmdline value. Android `--es KEY VAL` surfaces as the
## token `KEY=VAL`; the `KEY VAL` pair form is also accepted. Mirrors the
## convention used by mode_select and the mujoco device test.
## Start an Inside Robot session straight from launch arguments, taking the
## persisted panel settings for everything the arguments do not override. This
## is the same path the Confirm button takes, so what it exercises is the real
## startup rather than a test-only shortcut.
func _start_inside_from_launch_args() -> void:
	var options: Dictionary = SettingsUI.load_settings()
	options["target_scope"] = "inside"
	_apply_common_launch_overrides(options)
	var profile_id := _teleop_arg(TELEOP_KEY_PROFILE, "")
	if not profile_id.is_empty():
		options["inside_profile"] = profile_id
	var backend := _teleop_arg(TELEOP_KEY_BACKEND, "")
	if not backend.is_empty():
		options["retargeting_backend"] = backend
	print(
		"[Operator] Inside Robot launch override: profile=%s backend=%s"
		% [str(options.get("inside_profile", "")), str(options.get("retargeting_backend", ""))]
	)
	if _settings_panel and _settings_panel.has_method("close"):
		_settings_panel.close()
	else:
		_settings_panel.visible = false
	_settings_button.visible = true
	_set_menu_guards(false)
	_on_settings_applied(options)


func _apply_common_launch_overrides(options: Dictionary) -> void:
	var show_video_panel := _teleop_arg(TELEOP_KEY_SHOW_VIDEO_PANEL, "")
	_apply_show_video_panel_launch_override(options, show_video_panel)


static func _apply_show_video_panel_launch_override(options: Dictionary, raw: String) -> void:
	if not raw.is_empty():
		options["show_video_panel"] = _parse_boolean_flag(raw)


## Read a launch argument. Intent extras reach here as the dashed form that
## GodotApp.getCommandLine() maps them to (`operator.teleop.scope` ->
## `--operator-teleop-scope`); an extra that is not in that allowlist never
## arrives at all.
func _teleop_arg(key: String, fallback: String) -> String:
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
	return _teleop_flag_set(SYNTH_KEY_ENABLE)


func _teleop_flag_set(key: String) -> bool:
	return _parse_boolean_flag(_teleop_arg(key, ""))


static func _parse_boolean_flag(raw: String) -> bool:
	raw = raw.to_lower()
	return raw == "1" or raw == "true" or raw == "yes" or raw == "on"


## Swap the OpenXR TrackingProvider for the scripted source. Runs before the
## command sender is wired so it captures the synthetic provider.
func _maybe_setup_synthetic() -> void:
	if not _synthetic_flag_set():
		return
	_synthetic = true
	_synth_duration = float(_teleop_arg(SYNTH_KEY_DURATION, str(SYNTH_DEFAULT_DURATION)))
	_synth_host = _teleop_arg(TELEOP_KEY_HOST, "")
	_synth_port = int(_teleop_arg(TELEOP_KEY_PORT, str(SYNTH_DEFAULT_PORT)))

	var src: Node = SyntheticTeleopSourceScript.new()
	src.name = "SyntheticTeleopSource"
	add_child(src)
	# Retire the real XR-backed provider so it does no OpenXR work.
	if is_instance_valid(_tracking_provider):
		_tracking_provider.queue_free()
	_tracking_provider = src
	_synth_source = src
	print(
		(
			"[TeleopSynthetic] started duration=%.1fs host=%s port=%d"
			% [
				_synth_duration,
				"<discovery>" if _synth_host.is_empty() else _synth_host,
				_synth_port,
			]
		)
	)


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
	_finish_synthetic(
		"never engaged (no descriptor handshake within %ds)" % int(SYNTH_CONNECT_TIMEOUT_SEC)
	)


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
		moved = (
			_synth_left_max_delta >= SYNTH_MIN_JOINT_DELTA_DEG
			and _synth_right_max_delta >= SYNTH_MIN_JOINT_DELTA_DEG
		)
	else:
		moved = _synth_max_delta >= SYNTH_MIN_JOINT_DELTA_DEG
	print(
		(
			"[TeleopSynthetic] summary connected=%s engaged=%s dual=%s telemetry_frames=%d max_joint_delta_deg=%.3f left_delta=%.3f right_delta=%.3f first=%s last=%s"
			% [
				str(connected),
				str(_synth_engaged),
				str(_synth_dual),
				_synth_telemetry_count,
				_synth_max_delta,
				_synth_left_max_delta,
				_synth_right_max_delta,
				JSON.stringify(_synth_first_joints),
				JSON.stringify(_synth_last_joints),
			]
		)
	)
	if reason.is_empty() and connected and _synth_engaged and moved:
		if _synth_dual:
			print(
				(
					"[TeleopSynthetic] PASS both arms tracked synthetic operator (left=%.2f right=%.2f deg over %d frames)"
					% [
						_synth_left_max_delta,
						_synth_right_max_delta,
						_synth_telemetry_count,
					]
				)
			)
		else:
			print(
				(
					"[TeleopSynthetic] PASS arm tracked synthetic operator (max_joint_delta=%.2f deg over %d frames)"
					% [
						_synth_max_delta,
						_synth_telemetry_count,
					]
				)
			)
		_synth_quit(0)
	else:
		var why := reason
		if why.is_empty():
			if _synth_dual:
				why = (
					"connected=%s engaged=%s moved=%s (left=%.2f right=%.2f, need >=%.2f deg on BOTH)"
					% [
						str(connected),
						str(_synth_engaged),
						str(moved),
						_synth_left_max_delta,
						_synth_right_max_delta,
						SYNTH_MIN_JOINT_DELTA_DEG,
					]
				)
			else:
				why = (
					"connected=%s engaged=%s moved=%s (max_delta=%.2f < %.2f deg)"
					% [
						str(connected),
						str(_synth_engaged),
						str(moved),
						_synth_max_delta,
						SYNTH_MIN_JOINT_DELTA_DEG,
					]
				)
		push_error("[TeleopSynthetic] FAIL %s" % why)
		_synth_quit(2)


func _synth_quit(code: int) -> void:
	# Drop the deadman and the connection before quitting so the robot-side
	# watchdog safes the arm; the host script's trap de-energises regardless.
	if _tcp_handler and _tcp_handler.is_connected_to_robot():
		_tcp_handler.disconnect_from_robot()
	print("[TeleopSynthetic] exiting code=%d" % code)
	get_tree().quit(code)
