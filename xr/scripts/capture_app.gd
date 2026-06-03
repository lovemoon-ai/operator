extends Node3D

const SessionSpoolWriterScript := preload("res://scripts/session_spool_writer.gd")
const PoseSamplerScript := preload("res://scripts/pose_sampler.gd")
const DepthSamplerScript := preload("res://scripts/depth_sampler.gd")
const ViewLockedCapturePanelScript := preload("res://scripts/view_locked_capture_panel.gd")
const ViewLockedRecordControlScript := preload("res://scripts/view_locked_record_control.gd")
const ViewLockedStatusPopupScript := preload("res://scripts/view_locked_status_popup.gd")
const OperatorUIPointerVisualScript := preload("res://scripts/xr/operator_ui_pointer_visual.gd")

const DEFAULT_SAVE_ROOT := "/sdcard/DCIM/SpatialMP4"
const DEFAULT_RGB_BITRATE := 24000000
const DEFAULT_RGB_FPS := 30
const LEFT_HAND_TRACKER := &"/user/hand_tracker/left"
const RIGHT_HAND_TRACKER := &"/user/hand_tracker/right"
const HAND_PINCH_DISTANCE_M := 0.028
const SETTINGS_PANEL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const RECORD_CONTROL_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.18, -0.86))
const STATUS_POPUP_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18, -0.92))
const CUE_SAMPLE_RATE := 32000

@export var auto_start := false
@export var pose_sample_hz := 90.0
@export var keep_passthrough_visible := true

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
var writer: Object
var pose_sampler: Node
var depth_sampler: Node
var cue_player: AudioStreamPlayer
var _start_cue: AudioStreamWAV
var _stop_cue: AudioStreamWAV
var camera_plugin: Object
var muxer_plugin: Object
var capture_options := {
	"interaction_mode": "controllers",
	"stereo_rgb": true,
	"record_depth": true,
	"record_head_pose": true,
	"record_controller_pose": true,
	"record_hand_data": true,
	"save_controller_hand_sidecar": false,
	"save_root": DEFAULT_SAVE_ROOT
}

var _recording := false
var _pose_accum := 0.0
var _capture_started_ticks_us := 0
var _xr_session_begun := false
var _camera_configured := false
var _camera_start_attempted := false
var _camera_bind_warned := false
var _camera_permission_wait_logged := false
var _passthrough_active := false
var _previous_transparent_bg := false
var _previous_environment_blend_mode := XRInterface.XR_ENV_BLEND_MODE_OPAQUE
var _previous_background_mode := Environment.BG_CLEAR_COLOR
var _previous_background_color := Color.BLACK
var _controller_pointer_down: XRController3D
var _hand_pointer_down := false
var _pressed_panel: Object

# 1Hz metrics ticker: tracks how many _process invocations and which phases
# (pose loop iterations, plugin probes) ran in the last second, then emits a
# single log line tagged "QcMetrics" so logcat can be grepped without
# combing through dozens of unrelated prints.
const METRICS_INTERVAL_S := 1.0
var _metrics_accum_s := 0.0
var _metrics_process_ticks := 0
var _metrics_pose_loop_iters := 0
var _metrics_started_ticks_us := 0
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
	_initialize_openxr()
	_bind_android_plugin()
	_setup_audio_cues()

	writer = SessionSpoolWriterScript.new()
	# _bind_android_plugin ran above when `writer` was still null, so its own
	# writer.set_*_plugin attempts were skipped; we re-wire both singletons
	# here against the freshly-created spool writer. Stage 2b's split moved
	# every write* RPC to the muxer plugin, so missing the second hand-off
	# silently no-ops every pose / depth / hand / input frame.
	if camera_plugin != null and writer.has_method("set_android_plugin"):
		writer.set_android_plugin(camera_plugin)
	if muxer_plugin != null and writer.has_method("set_muxer_plugin"):
		writer.set_muxer_plugin(muxer_plugin)
	pose_sampler = PoseSamplerScript.new()
	depth_sampler = DepthSamplerScript.new()

	add_child(pose_sampler)
	add_child(depth_sampler)
	pose_sampler.configure(writer, hmd_camera, left_controller, right_controller)
	depth_sampler.configure(writer)

	if AUTO_START_FOR_DEVICE_TEST:
		capture_options["interaction_mode"] = "head"
		if settings_panel and settings_panel.has_method("set_options"):
			settings_panel.set_options(capture_options)
		call_deferred("start_capture")
		var auto_stop_timer := Timer.new()
		auto_stop_timer.name = "AutoStopForDeviceTest"
		auto_stop_timer.one_shot = true
		auto_stop_timer.wait_time = AUTO_STOP_AFTER_SECONDS
		auto_stop_timer.timeout.connect(_auto_stop_for_device_test)
		add_child(auto_stop_timer)
		auto_stop_timer.start()
	elif auto_start:
		start_capture()


func _auto_stop_for_device_test() -> void:
	print("AUTO_STOP_FOR_DEVICE_TEST: stopping capture")
	stop_capture()
	await get_tree().create_timer(2.0).timeout
	print("AUTO_STOP_FOR_DEVICE_TEST: quitting")
	get_tree().quit()


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
	var plugin_metrics: Dictionary = {}
	if camera_plugin != null:
		var raw: Variant = camera_plugin.call("popMetricsJson")
		if typeof(raw) == TYPE_STRING and not String(raw).is_empty():
			var parsed: Variant = JSON.parse_string(String(raw))
			if typeof(parsed) == TYPE_DICTIONARY:
				plugin_metrics = parsed
	# Compact one-liner so it doesn't drown the rest of logcat. Tagged
	# "QcMetrics" so adb logcat -s godot:V | grep QcMetrics gives a clean
	# table.
	print("QcMetrics %.1fs recording=%s engine_fps=%d process_fps=%.1f pose_loop_iters=%d stages_ms={panel=%.1f,pointer=%.1f,record=%.1f,pose=%.1f,depth=%.1f,metrics=%.1f} pose=%s depth=%s plugin=%s" % [
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
		_compact_dict(plugin_metrics)
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
	_set_passthrough_visible(false)


func _notification(what: int) -> void:
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


func start_capture() -> void:
	if _recording:
		return

	if not _ensure_output_storage_ready():
		return
	if not bool(writer.start_session(capture_options)):
		push_error("Capture session did not start because its output directory could not be created.")
		return
	pose_sampler.set_capture_options(capture_options)
	_recording = true
	_pose_accum = 0.0
	_capture_started_ticks_us = Time.get_ticks_usec()
	_camera_configured = false
	_camera_start_attempted = false
	_camera_permission_wait_logged = false
	if record_control:
		record_control.set_recording(true)
	if _xr_session_begun and _stream_enabled("record_depth"):
		depth_sampler.start()
	_start_camera_plugin()
	_play_cue(_start_cue)
	print("Capture session started: %s" % writer.get_session_dir())


func stop_capture() -> void:
	if not _recording:
		return

	_stop_camera_plugin()
	depth_sampler.stop()
	writer.close()
	var saved_session_dir: String = writer.get_saved_path() if writer.has_method("get_saved_path") else writer.get_session_dir()
	_recording = false
	_camera_configured = false
	_camera_start_attempted = false
	_camera_permission_wait_logged = false
	if record_control:
		record_control.set_recording(false)
	_play_cue(_stop_cue)
	if status_popup and not saved_session_dir.is_empty():
		status_popup.show_saved_path(saved_session_dir)
	print("Capture session stopped: %s" % saved_session_dir)


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
	left_pointer.button_pressed.connect(_on_controller_button_pressed.bind(left_pointer))
	left_pointer.button_released.connect(_on_controller_button_released.bind(left_pointer))
	origin.add_child(left_pointer)

	right_pointer = XRController3D.new()
	right_pointer.name = "RightAimPointer"
	right_pointer.tracker = &"right_hand"
	right_pointer.pose = &"aim"
	right_pointer.button_pressed.connect(_on_controller_button_pressed.bind(right_pointer))
	right_pointer.button_released.connect(_on_controller_button_released.bind(right_pointer))
	origin.add_child(right_pointer)

	ui_pointer_visual = OperatorUIPointerVisualScript.new()
	ui_pointer_visual.name = "OperatorUIPointerVisual"
	origin.add_child(ui_pointer_visual)

	settings_panel = ViewLockedCapturePanelScript.new()
	settings_panel.name = "ViewLockedSettingsPanel"
	settings_panel.saved.connect(_on_capture_settings_saved)
	settings_panel.exit_requested.connect(_on_exit_requested)
	origin.add_child(settings_panel)
	capture_options = settings_panel.get_options()

	record_control = ViewLockedRecordControlScript.new()
	record_control.name = "ViewLockedRecordControl"
	record_control.start_requested.connect(start_capture)
	record_control.stop_requested.connect(stop_capture)
	record_control.settings_requested.connect(_on_settings_requested)
	origin.add_child(record_control)

	status_popup = ViewLockedStatusPopupScript.new()
	status_popup.name = "ViewLockedStatusPopup"
	origin.add_child(status_popup)


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
		print("Quest passthrough view enabled")
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
		print("Quest passthrough view disabled")


func _bind_android_plugin() -> void:
	if camera_plugin != null and muxer_plugin != null:
		return
	# Stage 2b split the monolithic QuestCapturePlugin singleton into a provider
	# (cameras + clock + depth conversion) and a muxer (writer handle + the
	# write* RPCs). Both must be present at runtime; bindMuxer wires the
	# provider's RGB hot path to the muxer through SpatialDataSink.
	if camera_plugin == null and Engine.has_singleton("QuestCapturePlugin"):
		camera_plugin = Engine.get_singleton("QuestCapturePlugin")
		camera_plugin.connect("camera_ready", Callable(self, "_on_camera_ready"))
		camera_plugin.connect("camera_frame_saved", Callable(self, "_on_camera_frame_saved"))
		camera_plugin.connect("camera_error", Callable(self, "_on_camera_error"))
		_camera_bind_warned = false
		print("QuestCapturePlugin singleton bound")
	if muxer_plugin == null and Engine.has_singleton("SpatialMp4MuxerPlugin"):
		muxer_plugin = Engine.get_singleton("SpatialMp4MuxerPlugin")
		muxer_plugin.connect("camera_error", Callable(self, "_on_camera_error"))
		print("SpatialMp4MuxerPlugin singleton bound (contract v%d)" % int(muxer_plugin.call("getMuxerContractVersion")))
	if camera_plugin != null and muxer_plugin != null:
		# Kotlin-direct sink binding: RGB CSD + packets bypass GDScript on the
		# per-frame path. Depth / pose / hand / input still flow through
		# session_spool_writer.gd to the muxer singleton -- see writer wiring.
		var bound: Variant = camera_plugin.call("bindMuxer", muxer_plugin)
		if not bool(bound):
			push_warning("QuestCapturePlugin.bindMuxer(SpatialMp4MuxerPlugin) returned false; RGB writes will fail")
		if writer != null and writer.has_method("set_android_plugin"):
			writer.set_android_plugin(camera_plugin)
		if writer != null and writer.has_method("set_muxer_plugin"):
			writer.set_muxer_plugin(muxer_plugin)
		return
	if camera_plugin == null and not _camera_bind_warned:
		_camera_bind_warned = true
		print("QuestCapturePlugin singleton is not installed yet; RGB capture is waiting.")
		push_warning("QuestCapturePlugin singleton is not installed; RGB capture is disabled.")


func _start_camera_plugin() -> void:
	if camera_plugin == null:
		print("QuestCapturePlugin start skipped: singleton is not bound")
		return

	var session_dir_absolute: String = writer.get_session_dir_absolute()
	var output_mp4_absolute: String = writer.get_output_mp4_path_absolute()
	var partial_mp4_absolute: String = writer.get_partial_mp4_path_absolute()
	print("QuestCapturePlugin configure begin: %s" % output_mp4_absolute)
	var configured_result: Variant = camera_plugin.call(
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
		bool(capture_options.get("stereo_rgb", true)),
		int(capture_options.get("rgb_bitrate", DEFAULT_RGB_BITRATE)),
		int(capture_options.get("rgb_fps", DEFAULT_RGB_FPS))
	)
	_camera_configured = bool(configured_result)
	print("QuestCapturePlugin configureSessionWithTime returned: %s" % configured_result)
	if not _camera_configured:
		print("QuestCapturePlugin configure failed; RGB capture will retry")
		return

	camera_plugin.call("requestCameraPermission")
	print("QuestCapturePlugin requested camera permissions")
	_try_start_camera_plugin()


func _try_start_camera_plugin() -> void:
	if camera_plugin == null or not _camera_configured or _camera_start_attempted:
		return
	var has_permission: bool = bool(camera_plugin.call("hasCameraPermission"))
	if not has_permission:
		if not _camera_permission_wait_logged:
			_camera_permission_wait_logged = true
			print("QuestCapturePlugin waiting for camera permission")
		camera_plugin.call("requestCameraPermission")
		return
	_camera_start_attempted = true
	print("QuestCapturePlugin invoking startCameras")
	var started: bool = bool(camera_plugin.call("startCameras"))
	print("QuestCapturePlugin startCameras returned: %s" % started)


func _stop_camera_plugin() -> void:
	if camera_plugin != null:
		camera_plugin.call("stopCameras")


func _on_openxr_session_begun() -> void:
	if _xr_session_begun:
		return
	_xr_session_begun = true
	if keep_passthrough_visible:
		_set_passthrough_visible(true)
	_suppress_boundary_visibility()
	if _recording and _stream_enabled("record_depth"):
		depth_sampler.start()


func _on_openxr_session_stopping() -> void:
	_xr_session_begun = false
	if _recording:
		depth_sampler.stop()
	_set_passthrough_visible(false)


func _on_camera_ready(eye: String, camera_id: String) -> void:
	print("QuestCapturePlugin camera ready: %s=%s" % [eye, camera_id])


func _on_camera_frame_saved(eye: String, _path: String, timestamp_ns: int) -> void:
	if timestamp_ns > 0 and eye == "left":
		print_verbose("QuestCapturePlugin frames are being recorded")


func _on_camera_error(message: String) -> void:
	push_error("QuestCapturePlugin: %s" % message)


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
	capture_options = options.duplicate(true)
	capture_options["save_root"] = _configured_save_root()
	_release_ui_pointer()
	record_control.show_for_mode(str(capture_options.get("interaction_mode", "controllers")))
	_prepare_output_storage()
	print("Capture options updated: %s" % JSON.stringify(capture_options))


func _on_exit_requested() -> void:
	_release_ui_pointer()
	if _recording:
		stop_capture()
	_set_passthrough_visible(false)
	get_tree().quit()


func _update_view_locked_panel() -> void:
	if hmd_camera == null:
		return
	if settings_panel:
		settings_panel.transform = hmd_camera.transform * SETTINGS_PANEL_OFFSET
	if record_control:
		record_control.transform = hmd_camera.transform * RECORD_CONTROL_OFFSET
	if status_popup:
		status_popup.transform = hmd_camera.transform * STATUS_POPUP_OFFSET


func _update_ui_pointer() -> void:
	var panel := _active_pointer_panel()
	if panel == null:
		_release_ui_pointer()
		return
	var mode := str(capture_options.get("interaction_mode", "controllers"))
	if settings_panel.visible or mode == "controllers" or (mode == "head" and not _recording):
		_update_controller_pointer(panel)
	elif mode == "hands":
		_update_hand_pointer(panel)
	else:
		_release_ui_pointer()


func _update_controller_pointer(panel: Object) -> void:
	if _hand_pointer_down:
		_release_pressed_panel()
		_hand_pointer_down = false
	var pointer: XRController3D = _controller_pointer_down
	if pointer == null:
		if right_pointer.get_has_tracking_data():
			pointer = right_pointer
		elif left_pointer.get_has_tracking_data():
			pointer = left_pointer
	if pointer:
		var ray_origin := pointer.global_transform.origin
		var ray_direction := -pointer.global_transform.basis.z
		if panel.update_pointer_from_ray(ray_origin, ray_direction):
			_show_ui_pointer_visual(ray_origin, ray_direction, panel, _controller_pointer_down != null)
		else:
			_hide_ui_pointer_visual()
	else:
		panel.clear_pointer()
		_hide_ui_pointer_visual()


func _update_hand_pointer(panel: Object) -> void:
	if _controller_pointer_down:
		_release_pressed_panel()
		_controller_pointer_down = null

	var tracker := _tracked_hand(RIGHT_HAND_TRACKER)
	if tracker == null:
		tracker = _tracked_hand(LEFT_HAND_TRACKER)
	if tracker == null:
		if _hand_pointer_down:
			_release_pressed_panel()
			_hand_pointer_down = false
		panel.clear_pointer()
		_hide_ui_pointer_visual()
		return

	var index_tip: Vector3 = origin.to_global(tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin)
	var thumb_tip: Vector3 = origin.to_global(tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin)
	var direction := index_tip - hmd_camera.global_position
	var has_intersection := false
	if direction.length_squared() > 0.000001:
		has_intersection = panel.update_pointer_from_ray(hmd_camera.global_position, direction.normalized())
	var pressed := has_intersection and index_tip.distance_to(thumb_tip) <= HAND_PINCH_DISTANCE_M
	if has_intersection:
		_show_ui_pointer_visual(hmd_camera.global_position, direction.normalized(), panel, pressed)
	else:
		_hide_ui_pointer_visual()
	if pressed != _hand_pointer_down:
		_hand_pointer_down = pressed
		if pressed:
			_press_panel(panel)
		else:
			_release_pressed_panel()


func _tracked_hand(tracker_name: StringName) -> XRHandTracker:
	var tracker := XRServer.get_tracker(tracker_name)
	if tracker is XRHandTracker and (tracker as XRHandTracker).has_tracking_data:
		return tracker as XRHandTracker
	return null


func _on_controller_button_pressed(action: String, pointer: XRController3D) -> void:
	var panel := _active_pointer_panel()
	if panel == null or not _is_pointer_click_action(action):
		return
	var mode := str(capture_options.get("interaction_mode", "controllers"))
	if not settings_panel.visible and mode != "controllers" and not (mode == "head" and not _recording):
		return
	if panel.update_pointer_from_ray(pointer.global_transform.origin, -pointer.global_transform.basis.z):
		_controller_pointer_down = pointer
		_show_ui_pointer_visual(pointer.global_transform.origin, -pointer.global_transform.basis.z, panel, true)
		_press_panel(panel)


func _on_controller_button_released(action: String, pointer: XRController3D) -> void:
	if not _is_pointer_click_action(action) or pointer != _controller_pointer_down:
		return
	_release_pressed_panel()
	_controller_pointer_down = null


func _release_ui_pointer() -> void:
	_release_pressed_panel()
	_controller_pointer_down = null
	_hand_pointer_down = false
	if settings_panel:
		settings_panel.clear_pointer()
	if record_control:
		record_control.clear_pointer()
	_hide_ui_pointer_visual()


func _active_pointer_panel() -> Object:
	if settings_panel and settings_panel.visible:
		return settings_panel
	if record_control and record_control.visible:
		return record_control
	return null


func _press_panel(panel: Object) -> void:
	_pressed_panel = panel
	panel.set_pointer_pressed(true)


func _release_pressed_panel() -> void:
	if _pressed_panel:
		_pressed_panel.set_pointer_pressed(false)
		_pressed_panel = null


func _show_ui_pointer_visual(ray_origin: Vector3, ray_direction: Vector3, panel: Object, pressed: bool) -> void:
	if ui_pointer_visual == null or not (panel is Node3D):
		return
	var hit_point := _panel_hit_point(panel as Node3D, ray_origin, ray_direction)
	ui_pointer_visual.show_ray(ray_origin, ray_direction, hit_point, pressed)


func _hide_ui_pointer_visual() -> void:
	if ui_pointer_visual:
		ui_pointer_visual.clear()


func _panel_hit_point(panel: Node3D, ray_origin: Vector3, ray_direction: Vector3) -> Vector3:
	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		return ray_origin
	var normal := panel.global_transform.basis.z.normalized()
	var denominator := normal.dot(direction)
	if absf(denominator) < 0.0001:
		return ray_origin + direction * 0.25
	var distance_m := normal.dot(panel.global_transform.origin - ray_origin) / denominator
	return ray_origin + direction * maxf(distance_m, 0.001)


func _on_settings_requested() -> void:
	if _recording:
		return
	_release_ui_pointer()
	record_control.hide_control()
	settings_panel.open()


func _stream_enabled(option: String) -> bool:
	return bool(capture_options.get(option, true))


func _configured_save_root() -> String:
	var configured := str(capture_options.get("save_root", DEFAULT_SAVE_ROOT)).strip_edges()
	return DEFAULT_SAVE_ROOT if configured.is_empty() else configured


func _prepare_output_storage() -> void:
	if OS.get_name() != "Android" or camera_plugin == null:
		return
	if not bool(camera_plugin.call("hasStoragePermission")):
		camera_plugin.call("requestStoragePermission")
		print("Waiting for shared-storage permission for: %s" % _configured_save_root())
		return
	camera_plugin.call("ensureOutputDirectory", _configured_save_root())


func _ensure_output_storage_ready() -> bool:
	capture_options["save_root"] = _configured_save_root()
	var capture_root := _configured_save_root()
	if OS.get_name() == "Android":
		if camera_plugin == null:
			_bind_android_plugin()
		if camera_plugin == null:
			push_error("Storage setup requires the QuestCapturePlugin on Android.")
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


func _is_pointer_click_action(action: String) -> bool:
	return action == "trigger_click" or action == "primary_click" or action == "select_button"


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


func _suppress_boundary_visibility() -> void:
	if not Engine.has_singleton("OpenXRMetaBoundaryVisibilityExtensionWrapper"):
		return
	var boundary := Engine.get_singleton("OpenXRMetaBoundaryVisibilityExtensionWrapper")
	if boundary.has_method("is_boundary_visibility_supported") and bool(boundary.call("is_boundary_visibility_supported")):
		boundary.call("set_boundary_visible", false)
		print("Quest boundary visibility suppressed")
