extends Node
## Host composition for capture streams. Loaded by path by the host mode, and
## only in presets that ship the capture stack: Teleop-only presets exclude it
## and therefore never advertise `capture_streams_v1`.
##
## Interprets the host declaration's `capture_streams` envelope:
##   StreamPlanner   declaration × local limits × PermissionTable × advertised
##                   capabilities -> what runs, reported as StreamsStatus
##   CapturePipeline CameraSource & co. -> LivePushSink over the session's own
##                   media_up (peer address + the session-owned `media` block),
##                   plus a local SpatialMp4Sink recording when the host
##                   orchestrates a `record` task
##   local tasks     `record` / `upload` to an EndpointRegistry endpoint only
## The user confirms a host's camera declaration once (remembered per host
## address and declaration hash), sees a persistent indicator while media
## flows, and can revoke it with one tap. `required` never disconnects.

const HostCapturePromptScript := preload("res://scripts/ui/host_capture_prompt.gd")
const RESTART_DELAY_SECONDS := 0.3
const ADVERTISE_RETRY_SECONDS := 1.0
const DEFAULT_SAVE_ROOT := "/sdcard/DCIM/SpatialMP4"
const OUTPUT_INGEST := "ingest"
const OUTPUT_BOTH := "both"

var _session: HostSession
var _pipeline: CapturePipeline
var _planner := StreamPlanner.new()
var _prompt: HostCapturePrompt
var _indicator: HostCapturePrompt
var _uploader: Node = null
## Returns the live input source ("hands" / "controllers").
var _interaction_mode := Callable()
## Stream names this APK can produce on this device.
var _advertised_streams: Array = []
var _config: Dictionary = {}
## Session-owned media transport from the descriptor ({} when not served).
var _media: Dictionary = {}
var _hash := ""
var _host := ""
var _record_wanted := true
var _capture_failed := false
## Android is asking for shared storage (its settings page is in front); the
## start is retried when the app resumes, and a refusal only denies `record`.
var _awaiting_storage := false
var _storage_denied := false
## Upload endpoint for the running local recording, resolved at start so the
## finished file is still handed over after the host has gone.
var _upload_target: Dictionary = {}
var _advertise_retry_s := 0.0
var _starting := false
var _running_signature := ""
## Bumped by every plan that starts or stops capture. A restart waiting out
## RESTART_DELAY_SECONDS carries the epoch it was planned in, so a newer plan
## (or a stop) supersedes it instead of starting stale parameters.
var _plan_epoch := 0
## Latest planned rgb rate/bitrate. With a provider that changes them in place
## the capture runs at the envelope ceiling and these are delivered live, so a
## StreamsControl rate change never restarts camera and encoder.
var _rate_updates: Dictionary = {}
var _live_rate := false
## What the provider was last told; re-plans that change nothing send nothing.
var _applied_rate: Dictionary = {}
## local task kind -> {state, reason?}
var _task_status: Dictionary = {}


## Builds the capture pipeline and UI. Returns the Hello capabilities this
## composition can honor ([] when the device has no capture provider or no
## live push plugin).
func setup(session: HostSession, origin: XROrigin3D, head: XRCamera3D, left: XRController3D, right: XRController3D, pico_bridge: Object, interaction_mode: Callable) -> Array:
	_session = session
	_interaction_mode = interaction_mode
	_pipeline = CapturePipeline.new()
	_pipeline.name = "HostCapturePipeline"
	add_child(_pipeline)
	_pipeline.setup(head, left, right, pico_bridge, PlatformRegistry.shared() as PlatformRegistry)
	_pipeline.session_stopped.connect(_on_capture_stopped)
	_pipeline.capture_error.connect(_on_capture_error)
	_prompt = HostCapturePromptScript.new(false)
	_prompt.name = "HostCapturePrompt"
	_prompt.head = head
	_prompt.decided.connect(_on_prompt_decided)
	origin.add_child(_prompt)
	_indicator = HostCapturePromptScript.new(true)
	_indicator.name = "HostCaptureIndicator"
	_indicator.head = head
	_indicator.revoke_requested.connect(_on_revoke_requested)
	origin.add_child(_indicator)
	# Depth starts only inside a running OpenXR session.
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface != null:
		xr_interface.session_begun.connect(_pipeline.on_xr_session_begun)
		xr_interface.session_stopping.connect(_pipeline.on_xr_session_stopping)
		if xr_interface.is_initialized():
			_pipeline.on_xr_session_begun()
	return _advertise()


func _process(delta: float) -> void:
	if _pipeline == null:
		return
	_pipeline.tick(delta)
	if _advertised_streams.is_empty():
		_retry_advertise(delta)


func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_RESUMED or not _awaiting_storage:
		return
	_awaiting_storage = false
	_storage_denied = not _pipeline.camera.has_storage_permission()
	if _storage_denied:
		push_warning("[HostCapture] shared storage refused; the record task is denied")
	if not _config.is_empty():
		_replan()


## A provider plugin can bind after setup; advertise it for the next Hello.
func _retry_advertise(delta: float) -> void:
	_advertise_retry_s -= delta
	if _advertise_retry_s > 0.0:
		return
	_advertise_retry_s = ADVERTISE_RETRY_SECONDS
	var capabilities := _advertise()
	if not capabilities.is_empty():
		_session.set_extra_capabilities(capabilities)
		print("[HostCapture] capture provider bound late; advertising %s" % str(capabilities))


func _advertise() -> Array:
	_advertised_streams = []
	if not _pipeline.ensure_bound() or _pipeline.live_push_sink().plugin() == null:
		return []
	_advertised_streams.append(StreamPlanner.RGB_STREAM)
	if _pipeline.camera.supports_depth():
		_advertised_streams.append("depth.u16")
	for pose_stream in ["head_pose.json", "controller_pose.json", "controller_input.json", "hand_joints.json"]:
		_advertised_streams.append(pose_stream)
	var capabilities: Array = [StreamsContract.CAPABILITY]
	for stream_name_v in _advertised_streams:
		capabilities.append(StreamsContract.stream_capability(str(stream_name_v)))
	return capabilities


## A (re)delivered descriptor after Hello. No `capture_streams` stops capture.
func on_descriptor(descriptor: Dictionary) -> void:
	var parsed := StreamsContract.parse_capture_streams(descriptor.get("capture_streams", null))
	var errors: Array = parsed.get("errors", [])
	if not errors.is_empty():
		push_warning("[HostCapture] ignoring invalid capture_streams: %s" % str(errors))
	var config: Dictionary = parsed.get("config", {})
	if config.is_empty():
		_teardown()
		return
	var host := _session.host()
	var declaration_hash := StreamsContract.declaration_hash(config)
	if host != _host or declaration_hash != _hash:
		_planner.clear()
		_record_wanted = true
		_capture_failed = false
		_awaiting_storage = false
		_storage_denied = false
	_config = config
	_media = StreamsContract.parse_media(descriptor.get("media", null))
	_host = host
	_hash = declaration_hash
	print("[HostCapture] %s declares %d stream(s), %d local task(s)" % [
		_host, (_config.get("streams", []) as Array).size(), (_config.get("local_tasks", []) as Array).size()])
	_replan()


func on_host_disconnected() -> void:
	_teardown()


func on_streams_control(control: Dictionary) -> void:
	if _config.is_empty():
		return
	_planner.apply_control(control)
	# Shape is already validated, but a malformed entry must never abort the
	# handler: the plan below is what tells the host what actually runs.
	var tasks_v: Variant = control.get("local_tasks", {})
	if tasks_v is Dictionary:
		var record_v: Variant = (tasks_v as Dictionary).get("record", {})
		if record_v is Dictionary and (record_v as Dictionary).has("running"):
			_record_wanted = bool((record_v as Dictionary).get("running"))
	_replan()


func _teardown() -> void:
	_config = {}
	_media = {}
	_hash = ""
	_host = ""
	_task_status = {}
	_awaiting_storage = false
	_planner.clear()
	_prompt.dismiss()
	_indicator.dismiss()
	_stop_capture()


func _replan() -> void:
	var decisions := PermissionTable.decisions(_host, _hash, _categories())
	# Without a session media transport nothing can be carried: every stream
	# is unsupported for this session.
	var advertised: Array = _advertised_streams.duplicate() if not _media.is_empty() else []
	if _capture_failed:
		advertised.erase(StreamPlanner.RGB_STREAM)
	var plan := _planner.plan_host(_config, advertised, decisions, _current_interaction_mode())
	_plan_local_tasks(decisions)
	_apply(plan)
	_send_status()
	_refresh_ui()


## Categories a declaration touches (xr_state is always allowed on connect).
func _categories() -> Array:
	var categories: Array = [PermissionTable.CATEGORY_XR_STATE]
	for entry_v in _config.get("streams", []):
		var category := StreamPlanner.category_for_stream(str((entry_v as Dictionary).get("name", "")))
		if not categories.has(category):
			categories.append(category)
	if _declared_task("record").size() > 0 and not categories.has(PermissionTable.CATEGORY_CAMERA):
		categories.append(PermissionTable.CATEGORY_CAMERA)
	return categories


func _declared_task(kind: String) -> Dictionary:
	for task_v in _config.get("local_tasks", []):
		if str((task_v as Dictionary).get("kind", "")) == kind:
			return task_v as Dictionary
	return {}


## Local tasks ride on the camera grant: recording uses the capture the user
## allowed, and uploads only reach an endpoint verified on this headset.
func _plan_local_tasks(decisions: Dictionary) -> void:
	var camera := str(decisions.get(PermissionTable.CATEGORY_CAMERA, PermissionTable.DECISION_ASK))
	_task_status = {}
	if not _declared_task("record").is_empty():
		_task_status["record"] = _task_state_for(camera, _record_running())
		if _storage_denied and camera == PermissionTable.DECISION_ALLOW:
			_task_status["record"] = {"state": "denied", "reason": StreamPlanner.REASON_PERMISSION_DENIED}
	var upload := _declared_task("upload")
	if not upload.is_empty():
		var endpoint := EndpointRegistry.shared().resolve(str(upload.get("endpoint_ref", "")), EndpointRegistry.KIND_UPLOAD)
		if endpoint.is_empty():
			_task_status["upload"] = {"state": "denied", "reason": StreamPlanner.REASON_UNKNOWN_ENDPOINT}
		else:
			_task_status["upload"] = _task_state_for(camera, _uploader != null and _upload_pending())


func _task_state_for(decision: String, running: bool) -> Dictionary:
	match decision:
		PermissionTable.DECISION_ASK:
			return {"state": "pending"}
		PermissionTable.DECISION_DENY:
			return {"state": "denied", "reason": StreamPlanner.REASON_PERMISSION_DENIED}
		PermissionTable.DECISION_REVOKED:
			return {"state": "denied", "reason": StreamPlanner.REASON_REVOKED}
	return {"state": "running" if running else "idle"}


## Recording is a local task the host must declare; without a `record` task the
## session only pushes media (no shared storage, no local file).
func _record_running() -> bool:
	return _record_wanted and not _storage_denied and not _declared_task("record").is_empty() and _planner.media_up_running()


func _upload_pending() -> bool:
	return _uploader != null and _uploader.has_method("pending_jobs") and not (_uploader.call("pending_jobs") as Array).is_empty()


## Starts, restarts or stops the capture to match the plan.
func _apply(plan: Dictionary) -> void:
	if not bool(plan.get("media_up", false)) or _media.is_empty():
		_stop_capture()
		return
	var output := OUTPUT_BOTH if _record_running() else OUTPUT_INGEST
	var updates: Dictionary = plan.get("updates", {})
	_live_rate = _pipeline.supports_live_rgb_rate()
	_rate_updates = {"rgb_fps": updates.get("rgb_fps", 0), "rgb_bitrate": updates.get("rgb_bitrate", 0)}
	var options := _capture_options(updates, output, _live_rate)
	var signature := JSON.stringify([output, options], "", true)
	if signature == _running_signature and (_pipeline.is_recording() or _starting):
		# Same capture. A rate/bitrate-only change is delivered in place.
		if _live_rate and _pipeline.is_recording():
			_apply_live_rate()
		return
	if _pipeline.is_recording():
		_stop_capture()
		# Give the camera provider a moment to release before reconfiguring.
		_starting = true
		var epoch := _next_epoch()
		get_tree().create_timer(RESTART_DELAY_SECONDS).timeout.connect(
			_start_capture.bind(output, options, signature, epoch))
		return
	_start_capture(output, options, signature, _next_epoch())


func _next_epoch() -> int:
	_plan_epoch += 1
	return _plan_epoch


func _start_capture(output: String, options: Dictionary, signature: String, epoch: int) -> void:
	if epoch != _plan_epoch:
		return # A newer plan or a stop superseded this restart.
	_starting = false
	if _config.is_empty() or _pipeline.is_recording() or _awaiting_storage:
		return
	_pipeline.set_output(output, Callable(self, "_storage_ready"))
	if output == OUTPUT_BOTH and not _storage_ready():
		_running_signature = ""
		if _pipeline.camera.storage_request_opened:
			# Android shows its shared-storage page: re-planned on resume.
			_awaiting_storage = true
		else:
			# Nothing was put in front of the user (output directory not
			# writable, no activity), so no resume will come: deny `record`
			# for this session and keep streaming.
			push_warning("[HostCapture] local recording storage unavailable; the record task is denied")
			_storage_denied = true
			call_deferred("_replan")
		_refresh_ui()
		return
	# media_up is the session's own channel: the connected peer's address and
	# the session-issued token. Nothing about it is declared by the host app.
	_pipeline.live_push_sink().set_target(_host, int(_media.get("push_port", 0)), str(_media.get("auth_token", "")))
	_running_signature = signature
	if _uploader != null:
		_uploader.call("pause")
	_applied_rate = {}
	_upload_target = _upload_endpoint() if output == OUTPUT_BOTH else {}
	if _pipeline.start(_pipeline.effective_options(options)):
		if _live_rate:
			_apply_live_rate()
	else:
		_running_signature = ""
		push_warning("[HostCapture] capture did not start")
		# Report what actually runs: the host must not keep seeing `active`
		# for a camera that never started.
		_capture_failed = true
		call_deferred("_replan")
	_refresh_ui()


func _stop_capture() -> void:
	_running_signature = ""
	_plan_epoch += 1
	_starting = false
	if _pipeline != null and _pipeline.is_recording():
		_pipeline.stop()


## Delivers the planned rgb rate/bitrate out of a capture running at the
## ceiling. The planned rate never exceeds the ceiling, so a refusal only means
## the provider lost its encoder; the capture keeps running at the ceiling.
func _apply_live_rate() -> void:
	if _rate_updates == _applied_rate:
		return
	var fps := int(_rate_updates.get("rgb_fps", 0))
	if fps > 0 and not _pipeline.set_rgb_rate(fps, int(_rate_updates.get("rgb_bitrate", 0))):
		push_warning("[HostCapture] provider refused a live rgb rate of %d fps" % fps)
		return # Retried on the next plan.
	_applied_rate = _rate_updates.duplicate()


func _capture_options(updates: Dictionary, output: String, live_rate := false) -> Dictionary:
	var options := {
		"capture_output": output,
		"interaction_mode": _current_interaction_mode(),
		"stereo_rgb": true,
		"record_audio": false,
		"record_body_tracking": false,
		"record_motion_trackers": false,
		"max_motion_trackers": 0,
		"rgb_codec": "hevc",
		"rgb_width": 0,
		"rgb_height": 0,
		"rgb_resolution": "",
		"rgb_extrinsics_space": "head",
		"save_root": DEFAULT_SAVE_ROOT,
		"upload_on_finalize": false,
	}
	# The host session never changes the play space: record in whatever
	# reference space the scene already runs.
	var export_space := OpenXRExportSpace.DEFAULT
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface != null and xr_interface.is_initialized():
		var active_space := OpenXRExportSpace.from_play_area_mode(xr_interface.get_play_area_mode())
		if not active_space.is_empty():
			export_space = active_space
	options["export_coordinate_space"] = export_space
	options["export_coordinate_space_id"] = OpenXRExportSpace.coordinate_space_id(export_space)
	options.merge(updates, true)
	if live_rate:
		# Capture at the granted ceiling; the delivered rate is set in place.
		options.merge(_planner.rgb_capture_ceiling(), true)
	return options


func _storage_ready() -> bool:
	return _pipeline.ensure_storage_ready(DEFAULT_SAVE_ROOT)


func _current_interaction_mode() -> String:
	if _interaction_mode.is_valid():
		return str(_interaction_mode.call())
	return "controllers"


func _send_status() -> void:
	if _session == null or _config.is_empty():
		return
	_session.send_streams_status(_planner.status(_task_status))


func _refresh_ui() -> void:
	if _config.is_empty():
		_prompt.dismiss()
		_indicator.dismiss()
		return
	var decisions := PermissionTable.decisions(_host, _hash, _categories())
	var asking := false
	for decision_v in decisions.values():
		asking = asking or str(decision_v) == PermissionTable.DECISION_ASK
	if asking:
		_prompt.show_request(_host, _request_lines())
	else:
		_prompt.dismiss()
	if _pipeline.is_recording() or _starting:
		var text := tr("UI_HOST_CAPTURE_STREAMING") % _host
		if _pipeline.records_locally():
			text += " · %s" % tr("UI_HOST_CAPTURE_RECORDING")
		_indicator.show_indicator(text)
	else:
		_indicator.dismiss()


## One human-readable line per declared stream and local task.
func _request_lines() -> Array:
	var lines: Array = []
	for entry_v in _config.get("streams", []):
		var entry := entry_v as Dictionary
		var parts := PackedStringArray([str(entry.get("name", ""))])
		if entry.has("max_hz"):
			parts.append(tr("UI_HOST_CAPTURE_UP_TO_HZ") % str(entry.get("max_hz")))
		if entry.has("eye"):
			parts.append(str(entry.get("eye")))
		if bool(entry.get("required", false)):
			parts.append(tr("UI_HOST_CAPTURE_REQUIRED"))
		lines.append("• " + "  ·  ".join(parts))
	if not _declared_task("record").is_empty():
		lines.append("• " + tr("UI_HOST_CAPTURE_TASK_RECORD"))
	var upload := _declared_task("upload")
	if not upload.is_empty():
		lines.append("• " + tr("UI_HOST_CAPTURE_TASK_UPLOAD") % str(upload.get("endpoint_ref", "")))
	return lines


func _on_prompt_decided(allowed: bool) -> void:
	if _config.is_empty():
		return
	print("[HostCapture] user %s the capture declaration of %s" % ["allowed" if allowed else "denied", _host])
	PermissionTable.remember(_host, _hash, _categories(), allowed)
	_replan()


func _on_revoke_requested() -> void:
	if _config.is_empty():
		return
	print("[HostCapture] user revoked capture for %s" % _host)
	PermissionTable.revoke(_host, _hash)
	_upload_target = {}
	_replan()


## A capture ended: hand a finished local recording to the host's upload task.
func _on_capture_stopped(final_path: String) -> void:
	# A stop we did not ask for means the provider failed (system permission,
	# camera start): report the narrowed capability instead of retrying.
	# Stops we asked for are already being handled by their caller, so only
	# the unexpected case re-plans, deferred out of the stop signal.
	var unexpected := not _running_signature.is_empty() and not _starting
	if unexpected:
		_capture_failed = true
		_running_signature = ""
	if _pipeline.records_locally() and not final_path.is_empty():
		_enqueue_upload()
	# Uploads pause while a capture runs; this one has ended.
	if _uploader != null:
		_uploader.call("resume")
	if unexpected and not _config.is_empty():
		call_deferred("_replan")


func _on_capture_error(message: String) -> void:
	push_warning("[HostCapture] %s" % message)


## The declared upload task's verified endpoint ({} when there is none).
func _upload_endpoint() -> Dictionary:
	var upload := _declared_task("upload")
	if upload.is_empty() or str((_task_status.get("upload", {}) as Dictionary).get("state", "")) == "denied":
		return {}
	var endpoint := EndpointRegistry.shared().resolve(str(upload.get("endpoint_ref", "")), EndpointRegistry.KIND_UPLOAD)
	if endpoint.is_empty():
		return {}
	endpoint = endpoint.duplicate()
	endpoint["endpoint_ref"] = str(upload.get("endpoint_ref", ""))
	return endpoint


func _enqueue_upload() -> void:
	var endpoint := _upload_target
	_upload_target = {}
	if endpoint.is_empty():
		return
	var writer: Object = _pipeline.writer()
	if writer == null or not writer.has_method("get_output_mp4_path_absolute"):
		return
	if _uploader == null:
		_uploader = _pipeline.upload_sink().uploader()
		_uploader.name = "HostTaskUploader"
		add_child(_uploader)
	var queued := _pipeline.upload_sink().enqueue_session(
		str(writer.get_session_dir_absolute()),
		str(writer.get_output_mp4_path_absolute()),
		{
			"upload_url": str(endpoint.get("url", "")),
			"upload_token": str(endpoint.get("token", "")),
			"upload_on_finalize": true,
			"keep_local_after_upload": true,
		})
	if queued:
		print("[HostCapture] recording queued for upload to %s" % str(endpoint.get("endpoint_ref", "")))
