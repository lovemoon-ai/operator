class_name EgoCaptureComposition
extends RefCounted
## Composition root for capture: interprets an output selection into mounted
## sinks, a canonical-frame fanout and a capture lifecycle controller.
##
## The output (`capture_options.capture_output`) is decided by the user in
## Ego mode and by the host declaration in a host session:
##   local  — SpatialMp4Sink (local SpatialMP4 recording; uploads may follow)
##   ingest — LivePushSink to the session-injected endpoint (OLCP media_up)
##   both   — one capture feeding both; the local recording is primary
## Sources are identical for every output; only the wiring differs
## (CapturePipeline instantiates and drives them).

const SessionSpoolWriterScript := preload("res://scripts/core/capture/session_spool_writer.gd")

const OUTPUT_LOCAL := "local"
const OUTPUT_INGEST := "ingest"
const OUTPUT_BOTH := "both"
const OUTPUTS := [OUTPUT_LOCAL, OUTPUT_INGEST, OUTPUT_BOTH]


static func normalize_output(value: Variant) -> String:
	var output := str(value).strip_edges().to_lower()
	return output if OUTPUTS.has(output) else OUTPUT_LOCAL


static func records_locally(output: String) -> bool:
	return output != OUTPUT_INGEST


static func streams_to_ingest(output: String) -> bool:
	return output != OUTPUT_LOCAL


## Phase 1: every sink engine a capture can mount. The output selection only
## decides which of them wire() connects, so switching outputs never rebuilds
## plugin bindings or the upload queue.
## Returns {spatialmp4_sink, live_push_sink, upload_sink}.
static func build_io() -> Dictionary:
	return {
		"spatialmp4_sink": SpatialMp4Sink.new(SessionSpoolWriterScript.new()),
		"live_push_sink": LivePushSink.new(),
		# EgoUploader drains user://ego_upload_queue.json. The sink owns the
		# uploader instance (queue file / TUS behavior / signals); the scene
		# keeps node lifecycle + UI glue.
		"upload_sink": UploadQueueSink.new(),
	}


## Binds platform sink plugins (muxer, live push) and the camera provider to
## the engines. Idempotent: plugin singletons may register late.
static func bind_plugins(io: Dictionary, platform: PlatformRegistry, camera_plugin: Object) -> void:
	var spatialmp4 := io.get("spatialmp4_sink") as SpatialMp4Sink
	var live_push := io.get("live_push_sink") as LivePushSink
	if spatialmp4.plugin() == null:
		spatialmp4.bind_plugin(platform.muxer_plugin())
	if live_push.plugin() == null:
		live_push.bind_plugin(platform.live_server_plugin())
	if camera_plugin == null:
		return
	# Stage 2b split every write* RPC to the muxer plugin, and the spool
	# writer also needs the provider for device identity. Missing either
	# hand-off silently no-ops every pose / depth / hand / input frame.
	for writer_v in [spatialmp4.writer(), live_push.writer()]:
		var writer: Object = writer_v
		if writer != null and writer.has_method("set_android_plugin"):
			writer.set_android_plugin(camera_plugin)


## Phase 2: wiring for one output selection.
## Returns {output, local, ingest, frame_sink (StreamBinding), writer (the
## primary session writer: session paths and clock anchors), writer_adapter}.
static func wire(io: Dictionary, output: String) -> Dictionary:
	var normalized := normalize_output(output)
	var binding := StreamBinding.new()
	var adapters: Array = []
	var primary_writer: Object = null
	if records_locally(normalized):
		var spatialmp4 := io.get("spatialmp4_sink") as SpatialMp4Sink
		binding.add_sink(spatialmp4)
		adapters.append(SpoolWriterAdapter.new(spatialmp4.writer()))
		primary_writer = spatialmp4.writer()
	if streams_to_ingest(normalized):
		var live_push := io.get("live_push_sink") as LivePushSink
		binding.add_sink(live_push)
		adapters.append(LiveWriterAdapter.new(live_push.writer()))
		if primary_writer == null:
			primary_writer = live_push.writer()
	var writer_adapter: CaptureWriterAdapter = adapters[0] if adapters.size() == 1 else WriterFanoutAdapter.new(adapters)
	return {
		"output": normalized,
		"local": records_locally(normalized),
		"ingest": streams_to_ingest(normalized),
		"frame_sink": binding,
		"writer": primary_writer,
		"writer_adapter": writer_adapter,
	}


## Phase 3: capture lifecycle controller over the wiring.
## deps:
##   pose_sampler / depth_sampler / body_motion_sampler: configured Nodes
##   permission_check: Callable -> bool (storage / calibration readiness)
static func build_controller(wiring: Dictionary, deps: Dictionary) -> CaptureSessionController:
	# Stop order, preserved: body_motion.stop -> depth.stop -> writer.close
	# (inside the controller). The ingest result channel stays connected so
	# algorithm results keep arriving after the push stops.
	var controller := CaptureSessionController.new()
	controller.configure({
		"writer_adapter": wiring.get("writer_adapter"),
		"permission_check": deps.get("permission_check", Callable()),
		"option_samplers": [deps.get("pose_sampler"), deps.get("body_motion_sampler")],
		"stop_chain": [deps.get("body_motion_sampler"), deps.get("depth_sampler")],
		"live_mode": not bool(wiring.get("local", true)),
	})
	return controller
