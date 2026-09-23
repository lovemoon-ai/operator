class_name CapturePipeline
extends Node
## Composition interpreter for capture: instantiates the source components,
## wires them to the sinks an output selection mounts (see
## EgoCaptureComposition) and drives one capture lifecycle.
##
## Any host of a capture mounts this node: the Ego mode for local recordings
## and ingest streaming, and a host session when its declaration asks for
## camera streams. The scene that mounts it keeps UI, safety and calibration;
## everything provider-, plugin- or permission-specific lives in the components
## below. The data-flow rule is the RFC's: source -> StreamBinding -> sink,
## every sink receiving the same SensorFrame with its timestamp unchanged.

## The writer session opened (sources are about to start). Scene UI that must
## precede camera start (e.g. releasing a shared camera stream) runs here.
signal session_opened(session_dir: String)
## Sources started; the capture is live.
signal session_started(session_dir: String)
signal session_stopped(final_path: String)
## A provider / sink error surfaced for the scene's status UI.
signal capture_error(message: String)

## Runtime-only display options stripped before writers and samplers see them.
const RUNTIME_DISPLAY_OPTION_KEYS := ["show_hand_skeleton_overlay"]

var pose_sample_hz := 90.0
var camera: CameraSource
var audio: AudioSource
var depth: DepthSource
var hands: HandSource
var pose_sampler: PoseSampler
var body_motion_sampler: BodyMotionSampler
## Sink engines (EgoCaptureComposition.build_io()).
var io: Dictionary = {}
## Current output wiring (EgoCaptureComposition.wire()).
var wiring: Dictionary = {}
var controller: CaptureSessionController
var last_error := ""

var _platform: PlatformRegistry
var _permission_check := Callable()
var _active_options: Dictionary = {}
var _pose_accum := 0.0
var _metrics_pose_loop_iters := 0
var _stage_us_camera_pump := 0
var _stage_us_pose_loop := 0
var _stage_us_depth_pump := 0
var _sink_binding_key: Array = []


## Instantiates the sources under this node. `pico_bridge` may be null.
func setup(hmd_camera: XRCamera3D, left_controller: XRController3D, right_controller: XRController3D, pico_bridge: Object, platform: PlatformRegistry) -> void:
	_platform = platform
	io = EgoCaptureComposition.build_io()
	camera = CameraSource.new()
	camera.name = "CameraSource"
	camera.pico_bridge = pico_bridge
	camera.camera_error.connect(_on_capture_error)
	add_child(camera)
	audio = AudioSource.new()
	audio.name = "AudioSource"
	audio.configure(camera)
	add_child(audio)
	pose_sampler = PoseSampler.new()
	depth = DepthSource.new()
	depth.name = "DepthSource"
	body_motion_sampler = BodyMotionSampler.new()
	add_child(pose_sampler)
	add_child(depth)
	add_child(body_motion_sampler)
	hands = HandSource.new()
	hands.name = "HandSource"
	hands.configure(pose_sampler, body_motion_sampler)
	add_child(hands)
	depth.start_failed.connect(_on_depth_start_failed)
	(io.get("spatialmp4_sink") as SpatialMp4Sink).recorder_error.connect(_on_capture_error)
	(io.get("live_push_sink") as LivePushSink).push_failed.connect(_on_capture_error)
	camera.bind()
	var spool_writer: Object = (io.get("spatialmp4_sink") as SpatialMp4Sink).writer()
	pose_sampler.configure(spool_writer, hmd_camera, left_controller, right_controller, camera.plugin)
	depth.configure(spool_writer, camera.plugin)
	body_motion_sampler.configure(spool_writer, pose_sampler, pico_bridge)
	ensure_bound()


## Mounts the sinks for `output` and rebuilds the lifecycle controller. Not
## allowed while a capture runs. `permission_check` gates every start.
func set_output(output: String, permission_check: Callable = Callable()) -> void:
	if is_recording():
		return
	_permission_check = permission_check
	wiring = EgoCaptureComposition.wire(io, output)
	var frame_sink: Object = wiring.get("frame_sink")
	pose_sampler.set_frame_sink(frame_sink)
	depth.set_frame_sink(frame_sink)
	controller = EgoCaptureComposition.build_controller(wiring, {
		"pose_sampler": pose_sampler,
		"depth_sampler": depth,
		"body_motion_sampler": body_motion_sampler,
		"permission_check": Callable(self, "_check_start_permission"),
	})
	controller.session_started.connect(_on_session_started)
	controller.session_stopped.connect(_on_session_stopped)
	controller.session_error.connect(_on_session_error)
	_connect_camera_to_sinks()


func output() -> String:
	return str(wiring.get("output", EgoCaptureComposition.OUTPUT_LOCAL))


func records_locally() -> bool:
	return bool(wiring.get("local", false))


func streams_to_ingest() -> bool:
	return bool(wiring.get("ingest", false))


## The primary session writer (session paths and session-start clock anchors).
func writer() -> Object:
	return wiring.get("writer")


func live_push_sink() -> LivePushSink:
	return io.get("live_push_sink") as LivePushSink


func upload_sink() -> UploadQueueSink:
	return io.get("upload_sink") as UploadQueueSink


## Binds the provider and sink plugins. Safe every frame: singletons can load
## after the scene. Returns true once the camera provider is bound.
func ensure_bound() -> bool:
	var bound := camera.bind()
	EgoCaptureComposition.bind_plugins(io, _platform, camera.plugin)
	if not wiring.is_empty():
		_connect_camera_to_sinks()
	return bound


func is_recording() -> bool:
	return controller != null and controller.is_session_active()


func supports_live_rgb_rate() -> bool:
	return ensure_bound() and camera.supports_live_rgb_rate()


func set_rgb_rate(fps: int, bitrate_bps: int) -> bool:
	return camera != null and camera.set_rgb_rate(fps, bitrate_bps)


## Options the writers and samplers see: runtime display keys removed and
## streams the bound provider cannot produce turned off.
func effective_options(options: Dictionary) -> Dictionary:
	ensure_bound()
	var recording_options := options.duplicate(true)
	for key in RUNTIME_DISPLAY_OPTION_KEYS:
		recording_options.erase(key)
	return camera.gate_options(recording_options)


## Starts a capture with already-effective options. Returns false when the
## permission check or the writers refused; errors are reported on their own.
func start(options: Dictionary) -> bool:
	if controller == null or is_recording():
		return false
	_active_options = options.duplicate(true)
	# Late plugin binds can land between setup and the first capture start.
	ensure_bound()
	if not controller.request_start(_active_options):
		_active_options = {}
		return false
	return true


func stop() -> void:
	if not is_recording():
		return
	hands.stop_recording()
	camera.stop()
	# Snapshot the body-tracking runtime BEFORE close() so the manifest rewrite
	# records which extension actually fed the samples (PICO BD vs Meta XR_FB).
	var primary: Object = writer()
	if body_motion_sampler.has_method("get_runtime_info") and primary != null and primary.has_method("set_body_tracking_runtime_info"):
		primary.set_body_tracking_runtime_info(body_motion_sampler.get_runtime_info())
	# Controller runs the stop chain (body_motion.stop -> depth.stop) then
	# closes the writers and emits session_stopped.
	controller.request_stop()


func abort(message: String) -> void:
	last_error = message
	push_error(message)
	if is_recording():
		stop()


func active_options() -> Dictionary:
	return _active_options


func option(option_name: String, fallback: Variant = null) -> Variant:
	return _active_options.get(option_name, fallback)


func notify_pause() -> void:
	if controller != null:
		controller.notify_pause()


func notify_resume() -> void:
	if controller != null:
		controller.notify_resume()


## Shared-storage readiness for local recordings. Always true for ingest-only.
func ensure_storage_ready(save_root: String) -> bool:
	if not records_locally():
		return true
	if OS.get_name() == "Android":
		if not ensure_bound():
			push_error("Storage setup requires an Android capture provider.")
			return false
		if not camera.storage_permission_ready(save_root, "Capture waiting for shared-storage permission: %s"):
			return false
		if not camera.ensure_output_directory(save_root):
			push_error("Capture output directory is not writable: %s" % save_root)
			return false
		return true
	var result := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_root))
	if result != OK:
		push_error("Capture output directory could not be created: %s" % save_root)
	return result == OK


## Idle-time storage permission request so the prompt appears before Start.
func prepare_storage(save_root: String) -> void:
	if not records_locally() or OS.get_name() != "Android" or not camera.is_bound():
		return
	if camera.storage_permission_ready(save_root, "Waiting for shared-storage permission for: %s"):
		camera.ensure_output_directory(save_root)


func on_xr_session_begun() -> void:
	depth.on_xr_session_begun(is_recording() and _stream_enabled("record_depth"))


func on_xr_session_stopping() -> void:
	depth.on_xr_session_stopping(is_recording())


## Pumps, the pose loop and pipeline health; call from the owner's _process.
func tick(delta: float) -> void:
	if not is_recording():
		return
	var hand_error := hands.recording_error()
	if not hand_error.is_empty():
		abort(hand_error)
		return
	var camera_error := camera.pipeline_error()
	if not camera_error.is_empty():
		abort(camera_error)
		return
	if not camera.is_bound():
		if ensure_bound() and not camera.configured:
			_start_sources()
	_try_start_sources()
	var t_camera_pump := Time.get_ticks_usec()
	camera.pump(delta)
	_stage_us_camera_pump += Time.get_ticks_usec() - t_camera_pump
	if _stream_enabled("record_depth"):
		var t_depth := Time.get_ticks_usec()
		depth.pump(delta)
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


## One metrics window for the 1 Hz QcMetrics line.
## Returns {pose, depth, body_motion, plugin, muxer, pump, pose_loop_iters,
## stages_us: {camera, pose, depth}}.
func pop_metrics() -> Dictionary:
	var plugin_metrics := camera.pop_plugin_metrics()
	var hand_metrics := hands.pop_metrics()
	for key in hand_metrics.keys():
		plugin_metrics[key] = hand_metrics[key]
	var primary: Object = writer()
	if primary != null and primary.has_method("pop_metrics"):
		var writer_metrics: Dictionary = primary.pop_metrics()
		for key in writer_metrics.keys():
			plugin_metrics["sink_%s" % key] = writer_metrics[key]
	if records_locally() and streams_to_ingest():
		var push_metrics: Dictionary = live_push_sink().writer().pop_metrics()
		for key in push_metrics.keys():
			plugin_metrics["push_%s" % key] = push_metrics[key]
	var pump_metrics := camera.pop_pump_metrics()
	for key in pump_metrics.keys():
		plugin_metrics["pump_%s" % key] = pump_metrics[key]
	var metrics := {
		"pose": pose_sampler.pop_metrics(),
		"depth": depth.pop_metrics(),
		"body_motion": body_motion_sampler.pop_metrics(),
		"plugin": plugin_metrics,
		"muxer": (io.get("spatialmp4_sink") as SpatialMp4Sink).pop_plugin_metrics(),
		"pump": pump_metrics,
		"pose_loop_iters": _metrics_pose_loop_iters,
		"stages_us": {
			"camera": _stage_us_camera_pump,
			"pose": _stage_us_pose_loop,
			"depth": _stage_us_depth_pump,
		},
	}
	_metrics_pose_loop_iters = 0
	_stage_us_camera_pump = 0
	_stage_us_pose_loop = 0
	_stage_us_depth_pump = 0
	return metrics


## Kotlin-direct sink binding for the current output, plus the native hand /
## body writers. Local: the muxer. Ingest: the live push plugin. Both: the live
## push plugin tees the recorder through the process-wide sink registry.
func _connect_camera_to_sinks() -> void:
	var muxer: Object = (io.get("spatialmp4_sink") as SpatialMp4Sink).plugin()
	var live_push := live_push_sink()
	var live: Object = live_push.plugin()
	var local := records_locally()
	var ingest := streams_to_ingest()
	if (local and muxer == null) or (ingest and live == null):
		if ingest and live == null:
			push_warning("LivePushPlugin singleton is not installed; live feed streaming is disabled.")
		return
	if not camera.is_bound():
		return
	var binding_key := [output(), camera.plugin, muxer, live]
	if binding_key == _sink_binding_key:
		return
	_sink_binding_key = binding_key
	if local and ingest:
		live_push.set_recorder_tee(true)
		camera.bind_sink(null, true)
	elif ingest:
		live_push.set_recorder_tee(false)
		camera.bind_sink(live, true)
	else:
		camera.bind_sink(muxer)
	hands.enable_native_writers(muxer if local else null, live if ingest else null)


func _check_start_permission() -> bool:
	return not _permission_check.is_valid() or bool(_permission_check.call())


func _on_session_started(session_dir: String) -> void:
	if pose_sampler.has_method("on_session_started"):
		pose_sampler.on_session_started(session_dir)
	if body_motion_sampler.has_method("on_session_started"):
		body_motion_sampler.on_session_started(session_dir)
	_pose_accum = 0.0
	last_error = ""
	camera.reset_session()
	audio.reset_session()
	hands.reset_session()
	session_opened.emit(session_dir)
	_start_sources()
	if is_recording():
		session_started.emit(session_dir)


func _on_session_stopped(final_path: String) -> void:
	if pose_sampler.has_method("on_session_stopped"):
		pose_sampler.on_session_stopped()
	if body_motion_sampler.has_method("on_session_stopped"):
		body_motion_sampler.on_session_stopped()
	_active_options = {}
	camera.reset_session()
	audio.reset_session()
	session_stopped.emit(final_path)


func _on_session_error(message: String) -> void:
	push_error(message)


func _on_capture_error(message: String) -> void:
	last_error = message
	capture_error.emit(message)


func _on_depth_start_failed(reason: String) -> void:
	if is_recording() and _stream_enabled("record_depth"):
		abort("Environment depth start failed: %s" % reason)


## Configures the provider and requests its system permissions, then starts
## every source as soon as they are ready.
func _start_sources() -> void:
	if not camera.is_bound():
		print("Capture provider start skipped: singleton is not bound")
		return
	if not camera.configure_session(writer(), _active_options, AudioSource.session_config(_active_options)):
		abort("%s configure failed" % camera.label())
		return
	camera.request_permission()
	# RECORD_AUDIO is a runtime permission too. Request it up front; if the
	# user denies or ignores it, _try_start_sources degrades to video-only.
	audio.request_permission(bool(option("record_audio", false)))
	print("%s requested camera permissions" % camera.label())
	_try_start_sources()


func _try_start_sources() -> void:
	if not camera.awaiting_start():
		return
	if not camera.permission_ready():
		return
	if not audio.ready_to_start(bool(option("record_audio", false))):
		return
	# Environment depth may have its own Android runtime permission. Start the
	# OpenXR provider only after the capture provider confirms all permissions
	# required by this session, otherwise the runtime can reject the provider
	# and foreground its permission/setup UI while recording is already active.
	if _stream_enabled("record_depth"):
		if depth.start_when_xr_ready() and not is_recording():
			return
	if not camera.start(_active_options):
		abort("%s camera start failed" % camera.label())
		return
	var record_hands_locally := records_locally() and _stream_enabled("record_hand_data")
	if not hands.start_recording(record_hands_locally, camera.xr_time_to_godot_ticks_offset_ns()):
		abort("Native 60 Hz hand recorder failed to start")


func _stream_enabled(option_name: String) -> bool:
	return bool(option(option_name, true))


func _has_pose_streams_enabled() -> bool:
	return _stream_enabled("record_head_pose") or _stream_enabled("record_controller_pose") or _stream_enabled("record_hand_data")


func _has_body_motion_streams_enabled() -> bool:
	return _stream_enabled("record_body_tracking") or _stream_enabled("record_motion_trackers")
