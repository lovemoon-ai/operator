extends Node3D

const SessionSpoolWriterScript := preload("res://scripts/session_spool_writer.gd")
const LivePushWriterScript := preload("res://addons/live-push/live_push_writer.gd")
const LivePullDenseMapViewScript := preload("res://addons/live-pull/live_pull_dense_map_view.gd")
const PoseSamplerScript := preload("res://scripts/pose_sampler.gd")
const DepthSamplerScript := preload("res://scripts/depth_sampler.gd")
const BodyMotionSamplerScript := preload("res://scripts/body_motion_sampler.gd")
const ViewLockedCapturePanelScript := preload("res://scripts/view_locked_capture_panel.gd")
const ViewLockedRecordControlScript := preload("res://scripts/view_locked_record_control.gd")
const ViewLockedStatusPopupScript := preload("res://scripts/view_locked_status_popup.gd")
const OperatorUIPointerVisualScript := preload("res://scripts/xr/operator_ui_pointer_visual.gd")
const SettingsInteractionRouterScript := preload("res://scripts/ui/settings_interaction_router.gd")
const EgoUploaderScript := preload("res://scripts/ego_uploader.gd")
const EgoQRScannerScript := preload("res://scripts/ego_qr_scanner.gd")
const CaptureProviderRegistryScript := preload("res://scripts/xr/capture_provider_registry.gd")
const QR_SCANNER_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const QR_TARGET_UPLOAD_URL := "upload_url"
const QR_TARGET_LIVE_SERVER := "live_server"

const DEFAULT_SAVE_ROOT := "/sdcard/DCIM/SpatialMP4"
const DEFAULT_RGB_BITRATE := 24000000
const DEFAULT_RGB_FPS := 30
const SETTINGS_PANEL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const RECORD_CONTROL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.18, -0.86))
const STATUS_POPUP_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18, -0.92))
const CUE_SAMPLE_RATE := 32000
const UPLOAD_ACK_TIMEOUT_SECONDS := 8.0
const AUDIO_PERMISSION_GRACE_US := 3000000
const TRACKER_STATUS_REFRESH_SECONDS := 0.5
const TRACKER_REQUEST_RETRY_SECONDS := 3.0
const TRACKER_SETUP_OPENING_SECONDS := 4.0
# Re-probe the OpenXR runtime for hand-vs-controller state at ~6 Hz. Faster
# than this drowns logcat with mode-flip prints when the operator's hand
# briefly leaves the optical tracker's FOV; slower than ~3 Hz feels visibly
# laggy when the user transitions controllers <-> bare hands.
const INPUT_MODE_DETECT_INTERVAL_S := 0.18

@export var auto_start := false
@export var pose_sample_hz := 90.0
@export var keep_passthrough_visible := true
@export_enum("spatialmp4", "server") var capture_sink := "spatialmp4"
@export var default_live_server_host := "127.0.0.1"
@export var default_live_server_port := 63910
@export var default_live_result_port := 63912
@export var default_live_server_auth_token := ""
@export var enable_live_pull := true
## When false (default), the headset's safety / guardian / boundary overlay is
## hidden on session begin so it doesn't intrude on passthrough captures. Set
## to true to leave the platform overlay alone (Quest only; the Pico runtime
## already suppresses its safe zone while in passthrough).
@export var keep_safety_zone_visible := false

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
var record_control
var status_popup
var ui_pointer_visual
var settings_interaction_router
var writer: Object
var pose_sampler: Node
var depth_sampler: Node
var body_motion_sampler: Node
var ego_uploader: Node
var qr_scanner: Object
var upload_ack_request: HTTPRequest
var _pending_upload_ack_payload := ""
var _qr_scan_target := ""
var _active_upload_session_id := ""
var _upload_popup_hold_until_msec := 0
var _pending_upload_popup_update: Dictionary = {}
var _upload_popup_timer_armed := false
var cue_player: AudioStreamPlayer
var _start_cue: AudioStreamWAV
var _stop_cue: AudioStreamWAV
var camera_plugin: Object
var muxer_plugin: Object
var pico_openxr_bridge: Object
var live_server_plugin: Object
var live_pull_view: Node3D
var capture_options := {
	"interaction_mode": "controllers",
	"stereo_rgb": true,
	"record_depth": true,
	"record_head_pose": true,
	"record_controller_pose": true,
	"record_hand_data": true,
	"record_body_tracking": true,
	"record_motion_trackers": true,
	"max_motion_trackers": 3,
	# v3 spatial audio: now on by default ("Audio" toggle in the settings
	# panel). The pipeline still gates on the Android RECORD_AUDIO runtime
	# permission downstream -- if the user denies the prompt, the session
	# degrades to a video-only capture instead of failing outright.
	"record_audio": true,
	# Encoder shape. Mirrors AudioCapture.DEFAULT_* on the Kotlin side; the
	# host can override either here in code or via capture_options at runtime
	# (e.g. for an FOA-capable build that swaps "stereo" -> "foa_acn_sn3d").
	"audio_channel_layout": "stereo",
	"audio_sample_rate_hz": 48000,
	"audio_bitrate_bps": 128000,
	"server_host": "127.0.0.1",
	"server_port": 63910,
	"server_result_port": 63912,
	"save_controller_hand_sidecar": false,
	# Body joints always go into the MP4 mett body_joints track; the sidecar
	# JSONL (frame-level body_flags + PICO velocity/acceleration extras) is
	# opt-in via the settings panel.
	"save_body_sidecar": false,
	"save_root": DEFAULT_SAVE_ROOT
}

var _recording := false
var _pose_accum := 0.0
var _capture_started_ticks_us := 0
var _xr_session_begun := false
var _camera_configured := false
var _camera_start_attempted := false
var _camera_bind_warned := false
var _capture_provider_name := ""
var _camera_permission_wait_logged := false
var _last_capture_error := ""
var _audio_permission_wait_logged := false
var _audio_permission_degraded_logged := false
var _audio_permission_wait_started_ticks_us := 0
var _active_capture_options := {}
var _pico_camera_image_started := false
var _pico_camera_frame_interval_s := 1.0 / DEFAULT_RGB_FPS
var _pico_camera_frame_accum_s := 0.0
var _pico_camera_submit_warned := false
var _passthrough_active := false
var _previous_transparent_bg := false
var _previous_environment_blend_mode := XRInterface.XR_ENV_BLEND_MODE_OPAQUE
var _previous_background_mode := Environment.BG_CLEAR_COLOR
var _previous_background_color := Color.BLACK

# 1Hz metrics ticker: tracks how many _process invocations and which phases
# (pose loop iterations, plugin probes) ran in the last second, then emits a
# single log line tagged "QcMetrics" so logcat can be grepped without
# combing through dozens of unrelated prints.
const METRICS_INTERVAL_S := 1.0
var _metrics_accum_s := 0.0
var _metrics_process_ticks := 0
var _metrics_pose_loop_iters := 0
var _metrics_started_ticks_us := 0
var _tracker_status_refresh_accum := TRACKER_STATUS_REFRESH_SECONDS
var _tracker_last_request_ticks_us := 0
var _tracker_setup_opened_ticks_us := 0
# Cached input-mode detection state. capture_options["interaction_mode"] is
# updated whenever the detected source changes, and the panel + record
# control are notified at the same time.
var _input_mode_detected := ""
var _input_mode_detect_accum := 0.0
var _motion_tracker_supported_pushed := false
var _motion_tracker_provider_known := false
# Tracks whether we've already fired an up-front requestAudioPermission()
# prompt for this app session. Audio defaults to ON now, so we surface the
# system prompt as soon as the capture provider binds -- otherwise the
# operator wouldn't see it until they tapped Start, by which point a denied
# prompt would silently produce a video-only recording with no warning.
var _audio_permission_prompt_fired := false
# Per-stage main-thread budgets so we can attribute the engine_fps drop to a
# specific subsystem (panel update vs pointer raycast vs pose loop vs metrics
# overhead). Microsecond accumulators; pop_metrics-style reset each second.
var _stage_us_panel := 0
var _stage_us_pointer := 0
var _stage_us_record_ctl := 0
var _stage_us_pose_loop := 0
var _stage_us_depth_pump := 0
var _stage_us_emit_metrics := 0


func _ready() -> void:
	_setup_xr_scene()
	_setup_pico_openxr_bridge()
	_apply_automation_args()
	_initialize_openxr()
	_bind_android_plugin()
	_setup_audio_cues()

	writer = _create_writer()
	# _bind_android_plugin ran above when `writer` was still null, so its own
	# writer.set_*_plugin attempts were skipped; we re-wire both singletons
	# here against the freshly-created spool writer. Stage 2b's split moved
	# every write* RPC to the muxer plugin, so missing the second hand-off
	# silently no-ops every pose / depth / hand / input frame.
	if camera_plugin != null and writer.has_method("set_android_plugin"):
		writer.set_android_plugin(camera_plugin)
	if muxer_plugin != null and writer.has_method("set_muxer_plugin"):
		writer.set_muxer_plugin(muxer_plugin)
	if live_server_plugin != null and writer.has_method("set_live_server_plugin"):
		writer.set_live_server_plugin(live_server_plugin)
	pose_sampler = PoseSamplerScript.new()
	depth_sampler = DepthSamplerScript.new()
	body_motion_sampler = BodyMotionSamplerScript.new()

	add_child(pose_sampler)
	add_child(depth_sampler)
	add_child(body_motion_sampler)
	pose_sampler.configure(writer, hmd_camera, left_controller, right_controller, camera_plugin)
	depth_sampler.configure(writer, camera_plugin)
	body_motion_sampler.configure(writer, pose_sampler, pico_openxr_bridge)

	if not _is_live_feed_mode():
		# EgoUploader drains user://ego_upload_queue.json for ego capture only.
		# Live Feed is a push-only session and must not resume old local upload
		# jobs or surface upload progress/errors.
		ego_uploader = EgoUploaderScript.new()
		ego_uploader.name = "EgoUploader"
		add_child(ego_uploader)
		ego_uploader.upload_started.connect(_on_upload_started)
		ego_uploader.upload_progress.connect(_on_upload_progress)
		ego_uploader.upload_finished.connect(_on_upload_finished)
		ego_uploader.upload_failed.connect(_on_upload_failed)
		ego_uploader.upload_cancelled.connect(_on_upload_cancelled)
		ego_uploader.session_uploaded.connect(_on_session_uploaded)
		ego_uploader.queue_changed.connect(_on_upload_queue_changed)

		upload_ack_request = HTTPRequest.new()
		upload_ack_request.name = "UploadAckRequest"
		upload_ack_request.timeout = UPLOAD_ACK_TIMEOUT_SECONDS
		upload_ack_request.request_completed.connect(_on_upload_ack_completed)
		add_child(upload_ack_request)

	var automation := _capture_automation_options_from_args()
	if automation.has("interaction_mode"):
		capture_options["interaction_mode"] = automation["interaction_mode"]
		if settings_panel and settings_panel.has_method("set_options"):
			settings_panel.set_options(capture_options)
		print("Capture automation interaction_mode=%s" % capture_options["interaction_mode"])

	if bool(automation.get("auto_start", false)):
		call_deferred("start_capture")
		_schedule_auto_stop_for_device_test(float(automation.get("auto_stop_seconds", AUTO_STOP_AFTER_SECONDS)))
	elif AUTO_START_FOR_DEVICE_TEST:
		capture_options["interaction_mode"] = "head"
		if settings_panel and settings_panel.has_method("set_options"):
			settings_panel.set_options(capture_options)
		call_deferred("start_capture")
		_schedule_auto_stop_for_device_test(AUTO_STOP_AFTER_SECONDS)
	elif auto_start:
		start_capture()
	elif _is_live_feed_mode():
		call_deferred("_open_live_feed_settings")


func _apply_automation_args() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	for arg_value in args:
		var arg := String(arg_value).strip_edges()
		if arg == "--operator-auto-start":
			auto_start = true
		elif arg.begins_with("operator.auto_start="):
			auto_start = _truthy_string(arg.substr("operator.auto_start=".length()))


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


func _capture_automation_options_from_args() -> Dictionary:
	var options := {}
	_collect_capture_automation_args(options, OS.get_cmdline_user_args())
	_collect_capture_automation_args(options, OS.get_cmdline_args())
	return options


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
		i += 1


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


func _process(delta: float) -> void:
	_metrics_process_ticks += 1
	_metrics_accum_s += delta
	if _metrics_accum_s >= METRICS_INTERVAL_S:
		var t_metrics := Time.get_ticks_usec()
		_emit_metrics(_metrics_accum_s)
		_metrics_accum_s = 0.0
		_stage_us_emit_metrics += Time.get_ticks_usec() - t_metrics

	var t_panel := Time.get_ticks_usec()
	_update_view_locked_panel()
	_stage_us_panel += Time.get_ticks_usec() - t_panel

	var t_pointer := Time.get_ticks_usec()
	_update_ui_pointer()
	_stage_us_pointer += Time.get_ticks_usec() - t_pointer
	_update_pico_tracker_setup_status(delta)
	_update_input_mode_detection(delta)
	_update_motion_tracker_support_flag()
	_ensure_audio_permission_prompted()

	if _recording and record_control:
		var t_record := Time.get_ticks_usec()
		var elapsed_seconds := float(Time.get_ticks_usec() - _capture_started_ticks_us) / 1000000.0
		record_control.update_elapsed_seconds(elapsed_seconds)
		_stage_us_record_ctl += Time.get_ticks_usec() - t_record
	if not _recording:
		return

	if camera_plugin == null:
		_bind_android_plugin()
		if camera_plugin != null and not _camera_configured:
			_start_camera_plugin()
	_try_start_camera_plugin()
	_pump_pico_openxr_camera_frames(delta)
	if _stream_enabled("record_depth"):
		var t_depth := Time.get_ticks_usec()
		depth_sampler.pump(delta)
		_stage_us_depth_pump += Time.get_ticks_usec() - t_depth

	var t_pose_loop := Time.get_ticks_usec()
	_pose_accum += delta
	var interval: float = 1.0 / max(pose_sample_hz, 1.0)
	while _pose_accum >= interval:
		_pose_accum -= interval
		_metrics_pose_loop_iters += 1
		if _has_pose_streams_enabled():
			pose_sampler.sample(Time.get_ticks_usec() * 1000)
		if _has_body_motion_streams_enabled():
			body_motion_sampler.sample(Time.get_ticks_usec() * 1000)
	_stage_us_pose_loop += Time.get_ticks_usec() - t_pose_loop


func _emit_metrics(window_s: float) -> void:
	var process_fps: float = _metrics_process_ticks / window_s
	var engine_fps: float = float(Engine.get_frames_per_second())
	var pose_metrics: Dictionary = {}
	if pose_sampler != null:
		pose_metrics = pose_sampler.pop_metrics()
	var depth_metrics: Dictionary = {}
	if depth_sampler != null:
		depth_metrics = depth_sampler.pop_metrics()
	var body_motion_metrics: Dictionary = {}
	if body_motion_sampler != null:
		body_motion_metrics = body_motion_sampler.pop_metrics()
	var plugin_metrics: Dictionary = {}
	if camera_plugin != null:
		var raw: Variant = camera_plugin.call("popMetricsJson")
		var parsed: Variant = null
		if typeof(raw) == TYPE_STRING and not String(raw).is_empty():
			parsed = JSON.parse_string(String(raw))
		if typeof(parsed) == TYPE_DICTIONARY:
			plugin_metrics = parsed
	var muxer_metrics: Dictionary = {}
	if muxer_plugin != null:
		var raw_muxer: Variant = muxer_plugin.call("popMuxerMetricsJson")
		if typeof(raw_muxer) == TYPE_STRING and not String(raw_muxer).is_empty():
			var parsed_muxer: Variant = JSON.parse_string(String(raw_muxer))
			if typeof(parsed_muxer) == TYPE_DICTIONARY:
				muxer_metrics = parsed_muxer
	if writer != null and writer.has_method("pop_metrics"):
		var writer_metrics: Dictionary = writer.pop_metrics()
		for key in writer_metrics.keys():
			plugin_metrics["sink_%s" % key] = writer_metrics[key]
	# Compact one-liner so it doesn't drown the rest of logcat. Tagged
	# "QcMetrics" so adb logcat -s godot:V | grep QcMetrics gives a clean
	# table.
	print("QcMetrics %.1fs recording=%s engine_fps=%d process_fps=%.1f pose_loop_iters=%d stages_ms={panel=%.1f,pointer=%.1f,record=%.1f,pose=%.1f,depth=%.1f,metrics=%.1f} pose=%s depth=%s body_motion=%s plugin=%s muxer=%s" % [
		window_s,
		str(_recording),
		engine_fps,
		process_fps,
		_metrics_pose_loop_iters,
		_stage_us_panel / 1000.0,
		_stage_us_pointer / 1000.0,
		_stage_us_record_ctl / 1000.0,
		_stage_us_pose_loop / 1000.0,
		_stage_us_depth_pump / 1000.0,
		_stage_us_emit_metrics / 1000.0,
		_compact_dict(pose_metrics),
		_compact_dict(depth_metrics),
		_compact_dict(body_motion_metrics),
		_compact_dict(plugin_metrics),
		_compact_dict(muxer_metrics)
	])
	_metrics_process_ticks = 0
	_metrics_pose_loop_iters = 0
	_stage_us_panel = 0
	_stage_us_pointer = 0
	_stage_us_record_ctl = 0
	_stage_us_pose_loop = 0
	_stage_us_depth_pump = 0
	_stage_us_emit_metrics = 0


func _compact_dict(d: Dictionary) -> String:
	if d.is_empty():
		return "{}"
	var parts: Array = []
	for key in d.keys():
		parts.append("%s=%s" % [key, d[key]])
	return "{" + ",".join(parts) + "}"


func _exit_tree() -> void:
	stop_capture()
	_stop_live_pull()
	_set_passthrough_visible(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_RESUMED:
		_reset_ui_input_state()

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
	if settings_interaction_router == null:
		return
	if settings_interaction_router.has_method("reset_input_state"):
		settings_interaction_router.call("reset_input_state")
	else:
		settings_interaction_router.release_pointer()


func start_capture() -> void:
	if _recording:
		return

	if not _ensure_output_storage_ready():
		return
	_active_capture_options = _effective_capture_options(capture_options)
	if not bool(writer.start_session(_active_capture_options)):
		push_error("Capture session did not start because its output directory could not be created.")
		_active_capture_options = {}
		return
	_start_live_pull()
	pose_sampler.set_capture_options(_active_capture_options)
	body_motion_sampler.set_capture_options(_active_capture_options)
	_recording = true
	_pose_accum = 0.0
	_capture_started_ticks_us = Time.get_ticks_usec()
	_camera_configured = false
	_camera_start_attempted = false
	_camera_permission_wait_logged = false
	_last_capture_error = ""
	_audio_permission_wait_logged = false
	_audio_permission_degraded_logged = false
	_audio_permission_wait_started_ticks_us = 0
	_pico_camera_image_started = false
	_pico_camera_frame_accum_s = 0.0
	_pico_camera_submit_warned = false
	if record_control:
		record_control.set_recording(true)
	# Park any in-flight upload while we record — see
	# claw/issues/010-ego-data-upload.md "Trip-wires".
	if ego_uploader and not _is_live_feed_mode():
		ego_uploader.pause()
	if _xr_session_begun and _stream_enabled("record_depth"):
		depth_sampler.start()
	_start_camera_plugin()
	if not _recording:
		return
	_play_cue(_start_cue)
	print("Capture session started: %s" % writer.get_session_dir())


func stop_capture() -> void:
	if not _recording:
		return

	var is_live_feed := _is_live_feed_mode()
	_stop_camera_plugin()
	# Snapshot the body-tracking runtime BEFORE stop()/close() so the
	# manifest rewrite at close() time can record which extension actually
	# fed the samples (PICO BD vs Meta XR_FB / full_body). The sampler keeps
	# its observed_body_runtime across stop(), but reading it pre-close keeps
	# the data flow obvious — sample → record → manifest.
	if body_motion_sampler and body_motion_sampler.has_method("get_runtime_info") and writer and writer.has_method("set_body_tracking_runtime_info"):
		writer.set_body_tracking_runtime_info(body_motion_sampler.get_runtime_info())
	body_motion_sampler.stop()
	if not is_live_feed:
		_stop_live_pull()
	depth_sampler.stop()
	writer.close()
	var saved_session_dir := ""
	if not is_live_feed:
		saved_session_dir = writer.get_saved_path() if writer.has_method("get_saved_path") else writer.get_session_dir()
	_recording = false
	_active_capture_options = {}
	_camera_configured = false
	_camera_start_attempted = false
	_camera_permission_wait_logged = false
	_audio_permission_wait_logged = false
	_audio_permission_degraded_logged = false
	_audio_permission_wait_started_ticks_us = 0
	_pico_camera_image_started = false
	_pico_camera_frame_accum_s = 0.0
	_pico_camera_submit_warned = false
	if record_control:
		record_control.set_recording(false)
	_play_cue(_stop_cue)
	if is_live_feed:
		print("Live feed push stopped; live-pull remains connected for algorithm results")
		return
	var upload_expected := _upload_config_available()
	if status_popup:
		if saved_session_dir.is_empty():
			var detail := _last_capture_error if not _last_capture_error.is_empty() else tr("UI_RECORDING_SAVE_FAILED_DETAIL")
			status_popup.show_error(detail)
			_upload_popup_hold_until_msec = 0
		else:
			var saved_popup_seconds := 1.35 if upload_expected else 2.0
			status_popup.show_saved_path(saved_session_dir, saved_popup_seconds)
			_upload_popup_hold_until_msec = Time.get_ticks_msec() + int(saved_popup_seconds * 1000.0) if upload_expected else 0
	print("Capture session stopped: %s" % saved_session_dir)

	# Hand the freshly-finalized session to the uploader. enqueue() is a
	# no-op when upload_url is empty or upload_on_finalize is off, so we
	# can always call it. Then resume the worker we paused at
	# start_capture so the new job (and anything queued from a prior
	# session) starts draining.
	if ego_uploader and writer:
		# session_spool_writer.gd exposes get_session_dir_absolute() (an
		# OS-absolute path on Android, e.g. /sdcard/DCIM/SpatialMP4/<id>/)
		# and get_output_mp4_path_absolute() (the finalized mp4 sibling
		# to that dir). Both are stable once writer.close() has returned.
		var session_dir_for_upload: String = writer.get_session_dir_absolute() if writer.has_method("get_session_dir_absolute") else writer.get_session_dir()
		var mp4_for_upload: String = writer.get_output_mp4_path_absolute() if writer.has_method("get_output_mp4_path_absolute") else (saved_session_dir if saved_session_dir.ends_with(".mp4") else "")
		var session_id_for_upload := mp4_for_upload.get_file().get_basename()
		var queued := bool(ego_uploader.enqueue(session_dir_for_upload, mp4_for_upload, capture_options))
		if queued:
			_active_upload_session_id = session_id_for_upload
			if ego_uploader.has_method("prioritize"):
				ego_uploader.prioritize(session_id_for_upload)
			ego_uploader.resume()
		elif upload_expected:
			_active_upload_session_id = ""
			_queue_upload_ui(tr("UI_UPLOAD_NOT_QUEUED"), "", -1.0, "warning", 3.0)


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

	ui_pointer_visual = OperatorUIPointerVisualScript.new()
	ui_pointer_visual.name = "OperatorUIPointerVisual"
	origin.add_child(ui_pointer_visual)

	settings_interaction_router = SettingsInteractionRouterScript.new()
	settings_interaction_router.name = "SettingsInteractionRouter"
	settings_interaction_router.configure(origin, hmd_camera, left_pointer, right_pointer, ui_pointer_visual)
	origin.add_child(settings_interaction_router)

	if _is_live_feed_mode() and enable_live_pull:
		live_pull_view = LivePullDenseMapViewScript.new()
		live_pull_view.name = "LivePullDenseMapView"
		# Head-lock the dense-map minimap to the HMD so the scaled-down cloud
		# stays pinned in front of the user's view instead of riding XROrigin.
		if "head_lock_target" in live_pull_view:
			live_pull_view.head_lock_target = hmd_camera
		if live_pull_view.has_signal("connected_to_server"):
			live_pull_view.connected_to_server.connect(_on_live_pull_connected)
		if live_pull_view.has_signal("disconnected_from_server"):
			live_pull_view.disconnected_from_server.connect(_on_live_pull_disconnected)
		if live_pull_view.has_signal("connection_failed"):
			live_pull_view.connection_failed.connect(_on_live_pull_connection_failed)
		origin.add_child(live_pull_view)

	settings_panel = ViewLockedCapturePanelScript.new(_is_live_feed_mode())
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
	if _is_live_feed_mode():
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

	status_popup = ViewLockedStatusPopupScript.new()
	status_popup.name = "ViewLockedStatusPopup"
	if status_popup.has_signal("cancel_requested"):
		status_popup.cancel_requested.connect(_on_upload_cancel_requested)
	origin.add_child(status_popup)
	settings_interaction_router.set_targets([qr_scanner, settings_panel, status_popup, record_control])


func _setup_pico_openxr_bridge() -> void:
	if pico_openxr_bridge != null:
		return
	var bridge_autoload := get_node_or_null("/root/PicoOpenXRBridge")
	if bridge_autoload != null and bridge_autoload.has_method("get_bridge"):
		pico_openxr_bridge = bridge_autoload.call("get_bridge")
		if pico_openxr_bridge != null:
			print("PicoOpenXRExtension bridge bound from autoload")
			return
	if Engine.has_singleton("PicoOpenXRBridgeNative"):
		pico_openxr_bridge = Engine.get_singleton("PicoOpenXRBridgeNative")
		if pico_openxr_bridge != null:
			print("PicoOpenXRExtension bridge bound from native singleton")
			return
	if not ClassDB.class_exists("PicoOpenXRExtension"):
		return
	pico_openxr_bridge = ClassDB.instantiate("PicoOpenXRExtension")
	if pico_openxr_bridge != null:
		print("PicoOpenXRExtension bridge instantiated")


func _initialize_openxr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface:
		xr_interface.session_begun.connect(_on_openxr_session_begun)
		xr_interface.session_stopping.connect(_on_openxr_session_stopping)
	if xr_interface and not xr_interface.is_initialized():
		xr_interface.initialize()

	if xr_interface and xr_interface.is_initialized():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_viewport().use_xr = true
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


func _bind_android_plugin() -> void:
	if camera_plugin != null and _active_sink_plugin() != null:
		return
	# Stage 2b split the camera provider from the muxer. Quest and PICO now
	# both export providers; select the one with the best runtime device score
	# so a PICO APK does not accidentally bind QuestCapturePlugin first.
	var provider_was_bound := camera_plugin != null
	if camera_plugin == null:
		camera_plugin = CaptureProviderRegistryScript.bind()
	if camera_plugin != null and not provider_was_bound:
		_capture_provider_name = CaptureProviderRegistryScript.provider_name(camera_plugin)
		camera_plugin.connect("camera_ready", Callable(self, "_on_camera_ready"))
		camera_plugin.connect("camera_frame_saved", Callable(self, "_on_camera_frame_saved"))
		camera_plugin.connect("camera_error", Callable(self, "_on_camera_error"))
		_camera_bind_warned = false
		print("Capture provider singleton bound: %s" % _provider_label())

	if _is_live_feed_mode():
		if live_server_plugin == null and Engine.has_singleton("LivePushPlugin"):
			live_server_plugin = Engine.get_singleton("LivePushPlugin")
		elif live_server_plugin == null and Engine.has_singleton("LiveFeedServerPlugin"):
			live_server_plugin = Engine.get_singleton("LiveFeedServerPlugin")
		elif live_server_plugin == null and Engine.has_singleton("LiveCaptureServerPlugin"):
			live_server_plugin = Engine.get_singleton("LiveCaptureServerPlugin")
		if live_server_plugin != null:
			if live_server_plugin.has_signal("live_feed_error"):
				live_server_plugin.connect("live_feed_error", Callable(self, "_on_camera_error"))
			elif live_server_plugin.has_signal("live_capture_error"):
				live_server_plugin.connect("live_capture_error", Callable(self, "_on_camera_error"))
			if live_server_plugin.has_signal("live_feed_connected"):
				live_server_plugin.connect("live_feed_connected", Callable(self, "_on_live_feed_connected"))
			elif live_server_plugin.has_signal("live_capture_connected"):
				live_server_plugin.connect("live_capture_connected", Callable(self, "_on_live_feed_connected"))
			if live_server_plugin.has_signal("live_feed_disconnected"):
				live_server_plugin.connect("live_feed_disconnected", Callable(self, "_on_live_feed_disconnected"))
			elif live_server_plugin.has_signal("live_capture_disconnected"):
				live_server_plugin.connect("live_capture_disconnected", Callable(self, "_on_live_feed_disconnected"))
			print("LivePushPlugin singleton bound")
	else:
		if muxer_plugin == null and Engine.has_singleton("SpatialMp4MuxerPlugin"):
			muxer_plugin = Engine.get_singleton("SpatialMp4MuxerPlugin")
			muxer_plugin.connect("camera_error", Callable(self, "_on_camera_error"))
			print("SpatialMp4MuxerPlugin singleton bound (contract v%d)" % int(muxer_plugin.call("getMuxerContractVersion")))

	var sink_plugin := _active_sink_plugin()
	if camera_plugin != null and sink_plugin != null:
		# Kotlin-direct sink binding: RGB CSD + packets bypass GDScript on the
		# per-frame path. Depth / pose / hand / input still flow through the
		# selected writer adapter -- see writer wiring.
		if _is_live_feed_mode():
			camera_plugin.call("bindMuxer", null)
		var bound: Variant = camera_plugin.call("bindMuxer", sink_plugin)
		if not bool(bound):
			push_warning("%s.bindMuxer(%s) returned false; registry fallback will be used if available" % [_provider_label(), sink_plugin])
		if writer != null and writer.has_method("set_android_plugin"):
			writer.set_android_plugin(camera_plugin)
		if writer != null and writer.has_method("set_muxer_plugin"):
			writer.set_muxer_plugin(muxer_plugin)
		if writer != null and writer.has_method("set_live_server_plugin"):
			writer.set_live_server_plugin(live_server_plugin)
		return
	if camera_plugin == null and not _camera_bind_warned:
		_camera_bind_warned = true
		print("Capture provider singleton is not installed yet; RGB capture is waiting.")
		push_warning("Capture provider singleton is not installed; RGB capture is disabled.")
	if _is_live_feed_mode() and live_server_plugin == null:
		push_warning("LivePushPlugin singleton is not installed; live feed streaming is disabled.")


func _start_camera_plugin() -> void:
	if camera_plugin == null:
		print("Capture provider start skipped: singleton is not bound")
		return

	var session_dir_absolute: String = writer.get_session_dir_absolute()
	var output_mp4_absolute: String = writer.get_output_mp4_path_absolute()
	var partial_mp4_absolute: String = writer.get_partial_mp4_path_absolute()
	print("%s configure begin: %s" % [_provider_label(), output_mp4_absolute])
	# Android Godot plugin singletons do not reliably report @UsedByGodot
	# methods through has_method(), so call the compact JSON RPC directly.
	var want_audio: bool = bool(_capture_option("record_audio", false))
	var layout_code: int = _audio_layout_code_for_label(
		str(_capture_option("audio_channel_layout", "stereo"))
	)
	var configured_result: Variant
	if _capture_provider_name == "pico":
		configured_result = camera_plugin.call(
			"configureSpatialMp4SessionWithTime",
			output_mp4_absolute,
			partial_mp4_absolute,
			session_dir_absolute,
			writer.get_session_start_unix_us(),
			writer.get_session_start_ticks_us(),
			Time.get_ticks_usec(),
			_stream_enabled("record_depth"),
			_stream_enabled("record_head_pose"),
			_stream_enabled("record_controller_pose"),
			_stream_enabled("record_hand_data"),
			_stream_enabled("record_controller_pose"),
			bool(_capture_option("stereo_rgb", true)),
			int(_capture_option("rgb_bitrate", DEFAULT_RGB_BITRATE)),
			int(_capture_option("rgb_fps", DEFAULT_RGB_FPS))
		)
	else:
		var session_config := {
			"final_path": output_mp4_absolute,
			"partial_path": partial_mp4_absolute,
			"sidecar_path": session_dir_absolute,
			"session_start_unix_us": writer.get_session_start_unix_us(),
			"session_start_godot_ticks_us": writer.get_session_start_ticks_us(),
			"configure_godot_ticks_us": Time.get_ticks_usec(),
			"record_depth": _stream_enabled("record_depth"),
			"record_head_pose": _stream_enabled("record_head_pose"),
			"record_controller_pose": _stream_enabled("record_controller_pose"),
			"record_hand_data": _stream_enabled("record_hand_data"),
			"record_controller_input": _stream_enabled("record_controller_pose"),
			"stereo_rgb": bool(_capture_option("stereo_rgb", true)),
			"rgb_bitrate": int(_capture_option("rgb_bitrate", DEFAULT_RGB_BITRATE)),
			"rgb_fps": int(_capture_option("rgb_fps", DEFAULT_RGB_FPS)),
			"record_audio": want_audio,
			"audio_channel_layout_code": layout_code,
			"audio_sample_rate_hz": int(_capture_option("audio_sample_rate_hz", 48000)),
			"audio_bitrate_bps": int(_capture_option("audio_bitrate_bps", 128000))
		}
		configured_result = camera_plugin.call(
			"configureSpatialMp4SessionFromJson",
			JSON.stringify(session_config)
		)
	# Body-motion options are configured the same way on every provider so the
	# settings panel's "Body tracking" toggle reaches the active provider. PICO
	# wires it to XR_BD_body_tracking + motion-tracker pucks; Quest wires it to
	# Meta XR body tracking (XR_FB_body_tracking / XR_META_body_tracking_full_body).
	# Pre-fix the call only fired in the PICO branch, so Quest's recordBodyTracking
	# stayed at its compile-time default and SessionConfig.bodyJointsExpected
	# never actually reflected the host's choice — the mp4 mett body track was
	# never allocated and the manifest's body_tracking source stayed empty.
	if camera_plugin.has_method("setBodyMotionCaptureOptions"):
		camera_plugin.call(
			"setBodyMotionCaptureOptions",
			_stream_enabled("record_body_tracking"),
			_stream_enabled("record_motion_trackers"),
			int(_capture_option("max_motion_trackers", 3))
		)
	_camera_configured = bool(configured_result)
	print("%s configureSession returned: %s (audio=%s)" % [_provider_label(), configured_result, want_audio])
	if not _camera_configured:
		_abort_capture_start("%s configure failed" % _provider_label())
		return

	camera_plugin.call("requestCameraPermission")
	# RECORD_AUDIO is a runtime permission too. Request it up front; if the
	# user denies or ignores it, _try_start_camera_plugin degrades to a
	# video-only capture instead of blocking the whole session.
	if want_audio:
		camera_plugin.call("requestAudioPermission")
	print("%s requested camera permissions" % _provider_label())
	_try_start_camera_plugin()


# Mirrors com.spatialmp4.contract.AudioChannelLayout.code on the Kotlin side.
# Centralised here so the capture panel / settings UI can swap "stereo" for
# "foa_acn_sn3d" without re-deriving the enum mapping in three places.
func _audio_layout_code_for_label(label: String) -> int:
	match label:
		"mono":
			return 0
		"stereo":
			return 1
		"foa_acn_sn3d":
			return 2
		"raw_4ch":
			return 3
		_:
			return 1


func _try_start_camera_plugin() -> void:
	if camera_plugin == null or not _camera_configured or _camera_start_attempted:
		return
	var has_permission: bool = bool(camera_plugin.call("hasCameraPermission"))
	if not has_permission:
		if not _camera_permission_wait_logged:
			_camera_permission_wait_logged = true
			print("%s waiting for camera permission" % _provider_label())
		camera_plugin.call("requestCameraPermission")
		return
	var wants_audio: bool = bool(_capture_option("record_audio", false))
	if wants_audio:
		var has_audio_permission: bool = bool(camera_plugin.call("hasAudioPermission"))
		if not has_audio_permission:
			var now_us := Time.get_ticks_usec()
			if not _audio_permission_wait_logged:
				_audio_permission_wait_logged = true
				_audio_permission_wait_started_ticks_us = now_us
				print("%s waiting for audio permission" % _provider_label())
			camera_plugin.call("requestAudioPermission")
			if now_us - _audio_permission_wait_started_ticks_us < AUDIO_PERMISSION_GRACE_US:
				return
			if not _audio_permission_degraded_logged:
				_audio_permission_degraded_logged = true
				print("%s audio permission missing; starting without audio" % _provider_label())
	_camera_start_attempted = true
	var started := false
	if _capture_provider_name == "pico":
		started = _start_pico_openxr_camera_image_capture()
	else:
		print("%s invoking startCameras" % _provider_label())
		started = bool(camera_plugin.call("startCameras"))
		print("%s startCameras returned: %s" % [_provider_label(), started])
	if not started:
		_abort_capture_start("%s camera start failed" % _provider_label())


func _stop_camera_plugin() -> void:
	if camera_plugin != null:
		camera_plugin.call("stopCameras")
	if _capture_provider_name == "pico" and pico_openxr_bridge != null and pico_openxr_bridge.has_method("stop_camera_image_capture"):
		pico_openxr_bridge.call("stop_camera_image_capture")
	_pico_camera_image_started = false


func _on_openxr_session_begun() -> void:
	if _xr_session_begun:
		return
	_xr_session_begun = true
	if keep_passthrough_visible:
		_set_passthrough_visible(true)
	if not keep_safety_zone_visible:
		_suppress_boundary_visibility()
	if _recording and _stream_enabled("record_depth"):
		depth_sampler.start()


func _on_openxr_session_stopping() -> void:
	_xr_session_begun = false
	if _recording:
		depth_sampler.stop()
	_set_passthrough_visible(false)


func _on_camera_ready(eye: String, camera_id: String) -> void:
	print("%s camera ready: %s=%s" % [_provider_label(), eye, camera_id])


func _on_camera_frame_saved(eye: String, _path: String, timestamp_ns: int) -> void:
	if timestamp_ns > 0 and eye == "left":
		print_verbose("%s frames are being recorded" % _provider_label())


func _on_camera_error(message: String) -> void:
	_last_capture_error = message
	push_error("%s: %s" % [_provider_label(), message])


func _on_live_feed_connected(endpoint: String) -> void:
	print("Live feed push connected: %s" % endpoint)


func _on_live_feed_disconnected(endpoint: String) -> void:
	print("Live feed push disconnected: %s" % endpoint)


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	var code := key_event.keycode
	if code == KEY_NONE:
		code = key_event.physical_keycode
	if code == KEY_VOLUMEUP or code == KEY_VOLUMEDOWN:
		print("Volume key received: %s mode=%s" % [code, capture_options.get("interaction_mode", "")])
	if str(capture_options.get("interaction_mode", "")) != "head":
		return
	if code == KEY_VOLUMEUP and not _recording:
		print("Volume-up requested capture start")
		start_capture()
		get_viewport().set_input_as_handled()
	elif code == KEY_VOLUMEDOWN and _recording:
		print("Volume-down requested capture stop")
		stop_capture()
		get_viewport().set_input_as_handled()


func _on_capture_settings_saved(options: Dictionary) -> void:
	if _recording:
		return
	var prev_record_audio := bool(capture_options.get("record_audio", false))
	_merge_capture_options(options)
	capture_options["save_root"] = _configured_save_root()
	_tracker_status_refresh_accum = TRACKER_STATUS_REFRESH_SECONDS
	_release_ui_pointer()
	record_control.show_for_mode(str(capture_options.get("interaction_mode", "controllers")))
	_prepare_output_storage()
	# If the operator just flipped Audio on, drop the once-per-session latch
	# so the next idle tick fires the system permission prompt. Without this
	# they'd only see the prompt the first time they tapped Start, which is
	# too late if the dialog gets dismissed during capture.
	if not prev_record_audio and bool(capture_options.get("record_audio", false)):
		_audio_permission_prompt_fired = false
	# The settings panel already persisted this snapshot through
	# BaseSettingsPanel before emitting `saved`.
	# Redact the token in the log so it does not land in adb logcat /
	# crash.log uploads.
	var log_view := capture_options.duplicate(true)
	if str(log_view.get("upload_token", "")) != "":
		log_view["upload_token"] = "<redacted>"
	print("Capture options updated: %s" % JSON.stringify(log_view))


func _on_connect_live_server_requested(options: Dictionary) -> void:
	if not _is_live_feed_mode():
		return
	_merge_capture_options(options)
	var host := str(capture_options.get("server_host", default_live_server_host))
	var port := int(capture_options.get("server_result_port", default_live_result_port))
	_set_live_server_connectivity_status(
		tr("UI_LIVE_SERVER_CONNECTING") % [host, port],
		"normal"
	)
	_start_live_pull()


func _start_live_pull() -> void:
	if not _is_live_feed_mode() or live_pull_view == null:
		return
	if not live_pull_view.has_method("connect_to_server"):
		return
	var host := str(capture_options.get("server_host", default_live_server_host))
	var port := int(capture_options.get("server_result_port", default_live_result_port))
	print("Live feed pull connecting: %s:%d" % [host, port])
	live_pull_view.call("connect_to_server", host, port)


func _stop_live_pull() -> void:
	if live_pull_view != null and live_pull_view.has_method("disconnect_from_server"):
		print("Live feed pull disconnecting")
		live_pull_view.call("disconnect_from_server")


func _on_live_pull_connected(host: String, port: int) -> void:
	_set_live_server_connectivity_status(
		tr("UI_LIVE_SERVER_CONNECTED") % [host, port],
		"success"
	)


func _on_live_pull_disconnected(host: String, port: int) -> void:
	_set_live_server_connectivity_status(
		tr("UI_LIVE_SERVER_DISCONNECTED") % [host, port],
		"warning"
	)


func _on_live_pull_connection_failed(_host: String, _port: int, reason: String) -> void:
	_set_live_server_connectivity_status(
		tr("UI_LIVE_SERVER_CONNECTION_FAILED") % reason,
		"error"
	)


func _set_live_server_connectivity_status(text: String, level: String) -> void:
	if settings_panel != null and settings_panel.has_method("set_live_server_connectivity_status"):
		settings_panel.set_live_server_connectivity_status(text, level)


func _on_exit_requested() -> void:
	# Exit from the in-mode settings panel returns to the launcher / mode
	# select page so the user can pick a different mode without restarting
	# the app. The launcher's own Exit card is what actually quits the
	# process (see scenes/mode_select.gd). Any active capture / live pull
	# is stopped first so we don't leak an MP4 muxer or a network reader.
	_release_ui_pointer()
	if _recording:
		stop_capture()
	_stop_live_pull()
	_set_passthrough_visible(false)
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _update_view_locked_panel() -> void:
	if hmd_camera == null:
		return
	if settings_panel:
		settings_panel.transform = hmd_camera.transform * SETTINGS_PANEL_OFFSET
	if record_control:
		record_control.transform = hmd_camera.transform * RECORD_CONTROL_OFFSET
	if status_popup:
		status_popup.transform = hmd_camera.transform * STATUS_POPUP_OFFSET
	if qr_scanner and qr_scanner.visible:
		qr_scanner.transform = hmd_camera.transform * QR_SCANNER_OFFSET


func _update_ui_pointer() -> void:
	if settings_interaction_router == null:
		return
	settings_interaction_router.interaction_mode = str(capture_options.get("interaction_mode", "controllers"))
	settings_interaction_router.busy = _recording
	# Scanner is intentionally target[0] so SettingsInteractionRouter's
	# `_should_use_controller_pointer` returns true for it regardless of
	# interaction_mode — picking a small floating arrow with a hand pinch
	# is too fiddly. When the scanner isn't visible the router's
	# `_active_target()` skips past it to the settings/record panel.
	# status_popup must stay in this per-frame list (matching _setup_ui):
	# during an upload it is the only visible target, and dropping it here
	# leaves _active_target() empty — the cancel button never receives the
	# ray and the whole pointer (hands included) goes dark.
	settings_interaction_router.set_targets([qr_scanner, settings_panel, status_popup, record_control])
	settings_interaction_router.update_pointer()


func _release_ui_pointer() -> void:
	if settings_interaction_router:
		settings_interaction_router.release_pointer()


func _on_settings_requested() -> void:
	if _recording:
		return
	_release_ui_pointer()
	record_control.hide_control()
	var mode := str(capture_options.get("interaction_mode", "controllers"))
	if settings_panel != null and settings_panel.has_method("set_feedback_input_mode"):
		settings_panel.set_feedback_input_mode(mode, right_pointer if mode == "controllers" else null)
	settings_panel.open()
	_tracker_status_refresh_accum = TRACKER_STATUS_REFRESH_SECONDS
	_update_pico_tracker_setup_status(0.0)


func _open_live_feed_settings() -> void:
	if not _is_live_feed_mode() or settings_panel == null:
		return
	_release_ui_pointer()
	if record_control != null:
		record_control.hide_control()
	if settings_panel.has_method("show_live_server_settings"):
		settings_panel.show_live_server_settings()
	else:
		settings_panel.open()


func _create_writer() -> Object:
	if _is_live_feed_mode():
		var live_writer = LivePushWriterScript.new()
		live_writer.configure_server(default_live_server_host, default_live_server_port, default_live_server_auth_token)
		return live_writer
	return SessionSpoolWriterScript.new()


func _is_live_feed_mode() -> bool:
	return capture_sink == "server"


func _active_sink_plugin() -> Object:
	return live_server_plugin if _is_live_feed_mode() else muxer_plugin


func _stream_enabled(option: String) -> bool:
	return bool(_capture_option(option, true))


func _capture_option(option: String, fallback: Variant = null) -> Variant:
	var source: Dictionary = _active_capture_options if _recording and not _active_capture_options.is_empty() else capture_options
	return source.get(option, fallback)


func _effective_capture_options(options: Dictionary) -> Dictionary:
	var effective := options.duplicate(true)
	if camera_plugin == null:
		_bind_android_plugin()
	if camera_plugin != null:
		if not CaptureProviderRegistryScript.supports_depth(camera_plugin):
			effective["record_depth"] = false
		if not CaptureProviderRegistryScript.supports_body_motion(camera_plugin):
			effective["record_body_tracking"] = false
			effective["record_motion_trackers"] = false
		# Motion trackers (PICO XR_PICO_motion_tracking) are PICO-only even
		# when the provider reports body-motion support — Quest's body data
		# comes purely from the Meta vendor AAR's XR_FB_body_tracking +
		# XR_META_body_tracking_full_body extensions, no external trackers.
		if CaptureProviderRegistryScript.provider_name(camera_plugin) != "pico":
			effective["record_motion_trackers"] = false
		if CaptureProviderRegistryScript.provider_name(camera_plugin) == "pico":
			effective["record_audio"] = false
	return effective


func _provider_label() -> String:
	return "%sCapturePlugin" % _capture_provider_name.capitalize() if not _capture_provider_name.is_empty() else "CaptureProvider"


func _start_pico_openxr_camera_image_capture() -> bool:
	if pico_openxr_bridge == null:
		push_error("PicoOpenXRExtension is not available; cannot start XR_PICO_camera_image")
		return false
	if not pico_openxr_bridge.has_method("start_camera_image_capture"):
		push_error("PicoOpenXRExtension does not expose start_camera_image_capture")
		return false
	var stereo := bool(_capture_option("stereo_rgb", true))
	var fps := int(_capture_option("rgb_fps", DEFAULT_RGB_FPS))
	var info: Variant = pico_openxr_bridge.call("start_camera_image_capture", stereo, 640, 480, fps)
	if typeof(info) != TYPE_DICTIONARY:
		push_error("XR_PICO_camera_image start returned invalid info")
		return false
	var info_dict := info as Dictionary
	print("XR_PICO_camera_image start info: %s" % JSON.stringify(info_dict))
	if not bool(info_dict.get("active", false)):
		push_error("XR_PICO_camera_image did not become active: %s" % JSON.stringify(info_dict))
		return false
	_pico_camera_frame_interval_s = 1.0 / max(float(info_dict.get("fps", DEFAULT_RGB_FPS)), 1.0)
	if camera_plugin.has_method("setOpenXrCameraImageInfoJson"):
		camera_plugin.call("setOpenXrCameraImageInfoJson", JSON.stringify(info_dict))
	var started: bool = bool(camera_plugin.call("startOpenXrCameraImageCapture", JSON.stringify(info_dict)))
	print("%s startOpenXrCameraImageCapture returned: %s" % [_provider_label(), started])
	_pico_camera_image_started = started
	return started


func _pump_pico_openxr_camera_frames(delta: float) -> void:
	if _capture_provider_name != "pico" or not _pico_camera_image_started:
		return
	if pico_openxr_bridge == null or camera_plugin == null:
		return
	_pico_camera_frame_accum_s += delta
	if _pico_camera_frame_accum_s < _pico_camera_frame_interval_s * 0.5:
		return
	_pico_camera_frame_accum_s = 0.0
	var frames: Variant = pico_openxr_bridge.call("poll_camera_image_frames")
	if typeof(frames) != TYPE_ARRAY:
		return
	for frame_variant in frames:
		if typeof(frame_variant) != TYPE_DICTIONARY:
			continue
		var frame := frame_variant as Dictionary
		var data: Variant = frame.get("data", PackedByteArray())
		if typeof(data) != TYPE_PACKED_BYTE_ARRAY:
			continue
		var ok: bool = bool(camera_plugin.call(
			"submitOpenXrRgbaFrame",
			str(frame.get("eye", "left")),
			int(frame.get("xr_time_ns", 0)),
			int(frame.get("width", 0)),
			int(frame.get("height", 0)),
			int(frame.get("stride", 0)),
			int(frame.get("effective_pixel_stride", frame.get("pixel_stride", frame.get("bytes_per_pixel", 4)))),
			data
		))
		if not ok and not _pico_camera_submit_warned:
			_pico_camera_submit_warned = true
			push_warning("Pico OpenXR camera frame submission failed; continuing to poll for later frames.")


func _push_pico_external_camera_info_if_available() -> void:
	if _capture_provider_name != "pico" or pico_openxr_bridge == null:
		return
	if not pico_openxr_bridge.has_method("get_external_camera_info"):
		return
	var info: Variant = pico_openxr_bridge.call("get_external_camera_info")
	if typeof(info) != TYPE_DICTIONARY:
		return
	var ok: Variant = camera_plugin.call("setOpenXrExternalCameraInfoJson", JSON.stringify(info))
	print("Pico external camera info forwarded: %s %s" % [ok, JSON.stringify(info)])


func _abort_capture_start(message: String) -> void:
	_last_capture_error = message
	push_error(message)
	if _recording:
		stop_capture()


func _merge_capture_options(options: Dictionary) -> void:
	for key in options.keys():
		capture_options[key] = options[key]


func _upload_config_available() -> bool:
	return bool(capture_options.get("upload_on_finalize", false)) and not str(capture_options.get("upload_url", "")).strip_edges().is_empty()


func _configured_save_root() -> String:
	var configured := str(capture_options.get("save_root", DEFAULT_SAVE_ROOT)).strip_edges()
	return DEFAULT_SAVE_ROOT if configured.is_empty() else configured


func _prepare_output_storage() -> void:
	if _is_live_feed_mode():
		return
	if OS.get_name() != "Android" or camera_plugin == null:
		return
	if not bool(camera_plugin.call("hasStoragePermission")):
		camera_plugin.call("requestStoragePermission")
		print("Waiting for shared-storage permission for: %s" % _configured_save_root())
		return
	camera_plugin.call("ensureOutputDirectory", _configured_save_root())


func _ensure_output_storage_ready() -> bool:
	if _is_live_feed_mode():
		return true
	capture_options["save_root"] = _configured_save_root()
	var capture_root := _configured_save_root()
	if OS.get_name() == "Android":
		if camera_plugin == null:
			_bind_android_plugin()
		if camera_plugin == null:
			push_error("Storage setup requires an Android capture provider.")
			return false
		if not bool(camera_plugin.call("hasStoragePermission")):
			camera_plugin.call("requestStoragePermission")
			print("Capture waiting for shared-storage permission: %s" % capture_root)
			return false
		if not bool(camera_plugin.call("ensureOutputDirectory", capture_root)):
			push_error("Capture output directory is not writable: %s" % capture_root)
			return false
		return true
	var result := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture_root))
	if result != OK:
		push_error("Capture output directory could not be created: %s" % capture_root)
	return result == OK


func _has_pose_streams_enabled() -> bool:
	return _stream_enabled("record_head_pose") or _stream_enabled("record_controller_pose") or _stream_enabled("record_hand_data")


func _has_body_motion_streams_enabled() -> bool:
	return _stream_enabled("record_body_tracking") or _stream_enabled("record_motion_trackers")


func _update_pico_tracker_setup_status(delta: float) -> void:
	if settings_panel == null or not bool(settings_panel.get("visible")):
		return
	if not settings_panel.has_method("set_pico_tracker_status"):
		return
	_tracker_status_refresh_accum += delta
	if _tracker_status_refresh_accum < TRACKER_STATUS_REFRESH_SECONDS:
		return
	_tracker_status_refresh_accum = 0.0
	var options: Dictionary = settings_panel.get_options() if settings_panel.has_method("get_options") else capture_options
	if not _pico_tracker_setup_required(options):
		settings_panel.call("set_pico_tracker_status", false, false, 0, false, false, false)
		return
	var status := _pico_openxr_status()
	var tracker_count := int(status.get("motion_tracker_count", 0))
	var connected := tracker_count > 0
	var request_sent := bool(status.get("motion_request_sent", false))
	var opening_setup := _tracker_setup_opened_ticks_us > 0 and Time.get_ticks_usec() - _tracker_setup_opened_ticks_us < int(TRACKER_SETUP_OPENING_SECONDS * 1000000.0)
	var can_open_setup := pico_openxr_bridge != null and (
			pico_openxr_bridge.has_method("request_motion_trackers")
			or pico_openxr_bridge.has_method("start_body_tracking_calibration_app")
	)
	settings_panel.call("set_pico_tracker_status", true, connected, tracker_count, request_sent, can_open_setup, opening_setup)


func _on_tracker_connect_requested() -> void:
	var options: Dictionary = settings_panel.get_options() if settings_panel != null and settings_panel.has_method("get_options") else capture_options
	if not _pico_tracker_setup_required(options):
		return
	var opened := _request_pico_motion_trackers(options, true)
	if not opened and pico_openxr_bridge != null and pico_openxr_bridge.has_method("start_body_tracking_calibration_app"):
		opened = bool(pico_openxr_bridge.call("start_body_tracking_calibration_app"))
	if opened:
		_tracker_setup_opened_ticks_us = Time.get_ticks_usec()
		print("PICO tracker setup requested")
	else:
		push_warning("PICO tracker setup is unavailable from the current OpenXR session.")
	_tracker_status_refresh_accum = TRACKER_STATUS_REFRESH_SECONDS
	_update_pico_tracker_setup_status(0.0)


func _pico_tracker_setup_required(options: Dictionary) -> bool:
	if camera_plugin == null:
		_bind_android_plugin()
	if camera_plugin == null or CaptureProviderRegistryScript.provider_name(camera_plugin) != "pico":
		return false
	return bool(options.get("record_body_tracking", false)) or bool(options.get("record_motion_trackers", false))


func _request_pico_motion_trackers(options: Dictionary, force: bool = false) -> bool:
	if pico_openxr_bridge == null or not pico_openxr_bridge.has_method("request_motion_trackers"):
		return false
	var max_trackers := clampi(int(options.get("max_motion_trackers", 3)), 0, 6)
	if max_trackers <= 0:
		return false
	var now_us := Time.get_ticks_usec()
	if not force and _tracker_last_request_ticks_us > 0 and now_us - _tracker_last_request_ticks_us < int(TRACKER_REQUEST_RETRY_SECONDS * 1000000.0):
		return false
	_tracker_last_request_ticks_us = now_us
	return bool(pico_openxr_bridge.call("request_motion_trackers", max_trackers))


## Auto-detect hand-vs-controller state and surface it to the settings
## panel + interaction router. The runtime answer flips when the operator
## puts a controller down (or back into the optical tracker's FOV), so we
## re-probe a few times per second instead of caching it for the lifetime
## of the session.
func _update_input_mode_detection(delta: float) -> void:
	_input_mode_detect_accum += delta
	if _input_mode_detect_accum < INPUT_MODE_DETECT_INTERVAL_S:
		return
	_input_mode_detect_accum = 0.0
	# "head" is a niche volume-button capture flow opted into by automation
	# args (see _collect_capture_automation_args). It has nothing to do with
	# the physical input source, so detection must not stamp over it.
	if str(capture_options.get("interaction_mode", "")) == "head":
		if settings_panel != null and settings_panel.has_method("set_interaction_mode"):
			settings_panel.call("set_interaction_mode", "head")
		return
	var detected := _detect_input_mode()
	if detected == "":
		return
	if detected == _input_mode_detected:
		return
	_input_mode_detected = detected
	# Auto-flip the record stream defaults so a gesture recording does not
	# silently keep writing dead controller poses (and vice versa). Mirrors
	# the rule the panel applies on set_interaction_mode().
	if detected == "hands":
		capture_options["record_hand_data"] = true
		capture_options["record_controller_pose"] = false
	elif detected == "controllers":
		capture_options["record_controller_pose"] = true
		capture_options["record_hand_data"] = false
	# NOTE: We intentionally do NOT write capture_options["interaction_mode"]
	# here, even though detection drives the indicator + record defaults.
	# That key feeds the settings interaction router's pointer mode, and on
	# main the router stayed on the controller laser; switching it to
	# hand-pinch mid-session regressed the gesture ray, so we leave the
	# router-facing mode at its initialized value ("controllers" by default,
	# or whatever automation args set explicitly).
	if settings_panel != null and settings_panel.has_method("set_interaction_mode"):
		settings_panel.call("set_interaction_mode", detected)
	# We intentionally do NOT persist on every detection flip -- a wobbly
	# tracking moment could otherwise spam the settings cfg. The mode is
	# re-detected on every launch, and the settings panel persists through
	# BaseSettingsPanel when the operator presses Save.


func _detect_input_mode() -> String:
	# Optical hand tracking wins when either hand has unobstructed data --
	# the operator can wear controllers but if their hands are also visible
	# we treat the session as a hand session. Falls back to the controller
	# state, then to whatever we last saw so the indicator doesn't flicker
	# during a brief drop-out.
	if _hand_tracker_active(&"/user/hand_tracker/left") or _hand_tracker_active(&"/user/hand_tracker/right"):
		return "hands"
	if _controller_active(left_controller) or _controller_active(right_controller):
		return "controllers"
	return ""


func _hand_tracker_active(tracker_path: StringName) -> bool:
	var tracker := XRServer.get_tracker(tracker_path)
	if not (tracker is XRHandTracker):
		return false
	var hand_tracker := tracker as XRHandTracker
	return hand_tracker.has_tracking_data \
			and hand_tracker.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED


func _controller_active(controller: XRController3D) -> bool:
	return controller != null and controller.get_is_active() and controller.get_has_tracking_data()


## Push the "external motion-tracker capture is available on this device?"
## flag into the settings panel once we know the provider. Motion trackers
## (waist / feet pucks via XR_PICO_motion_tracking) are PICO-only — Quest
## body tracking goes through XR_FB_body_tracking / XR_META_body_tracking_full_body
## instead and has no external tracker concept — so anywhere else we hide
## the toggle entirely.
func _update_motion_tracker_support_flag() -> void:
	if settings_panel == null or not settings_panel.has_method("set_motion_tracker_supported"):
		return
	if camera_plugin == null:
		_bind_android_plugin()
	if camera_plugin == null:
		# Provider not yet bound — try again next frame; we don't want to
		# tell the panel "tracker capture is gone" while the singleton is
		# still loading on cold boot.
		return
	# IMPORTANT: this is supports_motion_trackers, NOT supports_body_motion.
	# Quest reports supports_body_motion=true (via Meta XR body tracking)
	# but has no external tracker hardware — using the body-motion flag
	# here would surface a non-functional PICO tracker UI on Quest.
	var supported := CaptureProviderRegistryScript.supports_motion_trackers(camera_plugin)
	if _motion_tracker_provider_known and supported == _motion_tracker_supported_pushed:
		return
	_motion_tracker_provider_known = true
	_motion_tracker_supported_pushed = supported
	settings_panel.call("set_motion_tracker_supported", supported)
	if not supported:
		# Force the in-memory option off so the configure path doesn't
		# claim to record trackers that aren't there.
		capture_options["record_motion_trackers"] = false


## Audio defaults to ON, so we proactively request the RECORD_AUDIO runtime
## permission as soon as the capture provider is bound -- before the user
## ever taps Start. Without this the system prompt would only appear mid-
## capture inside _start_camera_plugin(), and a denied/ignored prompt would
## silently produce a video-only recording with no chance for the operator
## to react.
##
## Idempotent: a single up-front prompt per app session. Re-prompting on
## every frame would spam the Android permission dialog and is what
## _try_start_camera_plugin's grace-window logic guards against further
## downstream.
func _ensure_audio_permission_prompted() -> void:
	if _audio_permission_prompt_fired:
		return
	if not bool(capture_options.get("record_audio", false)):
		return
	if camera_plugin == null:
		_bind_android_plugin()
	if camera_plugin == null:
		return
	# Pico capture today disables the audio track regardless (see
	# _effective_capture_options) -- skip the prompt so the operator isn't
	# asked for a permission the session won't end up using.
	if CaptureProviderRegistryScript.provider_name(camera_plugin) == "pico":
		_audio_permission_prompt_fired = true
		return
	# Android plugin singletons sometimes do not reflect @UsedByGodot methods
	# through has_method() (mirrors the camera-permission call elsewhere in
	# this file), so call directly. hasAudioPermission() is part of the same
	# Kotlin contract as hasCameraPermission().
	var granted: bool = bool(camera_plugin.call("hasAudioPermission"))
	if granted:
		_audio_permission_prompt_fired = true
		print("%s audio permission already granted" % _provider_label())
		return
	camera_plugin.call("requestAudioPermission")
	_audio_permission_prompt_fired = true
	print("%s requested audio permission up front (record_audio=on)" % _provider_label())


func _pico_openxr_status() -> Dictionary:
	if pico_openxr_bridge == null or not pico_openxr_bridge.has_method("get_status"):
		return {}
	var raw: Variant = pico_openxr_bridge.call("get_status")
	if typeof(raw) == TYPE_DICTIONARY:
		return raw
	return {}


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
	_start_upload_ack(payload)


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


func _start_upload_ack(payload: String) -> void:
	var trimmed := payload.strip_edges()
	if trimmed.is_empty():
		return
	# A QR carrying a plain ingest URL (no signed-ack challenge) — common
	# for self-hosted setups where the operator just wants to paste the
	# endpoint into the field. Skip the ack handshake and apply directly,
	# so the URL persists into the panel + config the same way a successful
	# ack would. The signed-ack path stays the secure default for cloud
	# ingest servers that hand out per-session credentials.
	if not _is_signed_ack_payload(trimmed):
		if _looks_like_http_url(trimmed):
			print("[UploadAck] applying plain URL from QR %s" % trimmed)
			_apply_scanned_upload_endpoint(trimmed, "", false)
			return
		_on_upload_ack_failed(tr("UI_UPLOAD_ACK_INVALID_QR"))
		return
	_pending_upload_ack_payload = trimmed
	if settings_panel and settings_panel.has_method("set_upload_connectivity_status"):
		settings_panel.set_upload_connectivity_status(tr("UI_UPLOAD_ACK_CHECKING"), "normal")
	print("[UploadAck] checking ack %s" % trimmed)
	if upload_ack_request == null:
		_on_upload_ack_failed(tr("UI_UPLOAD_ACK_UNAVAILABLE"))
		return
	if upload_ack_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		upload_ack_request.cancel_request()
	var headers := PackedStringArray([
		"User-Agent: ego-uploader/1.0 (godot)",
	])
	var err := upload_ack_request.request(trimmed, headers, HTTPClient.METHOD_GET)
	if err != OK:
		_on_upload_ack_failed(tr("UI_UPLOAD_ACK_REQUEST_FAILED") % err)


func _is_signed_ack_payload(payload: String) -> bool:
	return payload.find("/ack") >= 0 and payload.find("exp=") >= 0 and payload.find("sig=") >= 0


# Loose URL check used by the plain-URL fallback in _start_upload_ack.
# We accept http/https only — the ingest endpoint must be reachable as a
# normal HTTP request, and any other scheme (mailto:, geo:, ftp:, …) is
# almost certainly the wrong QR.
func _looks_like_http_url(payload: String) -> bool:
	var lower := payload.to_lower()
	if not (lower.begins_with("http://") or lower.begins_with("https://")):
		return false
	# Strip the scheme and confirm there's actually a host. Avoids accepting
	# "https://" or "http:// trailing junk" as valid endpoints.
	var after_scheme := payload.substr(payload.find("://") + 3).strip_edges()
	return not after_scheme.is_empty()


func _on_upload_ack_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_on_upload_ack_failed(tr("UI_UPLOAD_ACK_NETWORK_FAILED") % result)
		return
	var text := body.get_string_from_utf8()
	if response_code < 200 or response_code >= 300:
		_on_upload_ack_failed(tr("UI_UPLOAD_ACK_HTTP_FAILED") % [response_code, text.substr(0, 80)])
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_on_upload_ack_failed(tr("UI_UPLOAD_ACK_BAD_RESPONSE"))
		return
	if not bool(parsed.get("ok", false)):
		_on_upload_ack_failed(str(parsed.get("error", tr("UI_UPLOAD_ACK_BAD_RESPONSE"))))
		return
	var upload_url := str(parsed.get("uploadUrl", parsed.get("upload_url", ""))).strip_edges()
	if upload_url.is_empty():
		_on_upload_ack_failed(tr("UI_UPLOAD_ACK_BAD_RESPONSE"))
		return
	var upload_token := str(parsed.get("uploadToken", parsed.get("upload_token", "")))
	_apply_scanned_upload_endpoint(upload_url, upload_token, true)
	print("[UploadAck] ready upload_url=%s auth=%s" % [upload_url, "yes" if not upload_token.is_empty() else "no"])


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


func _suppress_boundary_visibility() -> void:
	if not Engine.has_singleton("OpenXRMetaBoundaryVisibilityExtensionWrapper"):
		return
	var boundary := Engine.get_singleton("OpenXRMetaBoundaryVisibilityExtensionWrapper")
	if boundary.has_method("is_boundary_visibility_supported") and bool(boundary.call("is_boundary_visibility_supported")):
		boundary.call("set_boundary_visible", false)
		print("Quest boundary visibility suppressed")
