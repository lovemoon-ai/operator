extends Node3D
## Ego capture mode (the offline feature side of the launcher): UI, QR, local
## settings, play space, calibration, automation and metrics. What a capture
## mounts is interpreted by CapturePipeline from the Output selection
## (`capture_output`: local | ingest | both); the provider, its plugins and
## system permissions live in components/sources, push/pull transports in
## components/sinks + components/views, and the user-configured ingest server
## in session/ingest_session.gd. Nothing here talks to a plugin or a socket.

const ViewLockedCapturePanelScript := preload("res://scripts/ui/view_locked_capture_panel.gd")
const ViewLockedRecordControlScript := preload("res://scripts/ui/view_locked_record_control.gd")
const ViewLockedStatusPopupScript := preload("res://scripts/ui/view_locked_status_popup.gd")
const SettingsLauncherButtonScript := preload("res://scripts/ui/settings_launcher_button.gd")
const EgoQRScannerScript := preload("res://scripts/ui/ego_qr_scanner.gd")
const HandSkeletonOverlayScript := preload("res://scripts/xr/hand_skeleton_overlay.gd")
const QR_SCANNER_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const QR_TARGET_UPLOAD_URL := "upload_url"
const QR_TARGET_LIVE_SERVER := "live_server"
const LAUNCHER_SCENE := "res://scenes/main.tscn"

const DEFAULT_SAVE_ROOT := "/sdcard/DCIM/SpatialMP4"
const DEFAULT_RGB_BITRATE := 24000000
const DEFAULT_RGB_FPS := 30
const DEFAULT_RGB_CODEC := "hevc"
const SETTINGS_PANEL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const SETTINGS_BUTTON_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18, -0.5))
const RECORD_CONTROL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.18, -0.86))
const STATUS_POPUP_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18, -0.92))
const CUE_SAMPLE_RATE := 32000
const TRACKER_STATUS_REFRESH_SECONDS := 0.5
const TRACKER_SETUP_OPENING_SECONDS := 4.0
const DEFAULT_PICO_BODY_TRACKERS := 2
const XR_TRACKING_STABLE_SECONDS := 0.75
const XR_TRACKING_WAIT_TIMEOUT_SECONDS := 15.0
const XR_TRACKING_POLL_SECONDS := 0.1
const EXPORT_SPACE_APPLY_TIMEOUT_SECONDS := 2.0
const MIN_QUEST_HORIZON_OS_VERSION := 76
const QUEST_OS_UPGRADE_WARNING_SECONDS := 10.0
const OPERATOR_INPUT_PLUGIN_SINGLETON := &"OperatorInputPlugin"
## Launch-argument keys (`operator.capture.<key>=` / `--operator-capture-<key>`)
## that select the Output and its ingest endpoint for automation.
const AUTOMATION_STRING_ARGS := ["output", "server_host", "server_auth_token"]
const AUTOMATION_PORT_ARGS := ["server_port", "server_result_port"]
@export var auto_start := false
@export var pose_sample_hz := 90.0
@export var keep_passthrough_visible := true
@export var default_live_server_host := "127.0.0.1"
@export var default_live_server_port := 63910
@export var default_live_result_port := 63912
@export var default_live_server_auth_token := ""
@export var enable_live_pull := true
# Optional host-driven validation override: flip to true (and rebuild/install)
# to start a recording at _ready(), let it run for AUTO_STOP_AFTER_SECONDS,
# then stop and quit. Designed for adb-driven smoke runs from a desktop while
# the headset is worn (Quest Guardian blocks launches while the proximity
# sensor reports no user).
const AUTO_START_FOR_DEVICE_TEST := false
const AUTO_STOP_AFTER_SECONDS := 12.0

var xr_interface: XRInterface
var origin: XROrigin3D
var world_environment: WorldEnvironment
var hmd_camera: XRCamera3D
var left_controller: XRController3D
var right_controller: XRController3D
var left_pointer: XRController3D
var right_pointer: XRController3D
var settings_panel
var settings_button
var record_control
var status_popup
var _hand_skeleton_overlay: Node3D = null
## Capture composition interpreter: sources, sinks, lifecycle.
var _pipeline: CapturePipeline
## The user-configured ingest server; null unless the Output includes ingest.
var _ingest: IngestSession = null
var live_pull_view: DenseMapView
var ego_uploader: Node
var qr_scanner: Object
var _endpoint_verifier: EndpointVerifier
var _qr_scan_target := ""
var _active_upload_session_id := ""
var _upload_popup_hold_until_msec := 0
var _pending_upload_popup_update: Dictionary = {}
var _upload_popup_timer_armed := false
var cue_player: AudioStreamPlayer
var _start_cue: AudioStreamWAV
var _stop_cue: AudioStreamWAV
# WP2: platform capability registry — the only sanctioned route to vendor
# plugin singletons (see xr/scripts/platform/).
var _platform: PlatformRegistry
var pico_openxr_bridge: Object
var _tracking_sessions: TrackingSessionService
var _pico_calibration_report: Dictionary = {}
## Currently displayed input-source mismatch text ("" when there is none).
## Kept so the notice is only re-emitted when it actually changes.
var _input_source_notice := ""
var capture_options := {
	"interaction_mode": "controllers",
	# Where a capture goes: local recording, the ingest server, or both.
	"capture_output": EgoCaptureComposition.OUTPUT_LOCAL,
	"stereo_rgb": true,
	"export_coordinate_space": OpenXRExportSpace.DEFAULT,
	"record_depth": true,
	"record_head_pose": true,
	"record_controller_pose": true,
	"record_hand_data": true,
	"record_body_tracking": true,
	"record_motion_trackers": true,
	"max_motion_trackers": DEFAULT_PICO_BODY_TRACKERS,
	# Runtime-only VST overlay. This is deliberately stripped from the
	# effective recording options before writer/samplers see them.
	"show_hand_skeleton_overlay": true,
	# v3 spatial audio: on by default ("Audio" toggle in the settings panel).
	# The pipeline still gates on the Android RECORD_AUDIO runtime permission;
	# a denied prompt degrades the session to video-only.
	"record_audio": true,
	# Encoder shape. Mirrors AudioCapture.DEFAULT_* on the Kotlin side.
	"audio_channel_layout": "stereo",
	"audio_sample_rate_hz": 48000,
	"audio_bitrate_bps": 128000,
	"rgb_bitrate": DEFAULT_RGB_BITRATE,
	"rgb_fps": DEFAULT_RGB_FPS,
	"rgb_width": 0,
	"rgb_height": 0,
	"rgb_resolution": "",
	"rgb_codec": DEFAULT_RGB_CODEC,
	"server_host": "127.0.0.1",
	"server_port": 63910,
	"server_result_port": 63912,
	"save_root": DEFAULT_SAVE_ROOT
}

# The recording lifecycle is owned by the pipeline's CaptureSessionController;
# `_recording` is a read-only view over its state machine.
var _recording: bool:
	get:
		return _pipeline != null and _pipeline.is_recording()
var _capture_started_ticks_us := 0
var _xr_session_begun := false
var _export_space_start_pending := false
var _capture_start_cancel_requested := false
var _passthrough_active := false
var _scene_transition_target := ""
var _previous_transparent_bg := false
var _previous_environment_blend_mode := XRInterface.XR_ENV_BLEND_MODE_OPAQUE
var _previous_background_mode := Environment.BG_CLEAR_COLOR
var _previous_background_color := Color.BLACK

# 1Hz metrics ticker: emits a single "QcMetrics" log line per second.
const METRICS_INTERVAL_S := 1.0
var _metrics_accum_s := 0.0
var _metrics_process_ticks := 0
var _view_pose_log_accum_s := 0.0
var _tracker_status_refresh_accum := TRACKER_STATUS_REFRESH_SECONDS
var _tracker_setup_opened_ticks_us := 0
var _last_capture_interaction_mode := ""
var _motion_tracker_supported_pushed := false
var _motion_tracker_provider_known := false
var _depth_supported_pushed := false
var _depth_provider_known := false
var _rgb_recording_provider_pushed := ""
var _rgb_camera_capabilities_pushed := false
var _rgb_camera_capability_next_probe_us := 0
var _quit_after_rgb_capability_probe := false
var _quest_os_upgrade_warning_shown := false
var _quest_os_upgrade_warning_pending := false
# Per-stage main-thread budgets (microseconds, reset every metrics window).
var _stage_us_panel := 0
var _stage_us_pointer := 0
var _stage_us_record_ctl := 0
var _stage_us_emit_metrics := 0


func _ready() -> void:
	_set_volume_buttons_captured(true)
	_setup_xr_scene()
	_setup_pico_openxr_bridge()
	_bind_operator_interaction()
	# The QR scanner is created inside _setup_xr_scene() — before the Pico
	# bridge resolves — so hand it over here. On Pico the scanner sources
	# frames from XR_PICO_camera_image (PicoOS has no Camera2 passthrough
	# id for the Kotlin plugin to open); the bridge may legitimately be
	# null off-Pico, in which case the scanner keeps its Camera2 path.
	if qr_scanner != null and qr_scanner.has_method("set_pico_bridge"):
		qr_scanner.set_pico_bridge(pico_openxr_bridge)
	_apply_automation_args()
	_sync_operator_interaction_override()
	_apply_capture_interaction_mode(_current_ui_interaction_mode())
	_initialize_openxr()
	_setup_audio_cues()

	_pipeline = CapturePipeline.new()
	_pipeline.name = "CapturePipeline"
	_pipeline.pose_sample_hz = pose_sample_hz
	add_child(_pipeline)
	_pipeline.setup(hmd_camera, left_controller, right_controller, pico_openxr_bridge, _platform_registry())
	_pipeline.session_opened.connect(_on_capture_session_opened)
	_pipeline.session_started.connect(_on_capture_session_started)
	_pipeline.session_stopped.connect(_on_capture_session_stopped)
	_note_provider_bound()
	_setup_uploader()

	var automation := _capture_automation_options_from_args()
	_apply_capture_automation_options(automation)
	_apply_output(str(capture_options.get("capture_output", EgoCaptureComposition.OUTPUT_LOCAL)))

	if bool(automation.get("auto_start", false)):
		call_deferred(
			"_start_capture_when_xr_tracking_ready",
			"capture automation",
			float(automation.get("auto_stop_seconds", AUTO_STOP_AFTER_SECONDS))
		)
	elif AUTO_START_FOR_DEVICE_TEST:
		capture_options["interaction_mode"] = "head"
		if settings_panel and settings_panel.has_method("set_options"):
			settings_panel.set_options(capture_options)
		call_deferred("start_capture")
		_schedule_auto_stop_for_device_test(AUTO_STOP_AFTER_SECONDS)
	elif auto_start:
		call_deferred("_start_capture_when_xr_tracking_ready", "auto_start", 0.0)


## EgoUploader drains user://ego_upload_queue.json. The UploadQueueSink owns
## the uploader (queue file / TUS behavior / signals); this scene keeps the
## node's tree lifecycle and the UI signal glue.
func _setup_uploader() -> void:
	ego_uploader = _pipeline.upload_sink().uploader()
	ego_uploader.name = "EgoUploader"
	add_child(ego_uploader)
	ego_uploader.upload_started.connect(_on_upload_started)
	ego_uploader.upload_progress.connect(_on_upload_progress)
	ego_uploader.upload_finished.connect(_on_upload_finished)
	ego_uploader.upload_failed.connect(_on_upload_failed)
	ego_uploader.upload_cancelled.connect(_on_upload_cancelled)
	ego_uploader.session_uploaded.connect(_on_session_uploaded)
	ego_uploader.queue_changed.connect(_on_upload_queue_changed)

	_endpoint_verifier = EndpointVerifier.new()
	_endpoint_verifier.name = "EndpointVerifier"
	_endpoint_verifier.checking.connect(_on_upload_ack_checking)
	_endpoint_verifier.resolved.connect(_apply_scanned_upload_endpoint)
	_endpoint_verifier.failed.connect(_on_upload_ack_failed)
	add_child(_endpoint_verifier)


## Mounts the sinks for an Output selection and mounts / drops the ingest
## session with it. Ignored while recording.
func _apply_output(output: String) -> void:
	if _recording:
		return
	var normalized := EgoCaptureComposition.normalize_output(output)
	capture_options["capture_output"] = normalized
	_pipeline.set_output(normalized, Callable(self, "_ensure_capture_start_ready"))
	var wants_ingest := _pipeline.streams_to_ingest()
	if wants_ingest and _ingest == null:
		if enable_live_pull:
			live_pull_view = DenseMapView.new()
			live_pull_view.name = "DenseMapView"
			# Head-lock the dense-map minimap to the HMD so the scaled-down
			# cloud stays pinned in front of the user instead of riding XROrigin.
			live_pull_view.configure(hmd_camera, DenseMapView.DISPLAY_MINIMAP)
			origin.add_child(live_pull_view)
		_ingest = IngestSession.new(_pipeline.live_push_sink(), live_pull_view)
		_ingest.connectivity_changed.connect(_set_live_server_connectivity_status)
		_ingest.capture_request_received.connect(_on_capture_request_received)
	elif not wants_ingest and _ingest != null:
		_ingest.disconnect_results()
		_ingest = null
		if live_pull_view != null:
			live_pull_view.queue_free()
			live_pull_view = null
		_pipeline.live_push_sink().clear_target()
		_update_input_source_mismatch_notice()
	if _ingest != null:
		_ingest.configure(capture_options)
	if record_control != null:
		record_control.set_streaming_only(not _pipeline.records_locally())


func _apply_automation_args() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	var i := 0
	while i < args.size():
		var arg_value := args[i]
		var arg := String(arg_value).strip_edges()
		if arg == "--operator-auto-start":
			auto_start = true
		elif arg.begins_with("operator.auto_start="):
			auto_start = _truthy_string(arg.substr("operator.auto_start=".length()))
		i += 1


func _truthy_string(value: String) -> bool:
	var text := value.strip_edges().to_lower()
	return text == "true" or text == "1" or text == "yes" or text == "on"


func _schedule_auto_stop_for_device_test(seconds: float) -> void:
	if seconds <= 0.0:
		return
	var auto_stop_timer := Timer.new()
	auto_stop_timer.name = "AutoStopForDeviceTest"
	auto_stop_timer.one_shot = true
	auto_stop_timer.wait_time = seconds
	auto_stop_timer.timeout.connect(_auto_stop_for_device_test)
	add_child(auto_stop_timer)
	auto_stop_timer.start()


func _auto_stop_for_device_test() -> void:
	print("AUTO_STOP_FOR_DEVICE_TEST: stopping capture")
	stop_capture()
	await get_tree().create_timer(2.0).timeout
	print("AUTO_STOP_FOR_DEVICE_TEST: quitting")
	get_tree().quit()


func _start_capture_when_xr_tracking_ready(reason: String, auto_stop_seconds: float = 0.0) -> void:
	var stable := await _wait_for_xr_head_pose_tracking_stable(reason)
	if not stable:
		push_warning("[CaptureApp] XR tracking did not stabilize; skipping %s" % reason)
		return
	if _recording:
		return
	await start_capture()
	if auto_stop_seconds > 0.0 and _recording:
		_schedule_auto_stop_for_device_test(auto_stop_seconds)


func _wait_for_xr_head_pose_tracking_stable(reason: String) -> bool:
	if not _should_wait_for_xr_tracking():
		return true

	print("[CaptureApp] waiting for XR head pose tracking before %s" % reason)
	var wait_start_us := Time.get_ticks_usec()
	var stable_start_us := 0
	var timeout_us := int(XR_TRACKING_WAIT_TIMEOUT_SECONDS * 1000000.0)
	var stable_us := int(XR_TRACKING_STABLE_SECONDS * 1000000.0)
	while is_inside_tree() and Time.get_ticks_usec() - wait_start_us < timeout_us:
		if _xr_head_pose_confident():
			if stable_start_us <= 0:
				stable_start_us = Time.get_ticks_usec()
			elif Time.get_ticks_usec() - stable_start_us >= stable_us:
				var waited_s := float(Time.get_ticks_usec() - wait_start_us) / 1000000.0
				print("[CaptureApp] XR tracking stable after %.2fs before %s" % [waited_s, reason])
				return true
		else:
			stable_start_us = 0
		await get_tree().create_timer(XR_TRACKING_POLL_SECONDS).timeout

	push_warning("[CaptureApp] XR tracking stability wait timed out before %s" % reason)
	return false


func _should_wait_for_xr_tracking() -> bool:
	if OS.has_feature("quest"):
		return true
	return _pipeline != null and _pipeline.ensure_bound() and _pipeline.camera.provider_name == "quest"


func _xr_head_pose_confident() -> bool:
	var tracker := XRServer.get_tracker(&"head")
	if not (tracker is XRPositionalTracker):
		return false
	var positional := tracker as XRPositionalTracker
	if not positional.has_pose(&"default"):
		return false
	var pose := positional.get_pose(&"default")
	if pose == null:
		return false
	return int(pose.get_tracking_confidence()) != XRPose.XR_TRACKING_CONFIDENCE_NONE


func _capture_automation_options_from_args() -> Dictionary:
	var options := {}
	_collect_capture_automation_args(options, OS.get_cmdline_user_args())
	_collect_capture_automation_args(options, OS.get_cmdline_args())
	return options


func _apply_capture_automation_options(automation: Dictionary) -> void:
	var changed := false
	_quit_after_rgb_capability_probe = bool(automation.get("capability_probe", false))
	changed = changed or _quit_after_rgb_capability_probe
	if automation.has("interaction_mode"):
		var interaction_mode := str(automation["interaction_mode"])
		capture_options["interaction_mode"] = interaction_mode
		# Automation is parsed after the initial interaction setup in _ready().
		# Apply the late override to the runtime and stream mutex as well as the
		# manifest label; RGB-only overrides below intentionally remain stronger.
		_sync_operator_interaction_override()
		_apply_capture_interaction_mode(interaction_mode)
		changed = true

	# Host-driven RGB matrix tests only need the encoded camera stream and a
	# head pose. Disable every optional/high-overhead stream and automatic
	# upload without changing or persisting the operator's saved settings.
	if bool(automation.get("rgb_only", false)):
		var rgb_only_overrides := {
			"stereo_rgb": true,
			"record_depth": false,
			"record_head_pose": true,
			"record_controller_pose": false,
			"record_hand_data": false,
			"record_body_tracking": false,
			"record_motion_trackers": false,
			"record_audio": false,
			"show_hand_skeleton_overlay": false,
			"upload_on_finalize": false,
		}
		_merge_capture_options(rgb_only_overrides)
		changed = true

	if automation.has("rgb_resolution"):
		var resolution := _parse_capture_resolution(str(automation["rgb_resolution"]))
		if resolution != Vector2i.ZERO:
			capture_options["rgb_width"] = resolution.x
			capture_options["rgb_height"] = resolution.y
			capture_options["rgb_resolution"] = CameraSource.rgb_resolution_text(resolution)
			changed = true

	if automation.has("export_coordinate_space"):
		capture_options["export_coordinate_space"] = OpenXRExportSpace.normalize(
			automation["export_coordinate_space"])
		changed = true

	if automation.has("save_root"):
		var save_root := str(automation["save_root"]).strip_edges()
		if not save_root.is_empty():
			capture_options["save_root"] = save_root
			changed = true

	# Output and ingest endpoint overrides (cicd/04 drives ingest through Ego).
	for key_v in AUTOMATION_STRING_ARGS + AUTOMATION_PORT_ARGS:
		var key := str(key_v)
		if not automation.has(key):
			continue
		var option_key := "capture_output" if key == "output" else key
		capture_options[option_key] = automation[key]
		changed = true

	if not changed:
		return
	# Keep the panel snapshot aligned so the later provider capability refresh
	# cannot restore a persisted resolution over the automation override.
	# set_options() only updates in-memory controls; it does not save settings.
	if settings_panel and settings_panel.has_method("set_options"):
		# The panel starts with Quest as its conservative fallback provider. On
		# Pico, applying 2048x1536 before selecting the detected provider would
		# clamp it to Quest's 1280x960 list. Bind the provider first so automation
		# is normalized against the correct platform-specific choices.
		if _pipeline != null and _pipeline.ensure_bound() and settings_panel.has_method("set_capture_provider_name"):
			var provider := _pipeline.camera.provider_name
			if not provider.is_empty():
				settings_panel.call("set_capture_provider_name", provider)
				_rgb_recording_provider_pushed = provider
		settings_panel.set_options(capture_options)
		if settings_panel.has_method("get_options"):
			_merge_capture_options(settings_panel.get_options())
			# Automation overrides win over the panel's persisted snapshot.
			for key_v in AUTOMATION_STRING_ARGS + AUTOMATION_PORT_ARGS:
				var key := str(key_v)
				if automation.has(key):
					capture_options["capture_output" if key == "output" else key] = automation[key]
	print(
		"Capture automation applied: interaction_mode=%s rgb_resolution=%s export_space=%s save_root=%s rgb_only=%s output=%s"
		% [
			str(capture_options.get("interaction_mode", "")),
			str(capture_options.get("rgb_resolution", "")),
			str(capture_options.get("export_coordinate_space", OpenXRExportSpace.DEFAULT)),
			str(capture_options.get("save_root", "")),
			str(bool(automation.get("rgb_only", false))),
			str(capture_options.get("capture_output", "")),
		]
	)


func _collect_capture_automation_args(options: Dictionary, args: PackedStringArray) -> void:
	var i := 0
	while i < args.size():
		var arg := String(args[i]).strip_edges()
		match arg:
			"--operator-capture-interaction-mode", "--capture-interaction-mode":
				if i + 1 < args.size():
					options["interaction_mode"] = _normalize_capture_interaction_mode(String(args[i + 1]))
					i += 1
			"--operator-capture-auto-start", "--capture-auto-start":
				if i + 1 < args.size() and not String(args[i + 1]).begins_with("--"):
					options["auto_start"] = _parse_capture_bool(String(args[i + 1]))
					i += 1
				else:
					options["auto_start"] = true
			"--operator-capture-auto-stop-seconds", "--capture-auto-stop-seconds":
				if i + 1 < args.size():
					options["auto_stop_seconds"] = _parse_capture_seconds(String(args[i + 1]), AUTO_STOP_AFTER_SECONDS)
					i += 1
			"--operator-capture-rgb-resolution", "--capture-rgb-resolution":
				if i + 1 < args.size():
					options["rgb_resolution"] = String(args[i + 1]).strip_edges()
					i += 1
			"--operator-capture-export-coordinate-space", "--capture-export-coordinate-space":
				if i + 1 < args.size():
					options["export_coordinate_space"] = String(args[i + 1]).strip_edges()
					i += 1
			"--operator-capture-save-root", "--capture-save-root":
				if i + 1 < args.size():
					options["save_root"] = String(args[i + 1]).strip_edges()
					i += 1
			"--operator-capture-rgb-only", "--capture-rgb-only":
				if i + 1 < args.size() and not String(args[i + 1]).begins_with("--"):
					options["rgb_only"] = _parse_capture_bool(String(args[i + 1]))
					i += 1
				else:
					options["rgb_only"] = true
			"--operator-capture-capability-probe", "--capture-capability-probe":
				if i + 1 < args.size() and not String(args[i + 1]).begins_with("--"):
					options["capability_probe"] = _parse_capture_bool(String(args[i + 1]))
					i += 1
				else:
					options["capability_probe"] = true
			_:
				if arg.begins_with("--operator-capture-interaction-mode="):
					options["interaction_mode"] = _normalize_capture_interaction_mode(arg.substr("--operator-capture-interaction-mode=".length()))
				elif arg.begins_with("--capture-interaction-mode="):
					options["interaction_mode"] = _normalize_capture_interaction_mode(arg.substr("--capture-interaction-mode=".length()))
				elif arg.begins_with("operator.capture.interaction_mode="):
					options["interaction_mode"] = _normalize_capture_interaction_mode(arg.substr("operator.capture.interaction_mode=".length()))
				elif arg.begins_with("--operator-capture-auto-start="):
					options["auto_start"] = _parse_capture_bool(arg.substr("--operator-capture-auto-start=".length()))
				elif arg.begins_with("--capture-auto-start="):
					options["auto_start"] = _parse_capture_bool(arg.substr("--capture-auto-start=".length()))
				elif arg.begins_with("operator.capture.auto_start="):
					options["auto_start"] = _parse_capture_bool(arg.substr("operator.capture.auto_start=".length()))
				elif arg.begins_with("--operator-capture-auto-stop-seconds="):
					options["auto_stop_seconds"] = _parse_capture_seconds(arg.substr("--operator-capture-auto-stop-seconds=".length()), AUTO_STOP_AFTER_SECONDS)
				elif arg.begins_with("--capture-auto-stop-seconds="):
					options["auto_stop_seconds"] = _parse_capture_seconds(arg.substr("--capture-auto-stop-seconds=".length()), AUTO_STOP_AFTER_SECONDS)
				elif arg.begins_with("operator.capture.auto_stop_seconds="):
					options["auto_stop_seconds"] = _parse_capture_seconds(arg.substr("operator.capture.auto_stop_seconds=".length()), AUTO_STOP_AFTER_SECONDS)
				elif arg.begins_with("--operator-capture-rgb-resolution="):
					options["rgb_resolution"] = arg.substr("--operator-capture-rgb-resolution=".length()).strip_edges()
				elif arg.begins_with("--capture-rgb-resolution="):
					options["rgb_resolution"] = arg.substr("--capture-rgb-resolution=".length()).strip_edges()
				elif arg.begins_with("operator.capture.rgb_resolution="):
					options["rgb_resolution"] = arg.substr("operator.capture.rgb_resolution=".length()).strip_edges()
				elif arg.begins_with("--operator-capture-export-coordinate-space="):
					options["export_coordinate_space"] = arg.substr("--operator-capture-export-coordinate-space=".length()).strip_edges()
				elif arg.begins_with("--capture-export-coordinate-space="):
					options["export_coordinate_space"] = arg.substr("--capture-export-coordinate-space=".length()).strip_edges()
				elif arg.begins_with("operator.capture.export_coordinate_space="):
					options["export_coordinate_space"] = arg.substr("operator.capture.export_coordinate_space=".length()).strip_edges()
				elif arg.begins_with("--operator-capture-save-root="):
					options["save_root"] = arg.substr("--operator-capture-save-root=".length()).strip_edges()
				elif arg.begins_with("--capture-save-root="):
					options["save_root"] = arg.substr("--capture-save-root=".length()).strip_edges()
				elif arg.begins_with("operator.capture.save_root="):
					options["save_root"] = arg.substr("operator.capture.save_root=".length()).strip_edges()
				elif arg.begins_with("--operator-capture-rgb-only="):
					options["rgb_only"] = _parse_capture_bool(arg.substr("--operator-capture-rgb-only=".length()))
				elif arg.begins_with("--capture-rgb-only="):
					options["rgb_only"] = _parse_capture_bool(arg.substr("--capture-rgb-only=".length()))
				elif arg.begins_with("operator.capture.rgb_only="):
					options["rgb_only"] = _parse_capture_bool(arg.substr("operator.capture.rgb_only=".length()))
				elif arg.begins_with("--operator-capture-capability-probe="):
					options["capability_probe"] = _parse_capture_bool(arg.substr("--operator-capture-capability-probe=".length()))
				elif arg.begins_with("--capture-capability-probe="):
					options["capability_probe"] = _parse_capture_bool(arg.substr("--capture-capability-probe=".length()))
				elif arg.begins_with("operator.capture.capability_probe="):
					options["capability_probe"] = _parse_capture_bool(arg.substr("operator.capture.capability_probe=".length()))
				else:
					i += _collect_endpoint_automation_arg(options, args, i)
		i += 1


## Output / ingest-endpoint arguments in the `operator.capture.<key>=value`,
## `--operator-capture-<key>=value` and `--operator-capture-<key> value` forms.
## Returns how many extra tokens were consumed.
func _collect_endpoint_automation_arg(options: Dictionary, args: PackedStringArray, index: int) -> int:
	var arg := String(args[index]).strip_edges()
	for key_v in AUTOMATION_STRING_ARGS + AUTOMATION_PORT_ARGS:
		var key := str(key_v)
		var flag := "--operator-capture-%s" % key.replace("_", "-")
		var raw := ""
		var consumed := 0
		if arg.begins_with("operator.capture.%s=" % key):
			raw = arg.substr(("operator.capture.%s=" % key).length())
		elif arg.begins_with(flag + "="):
			raw = arg.substr((flag + "=").length())
		elif arg == flag and index + 1 < args.size():
			raw = String(args[index + 1])
			consumed = 1
		else:
			continue
		raw = raw.strip_edges()
		if AUTOMATION_PORT_ARGS.has(key):
			if raw.is_valid_int() and int(raw) > 0 and int(raw) <= 65535:
				options[key] = int(raw)
		else:
			options[key] = EgoCaptureComposition.normalize_output(raw) if key == "output" else raw
		return consumed
	return 0


func _normalize_capture_interaction_mode(raw_mode: String) -> String:
	var mode := raw_mode.strip_edges().to_lower().replace("-", "_")
	match mode:
		"controller", "controllers":
			return "controllers"
		"hand", "hands":
			return "hands"
		"head", "head_button", "head_buttons", "volume", "volume_buttons":
			return "head"
		_:
			return mode


func _parse_capture_bool(raw_value: String) -> bool:
	var value := raw_value.strip_edges().to_lower()
	return value in ["1", "true", "yes", "on", "start", "auto"]


func _parse_capture_seconds(raw_value: String, fallback: float) -> float:
	var value := raw_value.strip_edges()
	if value.is_empty():
		return fallback
	if not value.is_valid_float():
		push_warning("Invalid capture auto-stop seconds: %s" % value)
		return fallback
	return max(value.to_float(), 0.0)


func _parse_capture_resolution(raw_value: String) -> Vector2i:
	var value := raw_value.strip_edges().to_lower().replace("×", "x")
	var parts := value.split("x", false, 2)
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		push_warning("Invalid capture RGB resolution: %s" % raw_value)
		return Vector2i.ZERO
	var resolution := Vector2i(int(parts[0]), int(parts[1]))
	if resolution.x <= 0 or resolution.y <= 0:
		push_warning("Invalid capture RGB resolution: %s" % raw_value)
		return Vector2i.ZERO
	return resolution


func _process(delta: float) -> void:
	_metrics_process_ticks += 1
	_metrics_accum_s += delta
	if _metrics_accum_s >= METRICS_INTERVAL_S:
		var t_metrics := Time.get_ticks_usec()
		_emit_metrics(_metrics_accum_s)
		_metrics_accum_s = 0.0
		_stage_us_emit_metrics += Time.get_ticks_usec() - t_metrics

	# 1 Hz head-pose source probe (see CameraSource.log_view_pose_probe).
	_view_pose_log_accum_s += delta
	if _view_pose_log_accum_s >= 1.0:
		_view_pose_log_accum_s = 0.0
		_pipeline.camera.log_view_pose_probe(hmd_camera)

	var t_panel := Time.get_ticks_usec()
	_update_view_locked_panel()
	_stage_us_panel += Time.get_ticks_usec() - t_panel

	var t_pointer := Time.get_ticks_usec()
	_update_operator_interaction_state()
	_update_hand_skeleton_overlay_state()
	_stage_us_pointer += Time.get_ticks_usec() - t_pointer
	_update_pico_tracker_setup_status(delta)
	if _note_provider_bound():
		_update_motion_tracker_support_flag()
		_update_depth_support_flag()
		_update_rgb_recording_provider()
		_pipeline.audio.prompt_up_front(bool(capture_options.get("record_audio", false)))

	if _recording and record_control:
		var t_record := Time.get_ticks_usec()
		var elapsed_seconds := float(Time.get_ticks_usec() - _capture_started_ticks_us) / 1000000.0
		record_control.update_elapsed_seconds(elapsed_seconds)
		_stage_us_record_ctl += Time.get_ticks_usec() - t_record
	_pipeline.tick(delta)


func _emit_metrics(window_s: float) -> void:
	var process_fps: float = _metrics_process_ticks / window_s
	var engine_fps: float = float(Engine.get_frames_per_second())
	var metrics := _pipeline.pop_metrics()
	var plugin_metrics: Dictionary = metrics.get("plugin", {})
	var pump_metrics: Dictionary = metrics.get("pump", {})
	var stages: Dictionary = metrics.get("stages_us", {})
	if not pump_metrics.is_empty():
		# Keep camera attribution on its own short line. The full QcMetrics
		# record can exceed Android logcat's per-line limit once OpenXR status
		# dictionaries are included, which previously hid the pump breakdown.
		print("QcCamera %.1fs pump=%s encoder=%s" % [
			window_s,
			_compact_dict(pump_metrics),
			_compact_dict(plugin_metrics),
		])
	# Compact one-liner so it doesn't drown the rest of logcat. Tagged
	# "QcMetrics" so adb logcat -s godot:V | grep QcMetrics gives a clean
	# table.
	print("QcMetrics %.1fs recording=%s engine_fps=%d process_fps=%.1f pose_loop_iters=%d stages_ms={panel=%.1f,pointer=%.1f,record=%.1f,camera=%.1f,pose=%.1f,depth=%.1f,metrics=%.1f} pose=%s depth=%s body_motion=%s plugin=%s muxer=%s" % [
		window_s,
		str(_recording),
		engine_fps,
		process_fps,
		int(metrics.get("pose_loop_iters", 0)),
		_stage_us_panel / 1000.0,
		_stage_us_pointer / 1000.0,
		_stage_us_record_ctl / 1000.0,
		int(stages.get("camera", 0)) / 1000.0,
		int(stages.get("pose", 0)) / 1000.0,
		int(stages.get("depth", 0)) / 1000.0,
		_stage_us_emit_metrics / 1000.0,
		_compact_dict(metrics.get("pose", {})),
		_compact_dict(metrics.get("depth", {})),
		_compact_dict(metrics.get("body_motion", {})),
		_compact_dict(plugin_metrics),
		_compact_dict(metrics.get("muxer", {}))
	])
	_metrics_process_ticks = 0
	_stage_us_panel = 0
	_stage_us_pointer = 0
	_stage_us_record_ctl = 0
	_stage_us_emit_metrics = 0


func _compact_dict(d: Dictionary) -> String:
	if d.is_empty():
		return "{}"
	var parts: Array = []
	for key in d.keys():
		parts.append("%s=%s" % [key, d[key]])
	return "{" + ",".join(parts) + "}"


func _exit_tree() -> void:
	_capture_start_cancel_requested = true
	_set_volume_buttons_captured(false)
	stop_capture()
	if _tracking_sessions != null:
		_tracking_sessions.release(self)
	if _ingest != null:
		_ingest.disconnect_results()
	var interaction := _operator_interaction()
	if interaction != null:
		if interaction.has_method("set_busy"):
			interaction.call("set_busy", false)
		if interaction.has_method("set_mode_override"):
			interaction.call("set_mode_override", "")
	# Keep passthrough alive while handing the already-running OpenXR session
	# back to the launcher. Stopping it here and starting it again from the new
	# scene races the vendor compositor; some runtimes do not recover passthrough
	# inside the same session even though the launcher nodes finished loading.
	# App shutdown and non-launcher transitions still perform normal cleanup.
	if not _preserve_passthrough_for_transition():
		_set_passthrough_visible(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_RESUMED:
		_reset_ui_input_state()
		# Track transient pause/resume in the capture state machine
		# (Running <-> Recovering). Bookkeeping only — `_recording` stays true
		# across Recovering, and request_stop() auto-resumes before stopping.
		if _pipeline != null:
			if what == NOTIFICATION_APPLICATION_PAUSED:
				_pipeline.notify_pause()
			else:
				_pipeline.notify_resume()

	# Device-test only: when the VR shell pauses the app (e.g. the headset is
	# doffed during a host-driven adb smoke run), the auto-stop Timer freezes and
	# the recording would otherwise be abandoned as a .partial.mp4. Finalize
	# synchronously on pause so the smoke run always yields a readable MP4.
	# Dormant in production because AUTO_START_FOR_DEVICE_TEST is false.
	if not AUTO_START_FOR_DEVICE_TEST:
		return
	if what == NOTIFICATION_APPLICATION_PAUSED and _recording:
		print("AUTO_STOP_FOR_DEVICE_TEST: paused, finalizing recording")
		stop_capture()


func _reset_ui_input_state() -> void:
	# The OperatorInteraction router resets its own input state on
	# pause/resume; mirror that here by releasing the active pointer.
	_release_ui_pointer()


func start_capture() -> void:
	if _recording:
		return
	if _pipeline == null:
		return
	if _export_space_start_pending:
		return
	if not _ensure_pico_capture_calibrated(capture_options):
		return
	_capture_start_cancel_requested = false
	_export_space_start_pending = true
	var export_space := OpenXRExportSpace.normalize(
		capture_options.get("export_coordinate_space", OpenXRExportSpace.DEFAULT))
	var export_space_ready := await _ensure_export_coordinate_space_ready(export_space)
	_export_space_start_pending = false
	var start_cancelled := _capture_start_cancel_requested
	_capture_start_cancel_requested = false
	if start_cancelled:
		print("Capture start cancelled before the session opened")
		return
	if not export_space_ready:
		push_error("Capture start blocked: OpenXR export coordinate space %s is unavailable" % export_space.to_upper())
		return
	capture_options["export_coordinate_space"] = export_space
	capture_options["export_coordinate_space_id"] = OpenXRExportSpace.coordinate_space_id(export_space)
	# RGB calibration remains a rigid transform relative to head. Consumers
	# obtain the selected-space camera pose with
	# T_export_camera = T_export_head * T_head_camera.
	capture_options["rgb_extrinsics_space"] = "head"
	# Normalize save_root before the options snapshot (the storage check runs
	# inside the controller's permission phase).
	if _pipeline.records_locally():
		capture_options["save_root"] = _configured_save_root()
	if _ingest != null:
		_ingest.configure(capture_options)
	# Storage / permission / writer failures log on their own; the session
	# callbacks below run synchronously when the start succeeds.
	_pipeline.start(_pipeline.effective_options(capture_options))


## Writer session opened; sources start right after this returns.
func _on_capture_session_opened(_session_dir: String) -> void:
	if _ingest != null:
		_ingest.connect_results()
	_update_operator_interaction_state()
	_capture_started_ticks_us = Time.get_ticks_usec()
	# Recording on Pico owns the XR_PICO_camera_image stream. Kick the QR
	# scanner off it before the camera starts — the stream's poll queue has a
	# single drain point, so two consumers would steal each other's frames.
	# Reachable with the scanner open via the volume-key shortcut.
	if qr_scanner != null and qr_scanner.has_method("set_external_capture_busy"):
		qr_scanner.set_external_capture_busy(_pipeline.camera.uses_pico_bridge())
	if record_control:
		record_control.set_recording(true)
	_update_hand_skeleton_overlay_state()
	# Park any in-flight upload while we capture — see
	# claw/issues/010-ego-data-upload.md "Trip-wires".
	if ego_uploader:
		ego_uploader.pause()


func _on_capture_session_started(_session_dir: String) -> void:
	_play_cue(_start_cue)
	print("Capture session started: %s" % _pipeline.writer().get_session_dir())


func stop_capture() -> void:
	if not _recording:
		return
	_pipeline.stop()


func _on_capture_session_stopped(final_path: String) -> void:
	var saved_session_dir := final_path
	_update_operator_interaction_state()
	# Recording released the camera stream; let the QR scanner use it again.
	if qr_scanner != null and qr_scanner.has_method("set_external_capture_busy"):
		qr_scanner.set_external_capture_busy(false)
	if record_control:
		record_control.set_recording(false)
	_update_hand_skeleton_overlay_state()
	_play_cue(_stop_cue)
	if _pipeline.streams_to_ingest():
		print("Live feed push stopped; live-pull remains connected for algorithm results")
	if not _pipeline.records_locally():
		if ego_uploader:
			ego_uploader.resume()
		return
	var upload_expected := _upload_config_available()
	if status_popup:
		if saved_session_dir.is_empty():
			var detail := _pipeline.last_error if not _pipeline.last_error.is_empty() else tr("UI_RECORDING_SAVE_FAILED_DETAIL")
			status_popup.show_error(detail)
			_upload_popup_hold_until_msec = 0
		else:
			var saved_popup_seconds := 1.35 if upload_expected else 2.0
			status_popup.show_saved_path(saved_session_dir, saved_popup_seconds)
			_upload_popup_hold_until_msec = Time.get_ticks_msec() + int(saved_popup_seconds * 1000.0) if upload_expected else 0
	print("Capture session stopped: %s" % saved_session_dir)

	# Hand the freshly-finalized session to the uploader. enqueue() is a
	# no-op when upload_url is empty or upload_on_finalize is off, so we
	# can always call it. Then resume the worker we paused at start so the
	# new job (and anything queued from a prior session) starts draining.
	var writer: Object = _pipeline.writer()
	if ego_uploader and writer:
		# The spool writer exposes OS-absolute paths once close() returned.
		var session_dir_for_upload: String = writer.get_session_dir_absolute() if writer.has_method("get_session_dir_absolute") else writer.get_session_dir()
		var mp4_for_upload: String = writer.get_output_mp4_path_absolute() if writer.has_method("get_output_mp4_path_absolute") else (saved_session_dir if saved_session_dir.ends_with(".mp4") else "")
		var session_id_for_upload := mp4_for_upload.get_file().get_basename()
		var queued := _pipeline.upload_sink().enqueue_session(session_dir_for_upload, mp4_for_upload, capture_options)
		if queued:
			_active_upload_session_id = session_id_for_upload
			if ego_uploader.has_method("prioritize"):
				ego_uploader.prioritize(session_id_for_upload)
			ego_uploader.resume()
		elif upload_expected:
			_active_upload_session_id = ""
			_queue_upload_ui(tr("UI_UPLOAD_NOT_QUEUED"), "", -1.0, "warning", 3.0)
		else:
			ego_uploader.resume()


func _setup_xr_scene() -> void:
	world_environment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = Environment.new()
	world_environment.environment.background_mode = Environment.BG_COLOR
	world_environment.environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	add_child(world_environment)

	origin = XROrigin3D.new()
	origin.name = "XROrigin3D"
	origin.current = true
	add_child(origin)

	hmd_camera = XRCamera3D.new()
	hmd_camera.name = "XRCamera3D"
	origin.add_child(hmd_camera)

	left_controller = XRController3D.new()
	left_controller.name = "LeftController"
	left_controller.tracker = &"left_hand"
	left_controller.pose = &"grip"
	origin.add_child(left_controller)

	right_controller = XRController3D.new()
	right_controller.name = "RightController"
	right_controller.tracker = &"right_hand"
	right_controller.pose = &"grip"
	origin.add_child(right_controller)

	left_pointer = XRController3D.new()
	left_pointer.name = "LeftAimPointer"
	left_pointer.tracker = &"left_hand"
	left_pointer.pose = &"aim"
	origin.add_child(left_pointer)

	right_pointer = XRController3D.new()
	right_pointer.name = "RightAimPointer"
	right_pointer.tracker = &"right_hand"
	right_pointer.pose = &"aim"
	origin.add_child(right_pointer)

	_hand_skeleton_overlay = HandSkeletonOverlayScript.new()
	_hand_skeleton_overlay.name = "HandSkeletonOverlay"
	if _hand_skeleton_overlay.has_method("set_xr_origin"):
		_hand_skeleton_overlay.call("set_xr_origin", origin)
	origin.add_child(_hand_skeleton_overlay)

	settings_panel = ViewLockedCapturePanelScript.new()
	settings_panel.name = "ViewLockedSettingsPanel"
	if settings_panel.has_method("set_live_server_defaults"):
		settings_panel.set_live_server_defaults(
			default_live_server_host,
			default_live_server_port,
			default_live_server_auth_token,
			default_live_result_port
		)
	settings_panel.saved.connect(_on_capture_settings_saved)
	settings_panel.tracker_connect_requested.connect(_on_tracker_connect_requested)
	settings_panel.tracker_calibration_confirm_requested.connect(_on_tracker_calibration_confirm_requested)
	settings_panel.exit_requested.connect(_on_exit_requested)
	# Camera button on the Upload URL row → open the QR scanner overlay.
	if settings_panel.has_signal("scan_upload_url_requested"):
		settings_panel.scan_upload_url_requested.connect(_on_scan_upload_url_requested)
	if settings_panel.has_signal("scan_live_server_requested"):
		settings_panel.scan_live_server_requested.connect(_on_scan_live_server_requested)
	if settings_panel.has_signal("connect_live_server_requested"):
		settings_panel.connect_live_server_requested.connect(_on_connect_live_server_requested)
	if settings_panel.has_signal("manual_upload_requested"):
		settings_panel.manual_upload_requested.connect(_on_manual_upload_requested)
	origin.add_child(settings_panel)

	# QR scanner overlay (Camera2 + ZXing). Sits in the same scene tree as
	# the settings panel so its OpenXR composition layer renders alongside
	# the others. Hidden by default; we open it on demand and close on
	# accept / cancel.
	qr_scanner = EgoQRScannerScript.new()
	qr_scanner.name = "EgoQRScanner"
	qr_scanner.payload_accepted.connect(_on_qr_payload_accepted)
	qr_scanner.cancelled.connect(_on_qr_cancelled)
	origin.add_child(qr_scanner)
	# Hydrate the panel through its own BaseSettingsPanel-backed loader so
	# every settings surface reads and writes through the same persistence
	# path.
	var persisted := ViewLockedCapturePanelScript.load_settings()
	persisted["server_host"] = str(persisted.get("server_host", default_live_server_host))
	persisted["server_port"] = int(persisted.get("server_port", default_live_server_port))
	persisted["server_result_port"] = int(persisted.get("server_result_port", default_live_result_port))
	persisted["server_auth_token"] = str(persisted.get("server_auth_token", default_live_server_auth_token))
	if settings_panel.has_method("set_options"):
		settings_panel.set_options(persisted)
	_merge_capture_options(settings_panel.get_options())

	record_control = ViewLockedRecordControlScript.new()
	record_control.name = "ViewLockedRecordControl"
	record_control.start_requested.connect(start_capture)
	record_control.stop_requested.connect(stop_capture)
	record_control.settings_requested.connect(_on_settings_requested)
	origin.add_child(record_control)

	settings_button = SettingsLauncherButtonScript.new()
	settings_button.name = "CaptureSettingsButton"
	settings_button.pressed.connect(_on_settings_requested)
	origin.add_child(settings_button)

	status_popup = ViewLockedStatusPopupScript.new()
	status_popup.name = "ViewLockedStatusPopup"
	if status_popup.has_signal("cancel_requested"):
		status_popup.cancel_requested.connect(_on_upload_cancel_requested)
	origin.add_child(status_popup)
	# Targets (qr_scanner, settings_panel, settings_button, status_popup,
	# record_control) self-register into the OperatorInteraction group, so we
	# no longer build an explicit target list here.


func _platform_registry() -> PlatformRegistry:
	if _platform == null:
		_platform = PlatformRegistry.create()
	return _platform


func _setup_pico_openxr_bridge() -> void:
	if pico_openxr_bridge != null:
		return
	var bridge_autoload := get_node_or_null("/root/PicoOpenXRBridge")
	if bridge_autoload != null and bridge_autoload.has_method("get_bridge"):
		pico_openxr_bridge = bridge_autoload.call("get_bridge")
		if pico_openxr_bridge != null:
			print("PicoOpenXRExtension bridge bound from autoload")
			return
	pico_openxr_bridge = _platform_registry().pico_adapter().openxr_bridge_native()
	if pico_openxr_bridge != null:
		print("PicoOpenXRExtension bridge bound from native singleton")
		return
	pico_openxr_bridge = _platform_registry().pico_adapter().instantiate_openxr_bridge()
	if pico_openxr_bridge != null:
		print("PicoOpenXRExtension bridge instantiated")


func _initialize_openxr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface:
		xr_interface.session_begun.connect(_on_openxr_session_begun)
		xr_interface.session_stopping.connect(_on_openxr_session_stopping)
		var viewport := get_viewport()
		if viewport != null:
			viewport.use_xr = true
	if xr_interface and not xr_interface.is_initialized():
		xr_interface.initialize()

	if xr_interface and xr_interface.is_initialized():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		call_deferred("_mark_openxr_session_active_if_needed")
	else:
		push_warning("OpenXR is not initialized; capture will only produce local test files.")


func _mark_openxr_session_active_if_needed() -> void:
	if _xr_session_begun:
		return
	if xr_interface and xr_interface.is_initialized():
		_on_openxr_session_begun()


func _set_passthrough_visible(enable: bool) -> void:
	if xr_interface == null or not xr_interface.is_initialized():
		return

	if enable:
		if _passthrough_active:
			return
		var supported_modes: Array = xr_interface.get_supported_environment_blend_modes()
		if not supported_modes.has(XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND):
			push_warning("OpenXR alpha blend mode is not supported; passthrough view is unavailable.")
			return

		_previous_transparent_bg = get_viewport().transparent_bg
		_previous_environment_blend_mode = xr_interface.environment_blend_mode
		_previous_background_mode = world_environment.environment.background_mode
		_previous_background_color = world_environment.environment.background_color

		get_viewport().transparent_bg = true
		world_environment.environment.background_mode = Environment.BG_COLOR
		world_environment.environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		if xr_interface.has_method("is_passthrough_supported") and xr_interface.has_method("start_passthrough"):
			if bool(xr_interface.call("is_passthrough_supported")):
				var start_result: Variant = xr_interface.call("start_passthrough")
				print("OpenXR start_passthrough returned: %s" % start_result)
		_passthrough_active = true
		print("OpenXR passthrough view enabled")
	else:
		if not _passthrough_active:
			return
		if xr_interface.has_method("stop_passthrough"):
			xr_interface.call("stop_passthrough")
		get_viewport().transparent_bg = _previous_transparent_bg
		world_environment.environment.background_mode = _previous_background_mode
		world_environment.environment.background_color = _previous_background_color
		xr_interface.environment_blend_mode = _previous_environment_blend_mode
		_passthrough_active = false
		print("OpenXR passthrough view disabled")


## Binds late-loading provider/sink plugins and runs the one-shot reaction to
## the provider appearing. Returns true once the provider is bound.
func _note_provider_bound() -> bool:
	if _pipeline == null:
		return false
	var was_bound := _pipeline.camera.is_bound()
	if not _pipeline.ensure_bound():
		return false
	if not was_bound or not _quest_os_upgrade_warning_pending:
		if _pipeline.camera.provider_name == "quest" and not _quest_os_upgrade_warning_pending and not _quest_os_upgrade_warning_shown:
			_quest_os_upgrade_warning_pending = true
			call_deferred("_show_quest_os_upgrade_warning")
	return true


func _on_openxr_session_begun() -> void:
	if _xr_session_begun:
		return
	_xr_session_begun = true
	_rgb_camera_capabilities_pushed = false
	_rgb_camera_capability_next_probe_us = 0
	var viewport := get_viewport()
	if viewport != null:
		viewport.use_xr = true
	_request_export_coordinate_space(
		capture_options.get("export_coordinate_space", OpenXRExportSpace.DEFAULT))
	if keep_passthrough_visible:
		_set_passthrough_visible(true)
	if _pipeline != null:
		_pipeline.on_xr_session_begun()


func _on_openxr_session_stopping() -> void:
	_xr_session_begun = false
	if _pipeline != null:
		_pipeline.on_xr_session_stopping()
	_set_passthrough_visible(false)


func _unhandled_key_input(event: InputEvent) -> void:
	var action := capture_action_for_key_event(event, _recording, _export_space_start_pending)
	if action.is_empty():
		return

	# Volume keys are an Ego hardware shortcut regardless of whether the active
	# XR interaction source is controllers or hands.
	print("Volume key requested ego capture %s" % action)
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()
	if action == &"start":
		print("Volume-up requested capture start")
		start_capture()
	elif action == &"cancel_start":
		print("Volume-down cancelled pending capture start")
		_capture_start_cancel_requested = true
	elif action == &"stop":
		print("Volume-down requested capture stop")
		stop_capture()


static func capture_action_for_key_event(
		event: InputEvent,
		recording: bool,
		start_pending: bool = false) -> StringName:
	if not (event is InputEventKey):
		return &""
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return &""
	var code := key_event.keycode
	if code == KEY_NONE:
		code = key_event.physical_keycode
	return capture_action_for_volume_key(code, recording, start_pending)


static func capture_action_for_volume_key(
		code: Key,
		recording: bool,
		start_pending: bool = false) -> StringName:
	if code == KEY_VOLUMEDOWN and start_pending:
		return &"cancel_start"
	if code == KEY_VOLUMEUP and not recording and not start_pending:
		return &"start"
	if code == KEY_VOLUMEDOWN and recording:
		return &"stop"
	return &""


func _set_volume_buttons_captured(captured: bool) -> void:
	if not OS.has_feature("android"):
		return
	if not Engine.has_singleton(OPERATOR_INPUT_PLUGIN_SINGLETON):
		if captured:
			push_warning("OperatorInputPlugin unavailable; volume keys will also change system volume")
		return
	var input_plugin := Engine.get_singleton(OPERATOR_INPUT_PLUGIN_SINGLETON)
	input_plugin.call("set_volume_buttons_captured", captured)


func _on_capture_settings_saved(options: Dictionary) -> void:
	if _recording:
		return
	var prev_record_audio := bool(capture_options.get("record_audio", false))
	_merge_capture_options(options)
	capture_options["export_coordinate_space"] = OpenXRExportSpace.normalize(
		capture_options.get("export_coordinate_space", OpenXRExportSpace.DEFAULT))
	_request_export_coordinate_space(capture_options["export_coordinate_space"])
	capture_options["save_root"] = _configured_save_root()
	_apply_output(str(capture_options.get("capture_output", EgoCaptureComposition.OUTPUT_LOCAL)))
	_register_saved_endpoints()
	_sync_operator_interaction_override()
	_update_hand_skeleton_overlay_state()
	_tracker_status_refresh_accum = TRACKER_STATUS_REFRESH_SECONDS
	_release_ui_pointer()
	record_control.show_for_mode(_current_ui_interaction_mode())
	_pipeline.prepare_storage(_configured_save_root())
	# If the operator just flipped Audio on, drop the once-per-session latch so
	# the next idle tick fires the system permission prompt.
	if not prev_record_audio and bool(capture_options.get("record_audio", false)):
		_pipeline.audio.rearm_prompt()
	# The settings panel already persisted this snapshot through
	# BaseSettingsPanel before emitting `saved`. Redact tokens in the log so
	# they do not land in adb logcat / crash.log uploads.
	var log_view := capture_options.duplicate(true)
	for secret_key in ["upload_token", "server_auth_token"]:
		if str(log_view.get(secret_key, "")) != "":
			log_view[secret_key] = "<redacted>"
	print("Capture options updated: %s" % JSON.stringify(log_view))


## Saved, working endpoints become referenceable by name for host-orchestrated
## local tasks (EndpointRegistry). Only what the user confirmed here counts.
func _register_saved_endpoints() -> void:
	var registry := EndpointRegistry.shared()
	var upload_url := str(capture_options.get("upload_url", "")).strip_edges()
	if not upload_url.is_empty() and bool(capture_options.get("upload_on_finalize", false)):
		registry.register_upload(upload_url, str(capture_options.get("upload_token", "")), true)
	if _ingest != null and settings_panel != null and bool(settings_panel.get("_live_server_connected")):
		registry.register_live(_ingest.host, _ingest.push_port, _ingest.result_port, _ingest.auth_token, true)


func _on_connect_live_server_requested(options: Dictionary) -> void:
	# Connecting before Save previews the endpoint: mount ingest if the panel's
	# Output selection asks for it, then open the result channel.
	_merge_capture_options(options)
	_apply_output(str(capture_options.get("capture_output", EgoCaptureComposition.OUTPUT_LOCAL)))
	if _ingest == null:
		return
	_ingest.configure(capture_options)
	_ingest.connect_results()


## The ingest server owns the stream selection: it tells us what its algorithm
## needs and we capture exactly that (StreamPlanner). Arrives on the result
## channel when the settings page connects, i.e. before any capture starts.
func _on_capture_request_received(request: Dictionary) -> void:
	if _ingest == null:
		return
	_merge_capture_options(_ingest.planner.apply_ingest_request(request, _last_capture_interaction_mode))
	if settings_panel != null and settings_panel.has_method("set_server_requested_streams"):
		settings_panel.set_server_requested_streams(
			_ingest.planner.requested_streams(), _ingest.planner.algorithm()
		)
	_update_input_source_mismatch_notice()


## Hand tracking and controller tracking are mutually exclusive, and which one
## is live is a physical fact. When the ingest algorithm wants the source the
## operator is not holding, ask them to switch rather than sending nothing.
func _update_input_source_mismatch_notice() -> void:
	var key := _ingest.planner.input_source_notice_key(_last_capture_interaction_mode) if _ingest != null else ""
	var message := tr(key) if not key.is_empty() else ""
	# De-duplicate so a flapping input-mode detector does not replay the
	# fade-in on every frame. _resync_capture_notice() clears this cache when
	# the panel reopens, because the panel's callout auto-hides on a timer.
	if message == _input_source_notice:
		return
	_input_source_notice = message
	if message.is_empty():
		if record_control != null and record_control.has_method("clear_status_notice"):
			record_control.call("clear_status_notice")
		if settings_panel != null and settings_panel.has_method("hide_capture_notice"):
			settings_panel.call("hide_capture_notice")
		return
	print("[Operator] Input source mismatch: %s" % message)
	# Surface in both places: the settings panel may be open (before capture)
	# or closed (during capture), and the operator needs to see it either way.
	if record_control != null and record_control.has_method("set_status_notice"):
		record_control.call("set_status_notice", message, "warning")
	if settings_panel != null and settings_panel.has_method("show_capture_notice"):
		settings_panel.call("show_capture_notice", message)


## Re-show the mismatch notice after the panel was reopened: its callout hides
## itself on a timer, so the cached "already shown" state has to be dropped.
func _resync_capture_notice() -> void:
	_input_source_notice = ""
	_update_input_source_mismatch_notice()


func _set_live_server_connectivity_status(text: String, level: String) -> void:
	if settings_panel != null and settings_panel.has_method("set_live_server_connectivity_status"):
		settings_panel.set_live_server_connectivity_status(text, level)


func _on_exit_requested() -> void:
	# Exit from the in-mode settings panel returns to the launcher so the user
	# can pick a different mode without restarting the app. The launcher's own
	# Exit card is what actually quits the process. Any active capture / result
	# channel is stopped first so we don't leak an MP4 muxer or a network reader.
	if not _scene_transition_target.is_empty():
		return
	print("[Operator] Capture exit requested — returning to mode select")
	_scene_transition_target = LAUNCHER_SCENE
	_release_ui_pointer()
	if _recording:
		stop_capture()
	if _ingest != null:
		_ingest.disconnect_results()
	# EgoUploader owns a worker thread. Ask it to leave any HTTP poll before
	# change_scene tears down this node and waits for that thread in _exit_tree().
	# Pending upload state is durable and resumes next time Ego is opened.
	if ego_uploader != null and ego_uploader.has_method("request_shutdown"):
		ego_uploader.call("request_shutdown")
	# Defer the scene change out of the SubViewport button input callback. A
	# direct change frees the panel while the same input event is still being
	# dispatched, producing Viewport::_push_unhandled_input_internal errors.
	call_deferred("_change_to_launcher")


func _change_to_launcher() -> void:
	await get_tree().process_frame
	var err := get_tree().change_scene_to_file(LAUNCHER_SCENE)
	if err != OK:
		_scene_transition_target = ""
		push_error("[Operator] Failed to return to launcher: %s" % err)


func _preserve_passthrough_for_transition() -> bool:
	return keep_passthrough_visible \
			and _passthrough_active \
			and _scene_transition_target == LAUNCHER_SCENE


func _update_view_locked_panel() -> void:
	if hmd_camera == null:
		return
	if settings_panel:
		settings_panel.transform = hmd_camera.transform * SETTINGS_PANEL_OFFSET
	if settings_button:
		settings_button.transform = hmd_camera.transform * SETTINGS_BUTTON_OFFSET
	if record_control:
		record_control.transform = hmd_camera.transform * RECORD_CONTROL_OFFSET
	if status_popup:
		status_popup.transform = hmd_camera.transform * STATUS_POPUP_OFFSET
	if qr_scanner and qr_scanner.visible:
		qr_scanner.transform = hmd_camera.transform * QR_SCANNER_OFFSET


func _update_operator_interaction_state() -> void:
	var interaction := _operator_interaction()
	if interaction != null and interaction.has_method("set_busy"):
		interaction.call("set_busy", _recording)


func _update_hand_skeleton_overlay_state() -> void:
	if _hand_skeleton_overlay == null:
		return
	var show_overlay := _pipeline != null and _pipeline.records_locally() \
			and _recording \
			and bool(capture_options.get("show_hand_skeleton_overlay", true)) \
			and _current_ui_interaction_mode() == "hands"
	if _hand_skeleton_overlay.has_method("set_enabled"):
		_hand_skeleton_overlay.call("set_enabled", show_overlay)
	else:
		_hand_skeleton_overlay.visible = show_overlay


func _current_ui_interaction_mode() -> String:
	var interaction := _operator_interaction()
	if interaction != null and interaction.has_method("get_current_mode"):
		return str(interaction.call("get_current_mode"))
	var configured := str(capture_options.get("interaction_mode", "controllers"))
	if configured == "head" or configured == "hands":
		return configured
	return "controllers"


func _release_ui_pointer() -> void:
	var interaction := _operator_interaction()
	if interaction != null and interaction.has_method("release_pointer"):
		interaction.call("release_pointer")


func _bind_operator_interaction() -> void:
	var interaction := _operator_interaction()
	if interaction == null:
		return
	if interaction.has_signal("input_mode_changed") \
			and not interaction.is_connected("input_mode_changed", Callable(self, "_on_global_interaction_mode_changed")):
		interaction.connect("input_mode_changed", Callable(self, "_on_global_interaction_mode_changed"))


func _operator_interaction() -> Node:
	if get_tree() == null:
		return null
	return get_tree().root.get_node_or_null("OperatorInteraction")


func _sync_operator_interaction_override() -> void:
	var interaction := _operator_interaction()
	if interaction == null or not interaction.has_method("set_mode_override"):
		return
	var configured := str(capture_options.get("interaction_mode", "controllers"))
	if configured == "head" or configured == "hands":
		interaction.call("set_mode_override", configured)
	else:
		interaction.call("set_mode_override", "")
	if interaction.has_method("set_busy"):
		interaction.call("set_busy", _recording)


func _on_global_interaction_mode_changed(mode: String) -> void:
	_apply_capture_interaction_mode(mode)


func _apply_capture_interaction_mode(mode: String) -> void:
	if mode.is_empty() or mode == _last_capture_interaction_mode:
		return
	_last_capture_interaction_mode = mode
	print("[Operator] Capture input mode: %s" % mode)
	_release_ui_pointer()
	if mode == "hands":
		capture_options["record_hand_data"] = true
		capture_options["record_controller_pose"] = false
	elif mode == "controllers":
		capture_options["record_controller_pose"] = true
		capture_options["record_hand_data"] = false
	# An ingest request wins over auto-detection.
	_narrow_to_ingest_request()
	if settings_panel != null and settings_panel.has_method("set_interaction_mode"):
		settings_panel.call("set_interaction_mode", mode)
	if record_control != null and record_control.visible and not _recording:
		record_control.show_for_mode(mode)
	_update_hand_skeleton_overlay_state()


func _on_settings_requested() -> void:
	if _recording:
		return
	_release_ui_pointer()
	record_control.hide_control()
	var mode := _current_ui_interaction_mode()
	if settings_panel != null and settings_panel.has_method("set_feedback_input_mode"):
		settings_panel.set_feedback_input_mode(mode, right_pointer if mode == "controllers" else null)
	settings_panel.open()
	_resync_capture_notice()
	_tracker_status_refresh_accum = TRACKER_STATUS_REFRESH_SECONDS
	_update_pico_tracker_setup_status(0.0)


## Requests one of the three user-visible OpenXR reference-space types.
## Godot applies the change on a subsequent XR frame, so callers that are
## about to record must also wait for get_play_area_mode() to confirm it.
func _request_export_coordinate_space(space: Variant) -> bool:
	if xr_interface == null or not xr_interface.is_initialized():
		return false
	var normalized := OpenXRExportSpace.normalize(space)
	var requested_mode := OpenXRExportSpace.play_area_mode(normalized)
	if xr_interface.get_play_area_mode() == requested_mode:
		print("OpenXR export coordinate space active: %s" % normalized.to_upper())
		return true
	var accepted := bool(xr_interface.set_play_area_mode(requested_mode))
	if not accepted:
		push_error("OpenXR runtime rejected export coordinate space %s" % normalized.to_upper())
	return accepted


## Fail closed rather than silently recording a mixture of the requested
## space label and the runtime's LOCAL fallback. This runs only before a
## capture starts; the active play space is never changed mid-recording.
func _ensure_export_coordinate_space_ready(space: Variant) -> bool:
	if xr_interface == null or not xr_interface.is_initialized():
		# Editor/static harnesses have no OpenXR session. Android capture must
		# always have one and therefore cannot bypass this check.
		return not OS.has_feature("android")
	var normalized := OpenXRExportSpace.normalize(space)
	var requested_mode := OpenXRExportSpace.play_area_mode(normalized)
	if xr_interface.get_play_area_mode() == requested_mode:
		return true
	if not _request_export_coordinate_space(normalized):
		return false
	var deadline_ms := Time.get_ticks_msec() + int(EXPORT_SPACE_APPLY_TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline_ms:
		await get_tree().process_frame
		if xr_interface.get_play_area_mode() == requested_mode:
			print("OpenXR export coordinate space active: %s" % normalized.to_upper())
			return true
	var actual := OpenXRExportSpace.from_play_area_mode(xr_interface.get_play_area_mode())
	push_error(
		"OpenXR export coordinate space did not become active: requested=%s actual=%s" % [
			normalized.to_upper(),
			actual.to_upper() if not actual.is_empty() else "UNKNOWN",
		]
	)
	return false


func _show_quest_os_upgrade_warning() -> void:
	_quest_os_upgrade_warning_pending = false
	if _quest_os_upgrade_warning_shown or _pipeline.camera.provider_name != "quest":
		return
	# One attempt per run, even when the version cannot be read.
	_quest_os_upgrade_warning_shown = true
	var version := _pipeline.camera.platform_version()
	if version <= 0:
		push_warning("Unable to detect Horizon OS version; skipping the Quest upgrade prompt")
		return
	if version >= MIN_QUEST_HORIZON_OS_VERSION:
		return
	var title := tr("UI_QUEST_OS_UPDATE_REQUIRED_TITLE")
	var detail := tr("UI_QUEST_OS_UPDATE_REQUIRED_DETAIL") % [version, MIN_QUEST_HORIZON_OS_VERSION]
	push_warning("%s: %s" % [title, detail])
	if status_popup and status_popup.has_method("show_upload_progress"):
		status_popup.show_upload_progress(
			title,
			detail,
			-1.0,
			"warning",
			QUEST_OS_UPGRADE_WARNING_SECONDS,
			false
		)


func _merge_capture_options(options: Dictionary) -> void:
	for key in options.keys():
		capture_options[key] = options[key]
	# An ingest request owns the stream selection, but panel Save, scene setup
	# and the RGB-provider probe all merge panel options in here. Re-assert the
	# request at the single point they converge on.
	_narrow_to_ingest_request()


func _narrow_to_ingest_request() -> void:
	if _ingest == null or not _ingest.planner.has_request():
		return
	_ingest.planner.narrow(capture_options)
	_update_input_source_mismatch_notice()


func _upload_config_available() -> bool:
	return bool(capture_options.get("upload_on_finalize", false)) and not str(capture_options.get("upload_url", "")).strip_edges().is_empty()


func _configured_save_root() -> String:
	var configured := str(capture_options.get("save_root", DEFAULT_SAVE_ROOT)).strip_edges()
	return DEFAULT_SAVE_ROOT if configured.is_empty() else configured


func _update_pico_tracker_setup_status(delta: float) -> void:
	_tracker_status_refresh_accum += delta
	if _tracker_status_refresh_accum < TRACKER_STATUS_REFRESH_SECONDS:
		return
	_tracker_status_refresh_accum = 0.0
	var options := _pico_selected_capture_options()
	if not _pico_tracker_setup_required(options):
		if _tracking_sessions != null:
			_tracking_sessions.release(self)
		if settings_panel != null:
			settings_panel.call("set_pico_tracker_status", false, false, 0, false, false, false)
		return
	var report := _refresh_pico_capture_calibration(options)
	# This runs with the settings CLOSED too, using the immutable session
	# options while recording. A loss finalizes the current file normally.
	if _recording and not bool(report.get("allowed", false)):
		stop_capture()
		_show_pico_calibration_required()
	if settings_panel == null or not bool(settings_panel.get("visible")):
		return
	var opening_setup := _tracker_setup_opened_ticks_us > 0 and Time.get_ticks_usec() - _tracker_setup_opened_ticks_us < int(TRACKER_SETUP_OPENING_SECONDS * 1000000.0)
	settings_panel.call("set_pico_calibration_status", report, bool(report.get("can_calibrate", false)), opening_setup)


func _pico_selected_capture_options() -> Dictionary:
	if _recording:
		return _pipeline.active_options()
	if settings_panel != null and bool(settings_panel.get("visible")):
		return settings_panel.get_options()
	return capture_options


func _refresh_pico_capture_calibration(options: Dictionary) -> Dictionary:
	_tracking_sessions = TrackingSessionService.shared()
	if _tracking_sessions == null:
		return {"phase": "unavailable", "allowed": false}
	var capabilities: Array = ["body"] if bool(options.get("record_body_tracking", false)) else (["motion"] if bool(options.get("record_motion_trackers", false)) else [])
	_tracking_sessions.acquire(self, capabilities, int(options.get("max_motion_trackers", 2)))
	var report := _tracking_sessions.status(self)
	if report.get("phase") != _pico_calibration_report.get("phase") or report.get("mode") != _pico_calibration_report.get("mode"):
		print("[CaptureCalibration] %s" % str(report))
	_pico_calibration_report = report
	return report


func _ensure_capture_start_ready() -> bool:
	# Recheck AFTER the asynchronous export-space wait and before the writer
	# allocates any tracks. All start inputs share this gate.
	return _ensure_pico_capture_calibrated(_pipeline.active_options()) \
			and _pipeline.ensure_storage_ready(_configured_save_root())


func _ensure_pico_capture_calibrated(options: Dictionary) -> bool:
	if not _pico_tracker_setup_required(options):
		return true
	var report := _refresh_pico_capture_calibration(options)
	if _tracking_sessions != null:
		report = _tracking_sessions.status(self, true)
		_pico_calibration_report = report
	if bool(report.get("allowed", false)):
		return true
	_show_pico_calibration_required()
	return false


func _show_pico_calibration_required() -> void:
	push_warning("[CaptureApp] tracker capture blocked: %s" % str(_pico_calibration_report))
	if settings_panel != null:
		if record_control != null:
			record_control.hide_control()
		settings_panel.open()
		settings_panel.select_group("streams")
		settings_panel.call("set_pico_calibration_status", _pico_calibration_report, bool(_pico_calibration_report.get("can_calibrate", false)), false)


func _on_tracker_connect_requested() -> void:
	if _recording:
		return
	var options: Dictionary = settings_panel.get_options() if settings_panel != null and settings_panel.has_method("get_options") else capture_options
	if not _pico_tracker_setup_required(options):
		return
	var opened := false
	var report := _refresh_pico_capture_calibration(options)
	if _tracking_sessions == null:
		return
	if report.get("phase") == "motion_setup":
		_tracking_sessions.retry_setup()
		opened = true
	else:
		opened = _tracking_sessions.begin_calibration()
	if opened:
		_tracker_setup_opened_ticks_us = Time.get_ticks_usec()
		print("PICO tracker setup requested")
	else:
		push_warning("PICO tracker setup is unavailable from the current OpenXR session.")
	_tracker_status_refresh_accum = TRACKER_STATUS_REFRESH_SECONDS
	_update_pico_tracker_setup_status(0.0)


func _on_tracker_calibration_confirm_requested() -> void:
	if _recording:
		return
	var options := _pico_selected_capture_options()
	if not _pico_tracker_setup_required(options):
		return
	_refresh_pico_capture_calibration(options)
	if _tracking_sessions == null or not _tracking_sessions.confirm_calibration():
		push_warning(tr("UI_TRACKING_CONFIRM_REJECTED"))
	_tracker_status_refresh_accum = TRACKER_STATUS_REFRESH_SECONDS
	_update_pico_tracker_setup_status(0.0)


## Body and motion trackers are recorded only locally (no OLCP stream), so
## only a capture that records locally needs the PICO tracker calibration.
func _pico_tracker_setup_required(options: Dictionary) -> bool:
	return PicoPlatformAdapter.is_pico_build() \
			and _pipeline != null and _pipeline.records_locally() \
			and (bool(options.get("record_body_tracking", false)) or bool(options.get("record_motion_trackers", false)))


## Push the "external motion-tracker capture is available?" flag into the
## settings panel once the provider is known. Motion trackers (waist / feet
## pucks via XR_PICO_motion_tracking) are PICO-only, so elsewhere the toggle
## is hidden entirely. This is supports_motion_trackers, NOT body motion:
## Quest has body tracking but no external tracker hardware.
func _update_motion_tracker_support_flag() -> void:
	if settings_panel == null or not settings_panel.has_method("set_motion_tracker_supported"):
		return
	var supported := _pipeline.camera.supports_motion_trackers()
	if _motion_tracker_provider_known and supported == _motion_tracker_supported_pushed:
		return
	_motion_tracker_provider_known = true
	_motion_tracker_supported_pushed = supported
	settings_panel.call("set_motion_tracker_supported", supported)
	if not supported:
		# Force the in-memory option off so the configure path doesn't claim
		# to record trackers that aren't there.
		capture_options["record_motion_trackers"] = false


## Same gating for the OpenXR environment-depth stream. The active runtime
## capability determines visibility; device identity is not consulted.
func _update_depth_support_flag() -> void:
	if settings_panel == null or not settings_panel.has_method("set_depth_supported"):
		return
	var supported := _pipeline.camera.supports_depth()
	if _depth_provider_known and supported == _depth_supported_pushed:
		return
	_depth_provider_known = true
	_depth_supported_pushed = supported
	settings_panel.call("set_depth_supported", supported)
	if not supported:
		# Never claim a depth stream the device cannot produce.
		capture_options["record_depth"] = false


## Push the active capture provider into the RGB recording settings so the
## resolution / FPS dropdowns expose the runtime-backed choices for PICO or
## Quest. The panel owns clamping stale saved values to its provider defaults;
## after that we merge its current snapshot back into capture_options.
func _update_rgb_recording_provider() -> void:
	if settings_panel == null or not settings_panel.has_method("set_capture_provider_name"):
		return
	var provider := _pipeline.camera.provider_name
	if provider.is_empty():
		return
	if provider != _rgb_recording_provider_pushed:
		_rgb_recording_provider_pushed = provider
		_rgb_camera_capabilities_pushed = false
		_rgb_camera_capability_next_probe_us = 0
		settings_panel.call("set_capture_provider_name", provider)
		if settings_panel.has_method("get_options"):
			_merge_capture_options(settings_panel.get_options())
	if provider != "pico" or _rgb_camera_capabilities_pushed:
		return
	var now_us := Time.get_ticks_usec()
	if now_us < _rgb_camera_capability_next_probe_us:
		return
	_rgb_camera_capability_next_probe_us = now_us + 1_000_000
	var capabilities := _pipeline.camera.rgb_runtime_capabilities()
	if capabilities.is_empty():
		return
	if settings_panel.has_method("set_rgb_capabilities"):
		settings_panel.call("set_rgb_capabilities", capabilities)
	_rgb_camera_capabilities_pushed = true
	# Keep the log payload below Android's per-line logcat limit. The UI still
	# receives the complete dictionary; this projection is the stable
	# automation/debug contract.
	var capability_log_summary := {
		"available": bool(capabilities.get("available", false)),
		"extension": str(capabilities.get("extension", "")),
		"fps": capabilities.get("fps", []),
		"stereo_available": bool(capabilities.get("stereo_available", false)),
		"stereo_resolutions": capabilities.get("stereo_resolutions", []),
	}
	print("PICO RGB runtime capabilities: %s" % JSON.stringify(capability_log_summary))
	if _quit_after_rgb_capability_probe:
		_quit_after_rgb_capability_probe = false
		call_deferred("_finish_rgb_capability_probe")
	if settings_panel.has_method("get_options"):
		_merge_capture_options(settings_panel.get_options())


func _finish_rgb_capability_probe() -> void:
	await get_tree().create_timer(0.25).timeout
	print("PICO RGB capability probe complete; quitting")
	get_tree().quit()


func _setup_audio_cues() -> void:
	cue_player = AudioStreamPlayer.new()
	cue_player.name = "RecordingCuePlayer"
	cue_player.volume_db = -6.0
	add_child(cue_player)
	_start_cue = _make_beep_stream(880.0, 0.13)
	_stop_cue = _make_beep_stream(520.0, 0.18)


func _play_cue(stream: AudioStreamWAV) -> void:
	if cue_player == null or stream == null:
		return
	cue_player.stop()
	cue_player.stream = stream
	cue_player.play()


func _make_beep_stream(frequency_hz: float, duration_seconds: float) -> AudioStreamWAV:
	var frame_count := int(float(CUE_SAMPLE_RATE) * duration_seconds)
	var data := PackedByteArray()
	data.resize(frame_count * 2)
	for frame in range(frame_count):
		var t := float(frame) / float(CUE_SAMPLE_RATE)
		var fade := minf(float(frame) / 320.0, float(frame_count - frame - 1) / 320.0)
		fade = clampf(fade, 0.0, 1.0)
		var sample := sin(TAU * frequency_hz * t) * 0.42 * fade
		var value := int(clampf(sample, -1.0, 1.0) * 32767.0)
		if value < 0:
			value += 65536
		var offset := frame * 2
		data[offset] = value & 0xff
		data[offset + 1] = (value >> 8) & 0xff
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = CUE_SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream


# --- QR scanner overlay handlers --------------------------------------------
# The scanner sits in front of the user; while it's open we hide the capture
# panel and the record control so the user has a clean field of view through
# passthrough. The Kotlin plugin drives detections via signals on its own.

func _on_scan_upload_url_requested() -> void:
	print("[QR] scan_upload_url_requested received")
	_open_qr_scanner(QR_TARGET_UPLOAD_URL)


func _on_scan_live_server_requested() -> void:
	print("[QR] scan_live_server_requested received")
	_open_qr_scanner(QR_TARGET_LIVE_SERVER)


func _open_qr_scanner(target: String) -> void:
	if qr_scanner == null:
		push_warning("[QR] scan requested but EgoQRScanner is null")
		return
	_qr_scan_target = target
	# Park the capture panel so the user's view isn't double-occluded with
	# two world-locked quads. Saved state is preserved.
	if settings_panel and settings_panel.visible:
		settings_panel.close()
	if record_control:
		record_control.hide_control()
	_release_ui_pointer()
	qr_scanner.open()
	print("[QR] EgoQRScanner.open() called")


func _on_qr_payload_accepted(payload: String) -> void:
	# Re-open the settings panel so the user can review + Save.
	var target := _qr_scan_target
	_restore_settings_after_qr(target)
	_qr_scan_target = ""
	if target == QR_TARGET_LIVE_SERVER:
		if settings_panel and settings_panel.has_method("set_live_server_host_from_scan"):
			settings_panel.set_live_server_host_from_scan(payload)
		return
	_endpoint_verifier.verify(payload)


func _on_qr_cancelled() -> void:
	# Restore the settings panel without touching the upload URL.
	_restore_settings_after_qr(_qr_scan_target)
	_qr_scan_target = ""


func _restore_settings_after_qr(target: String) -> void:
	if settings_panel == null:
		return
	if target == QR_TARGET_LIVE_SERVER and settings_panel.has_method("show_live_server_settings"):
		settings_panel.show_live_server_settings()
	else:
		settings_panel.open()


func _on_upload_ack_checking() -> void:
	if settings_panel and settings_panel.has_method("set_upload_connectivity_status"):
		settings_panel.set_upload_connectivity_status(tr("UI_UPLOAD_ACK_CHECKING"), "normal")


func _apply_scanned_upload_endpoint(upload_url: String, upload_token: String, verified: bool = true) -> void:
	if settings_panel and settings_panel.has_method("set_upload_url_from_scan"):
		settings_panel.set_upload_url_from_scan(upload_url, upload_token, verified, verified)
	if settings_panel and settings_panel.has_method("set_upload_connectivity_status"):
		if verified:
			settings_panel.set_upload_connectivity_status(tr("UI_UPLOAD_ACK_READY"), "success")
		else:
			settings_panel.set_upload_connectivity_status(tr("UI_UPLOAD_AUTO_REQUIRES_READY"), "warning")


func _on_upload_ack_failed(message: String) -> void:
	if settings_panel and settings_panel.has_method("set_upload_connectivity_status"):
		settings_panel.set_upload_connectivity_status(tr("UI_UPLOAD_ACK_FAILED") % message, "error")
	push_warning("[UploadAck] failed: %s" % message)


# --- EgoUploader signal handlers ---------------------------------------------
# Upload attempts are retried in the background, so the visible UI follows only
# the just-finalized session and uses a single popup progress surface.

func _on_manual_upload_requested(sessions: Array, options: Dictionary) -> void:
	if _recording or ego_uploader == null:
		return
	var upload_options := options.duplicate(true)
	upload_options["upload_on_finalize"] = true
	var queued_count := 0
	var first_session_id := ""
	for item in sessions:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var session_dir := str(item.get("session_dir", ""))
		var mp4_path := str(item.get("mp4_path", ""))
		var session_id := str(item.get("session_id", mp4_path.get_file().get_basename()))
		if session_dir.is_empty() or mp4_path.is_empty():
			continue
		if bool(ego_uploader.enqueue(session_dir, mp4_path, upload_options)):
			queued_count += 1
			if first_session_id.is_empty():
				first_session_id = session_id
	if queued_count <= 0:
		_queue_upload_ui(tr("UI_UPLOAD_NOT_QUEUED"), "", -1.0, "warning", 3.0)
		return
	if _active_upload_session_id.is_empty():
		_active_upload_session_id = first_session_id
		if ego_uploader.has_method("prioritize"):
			ego_uploader.prioritize(first_session_id)
	ego_uploader.resume()
	_queue_upload_ui(tr("UI_UPLOAD_QUEUE_PENDING") % queued_count, "", -1.0, "normal", 2.5, true)


func _on_upload_cancel_requested() -> void:
	if _active_upload_session_id.is_empty() or ego_uploader == null:
		return
	var session_id := _active_upload_session_id
	if ego_uploader.has_method("cancel") and bool(ego_uploader.cancel(session_id)):
		_queue_upload_ui(tr("UI_UPLOAD_CANCELING"), "", -1.0, "warning", 0.0, false)


func _on_upload_started(_session_id: String, kind: String) -> void:
	if not _is_visible_upload_session(_session_id):
		return
	_queue_upload_ui(tr("UI_UPLOAD_PROGRESS_TITLE") % _upload_kind_label(kind), tr("UI_UPLOAD_STARTED_DETAIL"), 0.0, "normal", 0.0, true)
	print("[Upload] %s/%s started" % [_session_id, kind])


func _on_upload_progress(_session_id: String, kind: String, sent_bytes: int, total_bytes: int) -> void:
	if not _is_visible_upload_session(_session_id):
		return
	if total_bytes <= 0:
		_queue_upload_ui(tr("UI_UPLOAD_PROGRESS_TITLE") % _upload_kind_label(kind), tr("UI_UPLOAD_STARTED_DETAIL"), -1.0, "normal", 0.0, true)
		return
	var pct: int = int(round((float(sent_bytes) / float(total_bytes)) * 100.0))
	var progress := clampf(float(sent_bytes) / float(total_bytes), 0.0, 1.0)
	_queue_upload_ui(tr("UI_UPLOAD_PROGRESS_TITLE") % _upload_kind_label(kind), tr("UI_UPLOAD_PROGRESS_DETAIL") % pct, progress, "normal", 0.0, true)


func _on_upload_finished(session_id: String, kind: String, _response: Dictionary) -> void:
	if not _is_visible_upload_session(session_id):
		return
	_queue_upload_ui(tr("UI_UPLOAD_FINISHED_TITLE") % _upload_kind_label(kind), "", 1.0, "success", 1.2)
	print("[Upload] %s/%s finished" % [session_id, kind])


func _on_upload_failed(session_id: String, kind: String, error: String) -> void:
	if _is_visible_upload_session(session_id):
		_queue_upload_ui(tr("UI_UPLOAD_FAILED_TITLE"), "%s: %s" % [_upload_kind_label(kind), error.substr(0, 90)], -1.0, "warning", 0.0, true)
	push_warning("[Upload] %s/%s failed: %s" % [session_id, kind, error])


func _on_upload_cancelled(session_id: String, _reason: String) -> void:
	if not _is_visible_upload_session(session_id):
		return
	_queue_upload_ui(tr("UI_UPLOAD_CANCELLED"), "", -1.0, "warning", 2.5, false)
	_active_upload_session_id = ""
	print("[Upload] session %s cancelled" % session_id)


func _on_session_uploaded(session_id: String) -> void:
	if not _is_visible_upload_session(session_id):
		return
	_queue_upload_ui(tr("UI_UPLOAD_SESSION_COMPLETE"), "", 1.0, "success", 2.5)
	_active_upload_session_id = ""
	print("[Upload] session %s fully uploaded" % session_id)


func _on_upload_queue_changed(pending_count: int) -> void:
	if _active_upload_session_id.is_empty():
		return
	if pending_count == 0:
		# Let the success/failure line linger; the next start_capture or
		# settings open will redraw the control anyway.
		return
	_queue_upload_ui(tr("UI_UPLOAD_QUEUE_PENDING") % pending_count, "", -1.0, "normal")


func _is_visible_upload_session(session_id: String) -> bool:
	return not _active_upload_session_id.is_empty() and session_id == _active_upload_session_id


func _queue_upload_ui(title: String, detail: String, progress: float, level: String = "normal", duration_seconds: float = 0.0, cancelable: bool = false) -> void:
	var update := {
		"title": title,
		"detail": detail,
		"progress": progress,
		"level": level,
		"duration_seconds": duration_seconds,
		"cancelable": cancelable,
	}
	var now := Time.get_ticks_msec()
	if now < _upload_popup_hold_until_msec:
		_pending_upload_popup_update = update
		if not _upload_popup_timer_armed:
			_upload_popup_timer_armed = true
			var delay := maxf(float(_upload_popup_hold_until_msec - now) / 1000.0, 0.05)
			get_tree().create_timer(delay).timeout.connect(_flush_pending_upload_ui)
		return
	_apply_upload_ui(update)


func _flush_pending_upload_ui() -> void:
	_upload_popup_timer_armed = false
	if _pending_upload_popup_update.is_empty():
		return
	var update := _pending_upload_popup_update.duplicate(true)
	_pending_upload_popup_update.clear()
	_apply_upload_ui(update)


func _apply_upload_ui(update: Dictionary) -> void:
	var title := str(update.get("title", ""))
	var detail := str(update.get("detail", ""))
	var progress := float(update.get("progress", -1.0))
	var level := str(update.get("level", "normal"))
	var duration_seconds := float(update.get("duration_seconds", 0.0))
	var cancelable := bool(update.get("cancelable", false))
	var used_popup := false
	if status_popup and status_popup.has_method("show_upload_progress"):
		status_popup.show_upload_progress(title, detail, progress, level, duration_seconds, cancelable)
		used_popup = true
	if record_control:
		if used_popup and record_control.has_method("clear_upload_status"):
			record_control.clear_upload_status()


func _upload_kind_label(kind: String) -> String:
	match kind:
		"manifest":
			return tr("UI_UPLOAD_KIND_MANIFEST")
		"media":
			return tr("UI_UPLOAD_KIND_MEDIA")
	return kind
