class_name CameraSource
extends Node
## Capability layer (components/sources): the RGB camera provider.
##
## Owns the Android capture-provider plugin binding, the system permissions
## that plugin exposes (camera, and the shared-storage permission local
## recordings need), per-session configuration, and the Quest byte-buffer vs
## PICO native (XR_PICO_camera_image) start / stop / pump paths. Encoded RGB
## leaves Kotlin-direct through the SpatialDataSink contract to whichever sink
## the composition bound; this component never picks a destination. The
## plugins own every timestamp (claw/architecture/wire-protocol.md,
## "Headset timebase").

signal camera_error(message: String)

const CaptureProviderRegistryScript := preload("res://scripts/xr/capture_provider_registry.gd")
const DEFAULT_RGB_BITRATE := 24000000
const DEFAULT_RGB_FPS := 30
const DEFAULT_RGB_CODEC := "hevc"
const DEFAULT_MAX_MOTION_TRACKERS := 2
# Warn on the first submit failure, then again at most every
# PICO_CAMERA_FAIL_WARN_EVERY failures or PICO_CAMERA_FAIL_WARN_INTERVAL_US,
# whichever comes first -- enough to stay visible in logcat without spamming
# one line per dropped frame.
const PICO_CAMERA_FAIL_WARN_EVERY := 100
const PICO_CAMERA_FAIL_WARN_INTERVAL_US := 5_000_000

## The provider plugin singleton (null until bound).
var plugin: Object
## PICO OpenXR extension bridge, injected by the platform layer (may be null).
var pico_bridge: Object
var provider_name := ""
var configured := false
var start_attempted := false
var last_error := ""

var _bind_warned := false
var _permission_wait_logged := false
var _pico_camera_image_started := false
var _pico_native_pipeline_started := false
var _pico_native_metrics_accum: Dictionary = {}
# Kotlin-direct RGB pump state: the pico_openxr bridge holds the capture
# plugin and submits frames in C++ (see pump()).
var _pico_camera_sink_bound := false
var _pico_camera_pump_warned := false
# How often the pump polls the native bridge for new camera frames. Each call
# moves at most one eye, so stereo capture polls at twice the configured fps:
# one left + one right transfer per camera-frame interval without bunching both
# large RGBA copies into the same render tick.
var _pico_camera_poll_interval_s := 0.5 / DEFAULT_RGB_FPS
var _pico_camera_frame_accum_s := 0.0
# Per-metrics-window pump counters (reset by pop_metrics) plus a
# session-lifetime failure total used to rate-limit the submit warning.
var _pico_camera_submit_ok_left := 0
var _pico_camera_submit_ok_right := 0
var _pico_camera_submit_fail_left := 0
var _pico_camera_submit_fail_right := 0
var _pico_camera_frames_skipped := 0
var _pico_camera_acquire_us := 0
var _pico_camera_submit_us := 0
var _pico_camera_submit_fail_session := 0
var _pico_camera_fail_count_at_last_warn := 0
var _pico_camera_fail_warn_ticks_us := 0
var _view_pose_log_count := 0


## Binds the best-scoring capture provider. Returns true when a provider is
## (now or already) bound. Safe to call every frame while the singleton loads.
func bind() -> bool:
	if plugin != null:
		return true
	# Quest and PICO both export providers; select the one with the best
	# runtime device score so a PICO APK does not bind QuestCapturePlugin.
	plugin = CaptureProviderRegistryScript.bind()
	if plugin == null:
		if not _bind_warned:
			_bind_warned = true
			print("Capture provider singleton is not installed yet; RGB capture is waiting.")
			push_warning("Capture provider singleton is not installed; RGB capture is disabled.")
		return false
	provider_name = CaptureProviderRegistryScript.provider_name(plugin)
	plugin.connect("camera_ready", Callable(self, "_on_camera_ready"))
	plugin.connect("camera_frame_saved", Callable(self, "_on_camera_frame_saved"))
	plugin.connect("camera_error", Callable(self, "_on_camera_error"))
	_bind_warned = false
	print("Capture provider singleton bound: %s" % label())
	return true


func is_bound() -> bool:
	return plugin != null


func label() -> String:
	return "%sCapturePlugin" % provider_name.capitalize() if not provider_name.is_empty() else "CaptureProvider"


func uses_pico_bridge() -> bool:
	return CaptureProviderRegistryScript.provider_uses_pico_bridge(provider_name)


func supports_depth() -> bool:
	return plugin != null and CaptureProviderRegistryScript.supports_depth(plugin)


## Whether the provider can change a running capture's delivered RGB rate and
## bitrate in place (set_rgb_rate) instead of restarting camera and encoder.
func supports_live_rgb_rate() -> bool:
	return plugin != null and bool(plugin.call("supportsLiveRgbRate"))


## Delivers `fps` frames per second (at most the capture rate) at `bitrate_bps`
## without a restart. False when the provider cannot.
func set_rgb_rate(fps: int, bitrate_bps: int) -> bool:
	return plugin != null and bool(plugin.call("setRgbRate", fps, bitrate_bps))


func supports_motion_trackers() -> bool:
	return plugin != null and CaptureProviderRegistryScript.supports_motion_trackers(plugin)


func supports_audio() -> bool:
	return plugin != null and CaptureProviderRegistryScript.provider_supports_audio_capture(provider_name)


## Provider-capability gating of requested capture options. Vendor-name
## decisions stay behind CaptureProviderRegistry helpers.
func gate_options(options: Dictionary) -> Dictionary:
	var effective := options.duplicate(true)
	if plugin == null:
		return effective
	if not provider_name.is_empty():
		effective["capture_provider"] = provider_name
	if not CaptureProviderRegistryScript.supports_depth(plugin):
		effective["record_depth"] = false
	if not CaptureProviderRegistryScript.supports_body_motion(plugin):
		effective["record_body_tracking"] = false
		effective["record_motion_trackers"] = false
	# Motion trackers (PICO XR_PICO_motion_tracking) are PICO-only even when
	# the provider reports body-motion support: Quest's body data comes purely
	# from Meta's XR_FB_body_tracking + XR_META_body_tracking_full_body.
	if not CaptureProviderRegistryScript.supports_motion_trackers(plugin):
		effective["record_motion_trackers"] = false
	if uses_pico_bridge() and bool(effective.get("record_body_tracking", false)):
		# PICO full-body capture and independent tracker capture are separate
		# runtime modes. Keep the manifest aligned with the sampler, which must
		# not request independent trackers while body tracking is active.
		effective["record_motion_trackers"] = false
	if not CaptureProviderRegistryScript.provider_supports_audio_capture(provider_name):
		effective["record_audio"] = false
	return effective


## Kotlin-direct sink binding: RGB CSD + packets bypass GDScript on the
## per-frame path. `sink_plugin` null selects the process-wide sink registry
## (used when the live push plugin tees the recorder).
func bind_sink(sink_plugin: Object, reset_first: bool = false) -> void:
	if plugin == null:
		return
	if reset_first:
		plugin.call("bindMuxer", null)
	var bound: Variant = plugin.call("bindMuxer", sink_plugin)
	if not bool(bound):
		push_warning("%s.bindMuxer(%s) returned false; registry fallback will be used if available" % [label(), sink_plugin])


func xr_time_to_godot_ticks_offset_ns() -> int:
	return int(plugin.call("getXrTimeToGodotTicksOffsetNs")) if plugin != null else 0


func platform_version() -> int:
	return int(plugin.call("getCapturePlatformVersion")) if plugin != null else 0


# --- System permissions -----------------------------------------------------

func request_permission() -> void:
	if plugin != null:
		plugin.call("requestCameraPermission")


## True once the Android CAMERA permission is granted; re-requests otherwise.
func permission_ready() -> bool:
	if plugin == null:
		return false
	if bool(plugin.call("hasCameraPermission")):
		return true
	if not _permission_wait_logged:
		_permission_wait_logged = true
		print("%s waiting for camera permission" % label())
	plugin.call("requestCameraPermission")
	return false


## Shared-storage permission for local recordings. Requests it (and logs
## `log_format % save_root`) while it is missing.
func storage_permission_ready(save_root: String, log_format: String) -> bool:
	if plugin == null:
		return false
	if bool(plugin.call("hasStoragePermission")):
		return true
	plugin.call("requestStoragePermission")
	print(log_format % save_root)
	return false


func ensure_output_directory(save_root: String) -> bool:
	return plugin != null and bool(plugin.call("ensureOutputDirectory", save_root))


# --- Session lifecycle -------------------------------------------------------

func reset_session() -> void:
	configured = false
	start_attempted = false
	_permission_wait_logged = false
	_pico_camera_image_started = false
	_pico_native_pipeline_started = false
	_pico_native_metrics_accum.clear()
	_pico_camera_sink_bound = false
	_pico_camera_frame_accum_s = 0.0
	_pico_camera_submit_ok_left = 0
	_pico_camera_submit_ok_right = 0
	_pico_camera_submit_fail_left = 0
	_pico_camera_submit_fail_right = 0
	_pico_camera_frames_skipped = 0
	_pico_camera_acquire_us = 0
	_pico_camera_submit_us = 0
	_pico_camera_submit_fail_session = 0
	_pico_camera_fail_count_at_last_warn = 0
	_pico_camera_fail_warn_ticks_us = 0


## Configures the provider for one capture session. `writer` is the primary
## session writer (session paths and the session-start clock anchors);
## `audio` is AudioSource.session_config(). Returns false on failure.
func configure_session(writer: Object, options: Dictionary, audio: Dictionary) -> bool:
	var session_dir_absolute: String = writer.get_session_dir_absolute()
	var output_mp4_absolute: String = writer.get_output_mp4_path_absolute()
	var partial_mp4_absolute: String = writer.get_partial_mp4_path_absolute()
	print("%s configure begin: %s" % [label(), output_mp4_absolute])
	var configured_result: Variant
	var export_space_id := OpenXRExportSpace.coordinate_space_id(
		options.get("export_coordinate_space", OpenXRExportSpace.DEFAULT))
	# Both providers embed this declaration in operator_static. RGB
	# extrinsics stay head-relative; only the head trajectory's base changes.
	# Android Godot plugin singletons do not reliably report @UsedByGodot
	# methods through has_method(), so call the compact JSON RPC directly.
	plugin.call("setExportCoordinateSpace", export_space_id)
	if uses_pico_bridge():
		plugin.call("setRgbVideoCodec", str(options.get("rgb_codec", DEFAULT_RGB_CODEC)))
		configured_result = plugin.call(
			"configureSpatialMp4SessionWithTime",
			output_mp4_absolute,
			partial_mp4_absolute,
			session_dir_absolute,
			writer.get_session_start_unix_us(),
			writer.get_session_start_ticks_us(),
			Time.get_ticks_usec(),
			_enabled(options, "record_depth"),
			_enabled(options, "record_head_pose"),
			_enabled(options, "record_controller_pose"),
			_enabled(options, "record_hand_data"),
			_enabled(options, "record_controller_pose"),
			bool(options.get("stereo_rgb", true)),
			int(options.get("rgb_bitrate", DEFAULT_RGB_BITRATE)),
			int(options.get("rgb_fps", DEFAULT_RGB_FPS))
		)
	else:
		var session_config := {
			"final_path": output_mp4_absolute,
			"partial_path": partial_mp4_absolute,
			"session_dir": session_dir_absolute,
			"session_start_unix_us": writer.get_session_start_unix_us(),
			"session_start_godot_ticks_us": writer.get_session_start_ticks_us(),
			"configure_godot_ticks_us": Time.get_ticks_usec(),
			"record_depth": _enabled(options, "record_depth"),
			"record_head_pose": _enabled(options, "record_head_pose"),
			"record_controller_pose": _enabled(options, "record_controller_pose"),
			"record_hand_data": _enabled(options, "record_hand_data"),
			"record_controller_input": _enabled(options, "record_controller_pose"),
			"stereo_rgb": bool(options.get("stereo_rgb", true)),
			"rgb_bitrate": int(options.get("rgb_bitrate", DEFAULT_RGB_BITRATE)),
			"rgb_fps": int(options.get("rgb_fps", DEFAULT_RGB_FPS)),
			"rgb_width": int(options.get("rgb_width", 0)),
			"rgb_height": int(options.get("rgb_height", 0)),
			"rgb_resolution": str(options.get("rgb_resolution", "")),
			"rgb_codec": str(options.get("rgb_codec", DEFAULT_RGB_CODEC)),
		}
		session_config.merge(audio, true)
		configured_result = plugin.call(
			"configureSpatialMp4SessionFromJson",
			JSON.stringify(session_config)
		)
	# Body-motion options are configured the same way on every provider so the
	# settings panel's "Body tracking" toggle reaches the active provider. PICO
	# wires it to XR_BD_body_tracking + motion-tracker pucks; Quest wires it to
	# Meta XR body tracking (XR_FB_body_tracking / XR_META_body_tracking_full_body).
	# has_method() is unreliable for Godot Android plugin singletons, so this is
	# called unconditionally: a provider that lacks it fails loudly at startup
	# instead of silently disabling body tracking for the whole session.
	plugin.call(
			"setBodyMotionCaptureOptions",
			_enabled(options, "record_body_tracking"),
			_enabled(options, "record_motion_trackers"),
			int(options.get("max_motion_trackers", DEFAULT_MAX_MOTION_TRACKERS))
		)
	configured = bool(configured_result)
	print("%s configureSession returned: %s (audio=%s)" % [label(), configured_result, bool(audio.get("record_audio", false))])
	return configured


## True while the provider is configured but not yet started.
func awaiting_start() -> bool:
	return plugin != null and configured and not start_attempted


## Starts the cameras. Callers first confirm permission_ready() and the
## other sources' readiness.
func start(options: Dictionary) -> bool:
	start_attempted = true
	var started := false
	if uses_pico_bridge():
		started = _start_pico_openxr_camera_image_capture(options)
	else:
		print("%s invoking startCameras" % label())
		started = bool(plugin.call("startCameras"))
		print("%s startCameras returned: %s" % [label(), started])
	return started


func stop() -> void:
	if uses_pico_bridge() and pico_bridge != null and pico_bridge.has_method("stop_camera_image_capture"):
		pico_bridge.call("stop_camera_image_capture")
	if plugin != null:
		plugin.call("stopCameras")
	_pico_camera_image_started = false
	_pico_native_pipeline_started = false
	_pico_camera_sink_bound = false


## "" while the provider pipeline is healthy; otherwise why it stopped.
func pipeline_error() -> String:
	if not _pico_native_pipeline_started \
			or bool(pico_bridge.call("is_native_recording_pipeline_running")):
		return ""
	var camera_error_text := "native PICO camera pipeline stopped unexpectedly"
	if pico_bridge.has_method("get_native_recording_pipeline_error"):
		camera_error_text += ": %s" % str(pico_bridge.call("get_native_recording_pipeline_error"))
	_pico_native_pipeline_started = false
	return camera_error_text


func pump(delta: float) -> void:
	if not uses_pico_bridge() or not _pico_camera_image_started:
		return
	var bridge := pico_bridge
	if bridge == null or plugin == null:
		return
	_pico_camera_frame_accum_s += delta
	if _pico_camera_frame_accum_s < _pico_camera_poll_interval_s:
		return
	# Carry the remainder forward (instead of zeroing) so the effective poll
	# rate tracks wall time, but clamp to one interval so a long frame hitch
	# doesn't queue up a burst of catch-up polls.
	_pico_camera_frame_accum_s = minf(
		_pico_camera_frame_accum_s - _pico_camera_poll_interval_s,
		_pico_camera_poll_interval_s
	)
	# Native mode is independently clocked. This main-thread call only drains
	# tiny counters for QcCamera; it never acquires, copies, or submits RGB.
	if _pico_native_pipeline_started:
		if bridge.has_method("pop_native_recording_metrics"):
			var native_metrics: Variant = bridge.call("pop_native_recording_metrics")
			if typeof(native_metrics) == TYPE_DICTIONARY:
				for key in (native_metrics as Dictionary).keys():
					_pico_native_metrics_accum[key] = int(_pico_native_metrics_accum.get(key, 0)) + int((native_metrics as Dictionary)[key])
		return
	# Kotlin-direct pump: the bridge submits frames to the capture plugin
	# (submitOpenXrRgbaFrame) entirely in C++ — the large per-eye RGBA
	# PackedByteArrays never round-trip through GDScript Dictionaries. This
	# GDScript tick is one call + a compact counter array at ~60 Hz. The native
	# pump moves at most one eye per call and alternates eyes.
	if not _pico_camera_sink_bound:
		if not bridge.has_method("bind_camera_frame_sink"):
			# Bridge .so predates the direct pump; RGB capture requires the
			# matching pico_openxr build (same APK ships both, so this only
			# fires on a stale sideload).
			if not _pico_camera_pump_warned:
				_pico_camera_pump_warned = true
				push_error("pico_openxr bridge lacks bind_camera_frame_sink — rebuild the APK (make build-pico); Pico RGB frames will not be recorded.")
			return
		bridge.call("bind_camera_frame_sink", plugin)
		_pico_camera_sink_bound = true
	var counters: Variant = bridge.call("pump_camera_frames_to_sink")
	if counters is PackedInt32Array and (counters as PackedInt32Array).size() >= 5:
		var c := counters as PackedInt32Array
		_pico_camera_submit_ok_left += c[0]
		_pico_camera_submit_ok_right += c[1]
		_pico_camera_submit_fail_left += c[2]
		_pico_camera_submit_fail_right += c[3]
		_pico_camera_frames_skipped += c[4]
		if c.size() >= 7:
			_pico_camera_acquire_us += c[5]
			_pico_camera_submit_us += c[6]
		var failed := c[2] + c[3]
		if failed > 0:
			_pico_camera_submit_fail_session += failed
			_maybe_warn_pico_submit_failures()


## Provider encoder metrics for the 1 Hz QcMetrics line.
func pop_plugin_metrics() -> Dictionary:
	if plugin == null:
		return {}
	var raw: Variant = plugin.call("popMetricsJson")
	var parsed: Variant = null
	if typeof(raw) == TYPE_STRING and not String(raw).is_empty():
		parsed = JSON.parse_string(String(raw))
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}


## GDScript-side PICO camera pump counters (submit ok/fail per eye plus skipped
## invalid frames). Empty unless the PICO OpenXR pump ran.
func pop_pump_metrics() -> Dictionary:
	if not _pico_native_metrics_accum.is_empty():
		var native_metrics := _pico_native_metrics_accum.duplicate()
		_pico_native_metrics_accum.clear()
		return native_metrics
	if _pico_camera_submit_ok_left == 0 and _pico_camera_submit_ok_right == 0 \
			and _pico_camera_submit_fail_left == 0 and _pico_camera_submit_fail_right == 0 \
			and _pico_camera_frames_skipped == 0 and _pico_camera_acquire_us == 0 \
			and _pico_camera_submit_us == 0:
		return {}
	var metrics := {
		"ok_l": _pico_camera_submit_ok_left,
		"ok_r": _pico_camera_submit_ok_right,
		"fail_l": _pico_camera_submit_fail_left,
		"fail_r": _pico_camera_submit_fail_right,
		"skip": _pico_camera_frames_skipped,
		"acquire_ms": _pico_camera_acquire_us / 1000.0,
		"submit_ms": _pico_camera_submit_us / 1000.0,
	}
	_pico_camera_submit_ok_left = 0
	_pico_camera_submit_ok_right = 0
	_pico_camera_submit_fail_left = 0
	_pico_camera_submit_fail_right = 0
	_pico_camera_frames_skipped = 0
	_pico_camera_acquire_us = 0
	_pico_camera_submit_us = 0
	return metrics


## PICO camera-image runtime capabilities for the RGB settings UI, or {} while
## the runtime has not reported them.
func rgb_runtime_capabilities() -> Dictionary:
	if pico_bridge == null or not pico_bridge.has_method("get_camera_image_capabilities"):
		return {}
	var raw_capabilities: Variant = pico_bridge.call("get_camera_image_capabilities")
	if not (raw_capabilities is Dictionary):
		return {}
	var capabilities := raw_capabilities as Dictionary
	if not bool(capabilities.get("available", false)):
		return {}
	return capabilities


## Ad-hoc head-pose source probe (1 Hz). Logs three things side by side:
##   1) Godot XRCamera3D.global_transform — what pose_sampler.gd records as
##      "head pose" into the MP4.
##   2) xrLocateSpace(VIEW, play) via the Pico OpenXR extension — what the
##      runtime authoritatively considers the OpenXR VIEW space pose.
##   3) The Pico RGB lens_pose (constant per session) stored as T_I_S.
## If (1) and (2) match, "hmd_camera" == OpenXR VIEW and any residual
## 2D-projection error must come from the T_I_S side.
func log_view_pose_probe(hmd_camera: Node3D) -> void:
	if hmd_camera == null:
		return
	var godot_t: Transform3D = hmd_camera.global_transform
	var godot_pos := godot_t.origin
	var godot_quat := godot_t.basis.get_rotation_quaternion()
	_view_pose_log_count += 1
	print("[PROBE %d] godot.hmd_camera.global_transform pos=(%.4f, %.4f, %.4f) quat_xyzw=(%.4f, %.4f, %.4f, %.4f)" % [
		_view_pose_log_count,
		godot_pos.x, godot_pos.y, godot_pos.z,
		godot_quat.x, godot_quat.y, godot_quat.z, godot_quat.w,
	])
	if pico_bridge != null and pico_bridge.has_method("probe_view_space_pose"):
		var probe: Dictionary = pico_bridge.call("probe_view_space_pose")
		var available: bool = bool(probe.get("available", false))
		if available:
			var t: Transform3D = probe.get("transform", Transform3D())
			var p := t.origin
			var q := t.basis.get_rotation_quaternion()
			var dp := godot_pos - p
			print("[PROBE %d] xrLocateSpace(VIEW, play)    pos=(%.4f, %.4f, %.4f) quat_xyzw=(%.4f, %.4f, %.4f, %.4f)  delta_pos_from_godot=(%.4f, %.4f, %.4f) |delta|=%.4f" % [
				_view_pose_log_count,
				p.x, p.y, p.z,
				q.x, q.y, q.z, q.w,
				dp.x, dp.y, dp.z, dp.length(),
			])
		else:
			print("[PROBE %d] xrLocateSpace probe unavailable: %s flags=%s xr_result=%s" % [
				_view_pose_log_count,
				probe.get("reason", "?"),
				probe.get("location_flags", "?"),
				probe.get("xr_result", "?"),
			])
	else:
		print("[PROBE %d] pico_openxr_bridge missing probe_view_space_pose() — APK not rebuilt with native probe" % _view_pose_log_count)
	if pico_bridge != null and pico_bridge.has_method("get_camera_image_info"):
		var info: Dictionary = pico_bridge.call("get_camera_image_info")
		var left_meta: Dictionary = info.get("left", {})
		var trans: Array = left_meta.get("lens_pose_translation", []) as Array
		var rot: Array = left_meta.get("lens_pose_rotation", []) as Array
		if trans.size() == 3 and rot.size() == 4:
			print("[PROBE %d] T_I_S (XR_PICO_camera_image left lens_pose) translation=(%.4f, %.4f, %.4f) rotation_xyzw=(%.4f, %.4f, %.4f, %.4f)" % [
				_view_pose_log_count,
				float(trans[0]), float(trans[1]), float(trans[2]),
				float(rot[0]), float(rot[1]), float(rot[2]), float(rot[3]),
			])


static func rgb_resolution_from_options(options: Dictionary, fallback: Vector2i) -> Vector2i:
	var width := int(options.get("rgb_width", fallback.x))
	var height := int(options.get("rgb_height", fallback.y))
	if width > 0 and height > 0:
		return Vector2i(width, height)
	var resolution := str(options.get("rgb_resolution", "")).strip_edges().to_lower()
	var parts := resolution.split("x", false, 2)
	if parts.size() == 2:
		width = int(parts[0])
		height = int(parts[1])
		if width > 0 and height > 0:
			return Vector2i(width, height)
	return fallback


static func rgb_resolution_text(resolution: Vector2i) -> String:
	return "%dx%d" % [resolution.x, resolution.y]


func _start_pico_openxr_camera_image_capture(options: Dictionary) -> bool:
	if pico_bridge == null:
		push_error("PicoOpenXRExtension is not available; cannot start XR_PICO_camera_image")
		return false
	if not pico_bridge.has_method("start_camera_image_capture"):
		push_error("PicoOpenXRExtension does not expose start_camera_image_capture")
		return false
	var stereo := bool(options.get("stereo_rgb", true))
	var fps := int(options.get("rgb_fps", DEFAULT_RGB_FPS))
	var resolution := rgb_resolution_from_options(options, Vector2i.ZERO)
	var info: Variant = pico_bridge.call(
		"start_camera_image_capture",
		stereo,
		resolution.x,
		resolution.y,
		fps
	)
	if typeof(info) != TYPE_DICTIONARY:
		push_error("XR_PICO_camera_image start returned invalid info")
		return false
	var info_dict := info as Dictionary
	print("XR_PICO_camera_image start info: %s" % JSON.stringify(info_dict))
	if not bool(info_dict.get("active", false)):
		push_error("XR_PICO_camera_image did not become active: %s" % JSON.stringify(info_dict))
		return false
	var negotiated_resolution := Vector2i(
		int(info_dict.get("width", 0)), int(info_dict.get("height", 0)))
	if resolution != Vector2i.ZERO and negotiated_resolution != resolution:
		pico_bridge.call("stop_camera_image_capture")
		push_error(
			"XR_PICO_camera_image negotiated %s instead of explicitly requested %s"
			% [rgb_resolution_text(negotiated_resolution), rgb_resolution_text(resolution)])
		return false
	# Poll at 2x the negotiated camera fps (see _pico_camera_poll_interval_s).
	_pico_camera_poll_interval_s = 0.5 / max(float(info_dict.get("fps", DEFAULT_RGB_FPS)), 1.0)
	if plugin.has_method("setOpenXrCameraImageInfoJson"):
		plugin.call("setOpenXrCameraImageInfoJson", JSON.stringify(info_dict))
	var started: bool = bool(plugin.call("startOpenXrCameraImageCapture", JSON.stringify(info_dict)))
	print("%s startOpenXrCameraImageCapture returned: %s" % [label(), started])
	if not started:
		_pico_camera_image_started = false
		return false
	if not pico_bridge.has_method("start_native_recording_pipeline"):
		push_error("pico_openxr bridge lacks the native camera/hand recording pipeline; rebuild the APK")
		return false
	# Android @UsedByGodot methods are callable even though has_method() may
	# report false. This PICO-specific branch always binds PicoCapturePlugin,
	# whose anchor maps OpenXR CLOCK_MONOTONIC timestamps to Godot process ticks.
	var time_offset_ns := xr_time_to_godot_ticks_offset_ns()
	var exact_head_samples := _enabled(options, "record_head_pose")
	var exact_hand_samples := _enabled(options, "record_hand_data")
	var tracking_coordinate_space := str(options.get(
		"export_coordinate_space_id",
		OpenXRExportSpace.coordinate_space_id(
			options.get("export_coordinate_space", OpenXRExportSpace.DEFAULT))))
	var native_started := bool(pico_bridge.call(
		"start_native_recording_pipeline",
		str(options.get("rgb_codec", DEFAULT_RGB_CODEC)),
		int(options.get("rgb_bitrate", DEFAULT_RGB_BITRATE)),
		time_offset_ns,
		exact_head_samples or exact_hand_samples,
		exact_head_samples,
		exact_hand_samples,
		tracking_coordinate_space
	))
	if not native_started:
		var native_error := ""
		if pico_bridge.has_method("get_native_recording_pipeline_error"):
			native_error = str(pico_bridge.call("get_native_recording_pipeline_error"))
		push_error("Failed to start native PICO RGB encoder: %s" % native_error)
		return false
	_pico_camera_image_started = true
	_pico_native_pipeline_started = true
	print("PICO native recording pipeline started: OpenXR RGBA -> GLES -> NDK MediaCodec")
	return true


func _maybe_warn_pico_submit_failures() -> void:
	var now_us := Time.get_ticks_usec()
	if _pico_camera_fail_count_at_last_warn > 0 \
			and _pico_camera_submit_fail_session - _pico_camera_fail_count_at_last_warn < PICO_CAMERA_FAIL_WARN_EVERY \
			and now_us - _pico_camera_fail_warn_ticks_us < PICO_CAMERA_FAIL_WARN_INTERVAL_US:
		return
	_pico_camera_fail_count_at_last_warn = _pico_camera_submit_fail_session
	_pico_camera_fail_warn_ticks_us = now_us
	push_warning("Pico OpenXR camera frame submission failed %d time(s) this session; frames are being dropped (see QcMetrics pump_fail_l/pump_fail_r and plugin oxr_rej_* counters)." % _pico_camera_submit_fail_session)


static func _enabled(options: Dictionary, option: String) -> bool:
	return bool(options.get(option, true))


func _on_camera_ready(eye: String, camera_id: String) -> void:
	print("%s camera ready: %s=%s" % [label(), eye, camera_id])


func _on_camera_frame_saved(eye: String, _path: String, timestamp_ns: int) -> void:
	if timestamp_ns > 0 and eye == "left":
		print_verbose("%s frames are being recorded" % label())


func _on_camera_error(message: String) -> void:
	last_error = message
	push_error("%s: %s" % [label(), message])
	camera_error.emit(message)
