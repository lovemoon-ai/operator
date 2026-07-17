extends RefCounted
class_name SessionSpoolWriter

const DEFAULT_CAPTURE_ROOT := "/sdcard/DCIM/SpatialMP4"
const CAMERA_CHARACTERISTICS_ARTIFACTS := [
	{
		"kind": "left_camera_characteristics",
		"filename": "left_camera_characteristics.json"
	},
	{
		"kind": "right_camera_characteristics",
		"filename": "right_camera_characteristics.json"
	},
]

var session_id := ""
var session_dir := ""
var output_mp4_path := ""
var partial_mp4_path := ""
var saved_path := ""
var session_start_unix_us := 0
var session_start_ticks_us := 0
var capture_options: Dictionary = {}
var android_plugin: Object
# Stage 2b split: every native write (depth / pose / hand / controller input /
# finish) now lives on SpatialMp4MuxerPlugin; android_plugin (the provider)
# is kept only for legacy callers and to query camera intrinsics if needed.
var muxer_plugin: Object

# WP5: the JSONL sidecar files (poses/*.jsonl, body_motion/*.jsonl,
# depth/frames.jsonl) moved verbatim to sinks/jsonl/jsonl_sidecar_sink.gd.
# This writer keeps the mp4/muxer engine: session dirs, manifest write +
# finalize rewrite, sha256, and all native write* calls.
# Body-tracking runtime info captured at close() time so the manifest reflects
# which extension actually fed samples (PICO BD vs Meta XR_FB / full_body).
# capture_app.gd::stop_capture() queries body_motion_sampler.get_runtime_info()
# and forwards the dict here via set_body_tracking_runtime_info() before
# calling close().
var _body_tracking_runtime_info: Dictionary = {}
# Debug-only: when capture option `dump_raw_depth` is true, every pre-encode
# depth payload is written here in capture order so the FFV1 mp4 track can be
# checked bit-for-bit offline (scripts/verify_depth_ffv1.py --reference).
var _depth_raw_dir := ""
var _depth_raw_index := 0
var _depth_sidecar_frame_count := 0
var _depth_mp4_write_count := 0
var _depth_mp4_write_failed_count := 0
var _depth_last_mp4_write_error := ""
var _muxer_contract_version_cache := -1


func start_session(options: Dictionary = {}) -> bool:
	close()
	capture_options = options.duplicate(true)
	# Wipe any body-runtime info left over from a prior session; the new
	# session's sampler will report fresh values via
	# set_body_tracking_runtime_info() before the next close().
	_body_tracking_runtime_info = {}
	_depth_raw_dir = ""
	_depth_raw_index = 0
	_depth_sidecar_frame_count = 0
	_depth_mp4_write_count = 0
	_depth_mp4_write_failed_count = 0
	_depth_last_mp4_write_error = ""
	_muxer_contract_version_cache = -1
	session_start_unix_us = Time.get_unix_time_from_system() * 1000000
	session_start_ticks_us = Time.get_ticks_usec()
	session_id = _make_session_id()
	saved_path = ""
	var capture_root := str(capture_options.get("save_root", DEFAULT_CAPTURE_ROOT)).strip_edges()
	if capture_root.is_empty():
		capture_root = DEFAULT_CAPTURE_ROOT
	session_dir = capture_root.path_join(session_id)
	output_mp4_path = capture_root.path_join("%s.mp4" % session_id)
	partial_mp4_path = capture_root.path_join("%s.partial.mp4" % session_id)

	if _make_dir(session_dir) != OK:
		push_error("Unable to create capture session directory: %s" % session_dir)
		session_dir = ""
		return false
	if _capture_enabled("record_head_pose") or _capture_enabled("record_controller_pose") or _capture_enabled("record_hand_data"):
		if _make_dir("%s/poses" % session_dir) != OK:
			return false
	var save_body_sidecar := bool(capture_options.get("save_body_sidecar", false))
	if (save_body_sidecar and _capture_enabled("record_body_tracking")) or _capture_enabled("record_motion_trackers"):
		if _make_dir("%s/body_motion" % session_dir) != OK:
			return false
	if _capture_enabled("record_depth"):
		if _make_dir("%s/depth" % session_dir) != OK:
			return false
		# Opt-in raw payload dump for offline lossless verification (default off).
		if bool(capture_options.get("dump_raw_depth", false)):
			_depth_raw_dir = "%s/depth/raw" % session_dir
			_depth_raw_index = 0
			if _make_dir(_depth_raw_dir) != OK:
				_depth_raw_dir = ""

	var sources := {}
	var capture_provider := str(capture_options.get("capture_provider", ""))
	# WP6: provider-keyed source text lives in the manifest contract.
	sources["rgb"] = SpatialMp4ManifestContract.rgb_source_description(
		capture_provider,
		_capture_enabled("stereo_rgb"),
		str(capture_options.get("rgb_codec", "hevc"))
	)
	if _capture_enabled("record_depth"):
		sources["depth"] = "OpenXRMetaEnvironmentDepthExtension converted to uint16 millimeters, FFV1 lossless (intra) in the mp4 depth track; PTS from OpenXR runtime_display_time_ns when available"
	if _capture_enabled("record_head_pose") or _capture_enabled("record_controller_pose") or _capture_enabled("record_hand_data"):
		var export_space := str(capture_options.get("export_coordinate_space_id", "openxr_play_space"))
		sources["pose"] = "Head, controller, and hand transforms relative to %s; RGB extrinsics remain head-relative (T_export_camera = T_export_head * T_head_camera); PTS from OpenXR runtime display time when available, else Time.get_ticks_usec()" % export_space
	if _capture_enabled("record_body_tracking"):
		# Placeholder — close() patches in the actual runtime info once the
		# sampler has observed at least one frame, so the manifest stores the
		# specific extension / joint set instead of a vague "either-or" blurb.
		sources["body_tracking"] = {
			"description": "Body joints in the mp4 mett track `spatialmp4:body_joints:body` (HJNT v1 layout). The runtime (PICO BD vs Meta XR_FB / XR_META_full_body) is patched in at session close based on the samples actually observed.",
			"observed_runtime": "",
			"extension": "",
			"joint_set": "",
			"joint_count": 0
		}
	if _capture_enabled("record_motion_trackers"):
		sources["motion_trackers"] = "PICO OpenXR XR_PICO_motion_tracking tracker poses, velocities, accelerations, battery state, and power-key events when available; stored in the mp4 `motion_trackers` metadata track with optional body_motion/motion_trackers.jsonl debug mirror"
	# v3 spatial audio. The audio path is provider-driven (AudioRecord ->
	# MediaCodec AAC-LC -> SpatialDataSink), so GDScript never sees a frame;
	# we just record the configured shape in the manifest. The same fields
	# get echoed into the mp4 audio track's stream metadata (`spatial_format`,
	# `channel_count`, `sample_rate_hz`) so an offline reader can correlate.
	if bool(capture_options.get("record_audio", false)):
		var requested_audio_layout := str(capture_options.get("audio_channel_layout", "stereo"))
		var audio_layout := _effective_audio_layout_for_request(requested_audio_layout)
		var audio_sample_rate := int(capture_options.get("audio_sample_rate_hz", 48000))
		var audio_bitrate := int(capture_options.get("audio_bitrate_bps", 128000))
		sources["audio"] = {
			"codec": "aac_lc",
			"channel_layout": audio_layout,
			"requested_channel_layout": requested_audio_layout,
			"layout_fallback": requested_audio_layout != audio_layout,
			"channel_count": _audio_channel_count_for_layout(audio_layout),
			"sample_rate_hz": audio_sample_rate,
			"bitrate_bps": audio_bitrate,
			"pipeline": "Android MediaRecorder.AudioSource.MIC -> AudioRecord -> MediaCodec AAC-LC -> SpatialDataSink",
			"pts_domain": "godot_ticks_ns",
			"pts_anchor": "first_successful_microphone_read_godot_ticks_us + n * (1024 * 1_000_000 / sample_rate_hz)"
		}

	_write_json("%s/manifest.json" % session_dir, {
		"schema": "spatialmp4.quest_capture.spool.v3",
		"session_id": session_id,
		"output_mp4_path": output_mp4_path,
		"partial_mp4_path": partial_mp4_path,
		"session_start_unix_us": session_start_unix_us,
		"session_start_ticks_us": session_start_ticks_us,
		"timebase_hz": 1000000,
		"media_pts_domain": "godot_ticks_ns",
		"media_pts_clock": "clock_monotonic_ns",
		"depth_timestamp_source_priority": ["openxr_runtime_display_time", "godot_async_callback_ticks"],
		"capture_options": capture_options,
		"resolved_capture_options": capture_options.duplicate(true),
		"sources": sources,
		"depth_saved_in_mp4": false,
		"stream_confirmations": {
			"rgb": _rgb_confirmation_record(false, "", capture_options, {}),
			"depth": _depth_confirmation_record(false, "")
		},
		"device": _resolve_device_identity()
	})

	# Every pose stream (head, controllers, hands) flows into the MP4's `mett`
	# tracks via the muxer plugin. The JSONL sidecars are debug-only mirrors
	# and are owned by JsonlSidecarSink since WP5 (identical filenames,
	# option gating, and line shapes; SpoolWriterAdapter opens it right after
	# this returns).
	return true


func close() -> void:
	var attempted_native_finish := muxer_plugin != null
	if muxer_plugin != null:
		var finalized: String = str(muxer_plugin.call("finishSpatialMp4"))
		if not finalized.is_empty():
			saved_path = finalized
	if saved_path.is_empty() and not attempted_native_finish and not output_mp4_path.is_empty():
		saved_path = output_mp4_path

	if session_dir.is_empty():
		return

	# Patch finalize-time facts back into the manifest. Unlike `sources.depth`,
	# this confirmation records whether a depth frame was actually accepted by
	# the mp4 muxer during this session.
	var media_hash := ""
	if not saved_path.is_empty():
		media_hash = _compute_file_sha256(saved_path)
		if media_hash.is_empty():
			push_warning("session_spool_writer: sha256 compute failed for %s" % saved_path)
	_rewrite_manifest_after_finalize(saved_path, media_hash)


# Stream the file in chunks so we never hold more than CHUNK bytes in
# memory; the Quest 3 IO subsystem reads ~1 GB/s sequentially so the
# wall time is dominated by SHA cost (~80 MB/s on this hardware).
func _compute_file_sha256(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("session_spool_writer: cannot open %s for hashing (%d)" % [path, FileAccess.get_open_error()])
		return ""
	const CHUNK := 4 * 1024 * 1024
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		f.close()
		return ""
	while f.get_position() < f.get_length():
		var data := f.get_buffer(CHUNK)
		if data.is_empty():
			break
		if ctx.update(data) != OK:
			f.close()
			return ""
	f.close()
	return ctx.finish().hex_encode()


func _file_length(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var length := int(f.get_length())
	f.close()
	return length


# Rewrite manifest.json in place to add finalize-time media integrity and
# per-stream confirmations. We keep the original top-level fields untouched
# so any v3 reader that doesn't know these additive fields keeps working.
func _rewrite_manifest_after_finalize(media_path: String, media_sha256: String) -> void:
	var manifest_path := "%s/manifest.json" % session_dir
	var reader := FileAccess.open(manifest_path, FileAccess.READ)
	if reader == null:
		push_warning("session_spool_writer: manifest missing at %s; skipping finalize rewrite" % manifest_path)
		return
	var text := reader.get_as_text()
	reader.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("session_spool_writer: manifest at %s is not a JSON object; skipping finalize rewrite" % manifest_path)
		return
	var manifest: Dictionary = parsed
	var artifacts_field: Variant = manifest.get("artifacts", {})
	var artifacts: Dictionary = artifacts_field if artifacts_field is Dictionary else {}
	if not media_path.is_empty():
		var media_artifact := {
			"filename": media_path.get_file(),
			"bytes": _file_length(media_path)
		}
		if not media_sha256.is_empty():
			media_artifact["sha256"] = media_sha256
			media_artifact["hash_algo"] = "sha256"
		artifacts["media"] = media_artifact
	for sidecar in CAMERA_CHARACTERISTICS_ARTIFACTS:
		var filename := str(sidecar.get("filename", ""))
		var sidecar_path := session_dir.path_join(filename)
		if filename.is_empty() or not FileAccess.file_exists(sidecar_path):
			continue
		var sidecar_hash := _compute_file_sha256(sidecar_path)
		var sidecar_artifact := {
			"filename": filename,
			"bytes": _file_length(sidecar_path)
		}
		if not sidecar_hash.is_empty():
			sidecar_artifact["sha256"] = sidecar_hash
			sidecar_artifact["hash_algo"] = "sha256"
		artifacts[str(sidecar.get("kind", filename.get_basename()))] = sidecar_artifact
	if not artifacts.is_empty():
		manifest["artifacts"] = artifacts
	var rgb_actual := _actual_rgb_recording_geometry()
	var resolved_capture_options := _resolved_capture_options_with_actual_rgb(manifest, rgb_actual)
	manifest["resolved_capture_options"] = resolved_capture_options
	# Patch in the body-tracking runtime info collected at close() so the
	# offline viewer can pick the right skeleton table for the joint ids it
	# finds in `spatialmp4:body_joints:body`. If the sampler never observed a
	# frame (no body tracking permission, runtime did not support it, …) we
	# still leave the original "observed_runtime: ''" placeholder so the
	# downstream tooling can distinguish "tried but got nothing" from "never
	# asked".
	if not _body_tracking_runtime_info.is_empty():
		var sources_field: Variant = manifest.get("sources", {})
		var sources_dict: Dictionary = sources_field if sources_field is Dictionary else {}
		var body_field: Variant = sources_dict.get("body_tracking", {})
		var body_entry: Dictionary = body_field if body_field is Dictionary else {"description": str(body_field)}
		for key in _body_tracking_runtime_info.keys():
			body_entry[key] = _body_tracking_runtime_info[key]
		sources_dict["body_tracking"] = body_entry
		manifest["sources"] = sources_dict
	var depth_confirmation := _depth_confirmation_record(true, media_path)
	manifest["depth_saved_in_mp4"] = bool(depth_confirmation.get("saved_in_mp4", false))
	var confirmations_field: Variant = manifest.get("stream_confirmations", {})
	var confirmations: Dictionary = confirmations_field if confirmations_field is Dictionary else {}
	confirmations["rgb"] = _rgb_confirmation_record(true, media_path, resolved_capture_options, rgb_actual)
	confirmations["depth"] = depth_confirmation
	manifest["stream_confirmations"] = confirmations
	_write_json(manifest_path, manifest)


func _resolved_capture_options_with_actual_rgb(manifest: Dictionary, rgb_actual: Dictionary) -> Dictionary:
	var capture_options_field: Variant = manifest.get("capture_options", capture_options)
	var source_options: Dictionary = capture_options_field if capture_options_field is Dictionary else capture_options
	var resolved := source_options.duplicate(true)
	if rgb_actual.is_empty():
		return resolved
	var left_width := int(rgb_actual.get("left_width", 0))
	var left_height := int(rgb_actual.get("left_height", 0))
	if left_width <= 0 or left_height <= 0:
		return resolved
	resolved["rgb_width"] = left_width
	resolved["rgb_height"] = left_height
	resolved["rgb_resolution"] = "%dx%d" % [left_width, left_height]
	resolved["rgb_encoded_width"] = int(rgb_actual.get("encoded_width", left_width))
	resolved["rgb_encoded_height"] = int(rgb_actual.get("encoded_height", left_height))
	resolved["rgb_camera_count"] = int(rgb_actual.get("camera_count", 1))
	return resolved


func _rgb_confirmation_record(
	finalized: bool,
	media_path: String,
	resolved_options: Dictionary,
	rgb_actual: Dictionary
) -> Dictionary:
	var requested_width := int(capture_options.get("rgb_width", 0))
	var requested_height := int(capture_options.get("rgb_height", 0))
	var actual_width := int(rgb_actual.get("left_width", 0))
	var actual_height := int(rgb_actual.get("left_height", 0))
	var actual_camera_count := int(rgb_actual.get("camera_count", 0))
	var saved_in_mp4 := finalized and not media_path.is_empty() and actual_width > 0 and actual_height > 0
	var status := "pending"
	var reason := ""
	if finalized:
		if saved_in_mp4:
			status = "saved"
		elif media_path.is_empty():
			status = "missing"
			reason = "mp4 finalize failed"
		else:
			status = "unknown"
			reason = "camera recording metadata missing"
	return {
		"requested": true,
		"saved_in_mp4": saved_in_mp4,
		"status": status,
		"reason": reason,
		"finalized": finalized,
		"mp4_path": media_path,
		"requested_width": requested_width,
		"requested_height": requested_height,
		"requested_resolution": str(capture_options.get("rgb_resolution", "")),
		"requested_fps": int(capture_options.get("rgb_fps", 0)),
		"requested_codec": str(capture_options.get("rgb_codec", "hevc")),
		"actual_width": actual_width,
		"actual_height": actual_height,
		"actual_resolution": "%dx%d" % [actual_width, actual_height] if actual_width > 0 and actual_height > 0 else "",
		"actual_encoded_width": int(rgb_actual.get("encoded_width", 0)),
		"actual_encoded_height": int(rgb_actual.get("encoded_height", 0)),
		"actual_camera_count": actual_camera_count,
		"actual_stereo": actual_camera_count >= 2,
		"fps": int(resolved_options.get("rgb_fps", capture_options.get("rgb_fps", 0))),
		"codec": str(resolved_options.get("rgb_codec", capture_options.get("rgb_codec", "hevc")))
	}


func _actual_rgb_recording_geometry() -> Dictionary:
	var left := _camera_recording_size("left_camera_characteristics.json")
	if left.is_empty():
		return {}
	var right := _camera_recording_size("right_camera_characteristics.json")
	var left_width := int(left.get("width", 0))
	var left_height := int(left.get("height", 0))
	var camera_count := 1
	var encoded_width := left_width
	if bool(capture_options.get("stereo_rgb", true)) and not right.is_empty():
		var right_width := int(right.get("width", 0))
		var right_height := int(right.get("height", 0))
		if right_width > 0 and right_height > 0:
			camera_count = 2
			encoded_width += right_width
	return {
		"left_width": left_width,
		"left_height": left_height,
		"right_width": int(right.get("width", 0)) if not right.is_empty() else 0,
		"right_height": int(right.get("height", 0)) if not right.is_empty() else 0,
		"encoded_width": encoded_width,
		"encoded_height": left_height,
		"camera_count": camera_count
	}


func _camera_recording_size(filename: String) -> Dictionary:
	var path := session_dir.path_join(filename)
	if not FileAccess.file_exists(path):
		return {}
	var reader := FileAccess.open(path, FileAccess.READ)
	if reader == null:
		return {}
	var parsed: Variant = JSON.parse_string(reader.get_as_text())
	reader.close()
	if not (parsed is Dictionary):
		return {}
	var metadata: Dictionary = parsed
	var intrinsics_field: Variant = metadata.get("recording_intrinsics", {})
	var width := 0
	var height := 0
	if intrinsics_field is Dictionary:
		var intrinsics: Dictionary = intrinsics_field
		width = int(intrinsics.get("width", 0))
		height = int(intrinsics.get("height", 0))
	if width <= 0:
		width = int(metadata.get("recording_width", 0))
	if height <= 0:
		height = int(metadata.get("recording_height", 0))
	if width <= 0 or height <= 0:
		return {}
	return {
		"width": width,
		"height": height
	}


func _depth_confirmation_record(finalized: bool, media_path: String) -> Dictionary:
	var requested := _capture_enabled("record_depth")
	var saved_in_mp4 := requested and finalized and not media_path.is_empty() and _depth_mp4_write_count > 0
	var status := "pending"
	var reason := ""
	if finalized:
		if saved_in_mp4 and _depth_mp4_write_failed_count > 0:
			status = "partial"
			reason = _depth_last_mp4_write_error if not _depth_last_mp4_write_error.is_empty() else "one or more depth writes failed"
		elif saved_in_mp4:
			status = "saved"
		elif not requested:
			status = "disabled"
			reason = "record_depth disabled"
		elif media_path.is_empty():
			status = "missing"
			reason = "mp4 finalize failed"
		elif _depth_mp4_write_count <= 0:
			status = "missing"
			reason = "no successful depth frames accepted by mp4 muxer"
		else:
			status = "partial"
			reason = _depth_last_mp4_write_error if not _depth_last_mp4_write_error.is_empty() else "one or more depth writes failed"
	return {
		"requested": requested,
		"saved_in_mp4": saved_in_mp4,
		"status": status,
		"reason": reason,
		"finalized": finalized,
		"mp4_path": media_path,
		"mp4_write_count": _depth_mp4_write_count,
		"mp4_write_failed_count": _depth_mp4_write_failed_count,
		"sidecar_frame_count": _depth_sidecar_frame_count,
		"raw_dump_count": _depth_raw_index
	}


func write_head_pose(timestamp_ns: int, transform: Transform3D, tracking_valid: bool, _write_jsonl_sidecar: bool = true) -> void:
	# The mp4 `mett` head-pose stream is always fed at the caller's sample
	# rate via a fast JNI Enqueue (~50 µs). The JSONL sidecar (and its
	# throttle flag, kept here for signature compat) lives in
	# JsonlSidecarSink since WP5.
	if muxer_plugin != null:
		var q := transform.basis.get_rotation_quaternion()
		var p := transform.origin
		muxer_plugin.call(
			"writeHeadPose",
			timestamp_ns,
			p.x,
			p.y,
			p.z,
			q.x,
			q.y,
			q.z,
			q.w,
			tracking_valid
		)


func write_controller_pose(source: String, timestamp_ns: int, transform: Transform3D, tracking_valid: bool, _write_jsonl_sidecar: bool = true) -> void:
	if muxer_plugin != null:
		var q := transform.basis.get_rotation_quaternion()
		var p := transform.origin
		muxer_plugin.call(
			"writeControllerPose",
			source,
			timestamp_ns,
			p.x,
			p.y,
			p.z,
			q.x,
			q.y,
			q.z,
			q.w,
			tracking_valid
		)


func write_controller_input(
	controller: String,
	timestamp_ns: int,
	packet_type: int,
	available_mask: int,
	pressed_mask: int,
	touched_mask: int,
	changed_mask: int,
	trigger_value: float,
	grip_value: float,
	thumbstick: Vector2,
	trackpad: Vector2
) -> bool:
	if muxer_plugin == null:
		return false
	var result: Variant = muxer_plugin.call(
		"writeControllerInput",
		controller,
		timestamp_ns,
		packet_type,
		available_mask,
		pressed_mask,
		touched_mask,
		changed_mask,
		trigger_value,
		grip_value,
		thumbstick.x,
		thumbstick.y,
		trackpad.x,
		trackpad.y
	)
	return bool(result)


func write_depth_frame(
	timestamp_ns: int,
	eye: String,
	image_path: String,
	width: int,
	height: int,
	metadata: Dictionary,
	depth_u16_mm: PackedByteArray = PackedByteArray()
) -> void:
	if muxer_plugin != null and eye == "left" and depth_u16_mm.size() > 0:
		var fov: Dictionary = metadata.get("fov_tangent", {})
		var result: Variant = muxer_plugin.call(
			"writeDepthFrame",
			timestamp_ns,
			width,
			height,
			depth_u16_mm,
			float(fov.get("left", 0.0)),
			float(fov.get("right", 0.0)),
			float(fov.get("top", 0.0)),
			float(fov.get("bottom", 0.0))
		)
		var mp4_write_ok := bool(result)
		if mp4_write_ok:
			_depth_mp4_write_count += 1
			_write_muxer_metadata_json(
				"writeDepthFrameMetadataJson",
				timestamp_ns,
				_depth_metadata_record(timestamp_ns, eye, image_path, width, height, metadata)
			)
		else:
			_depth_mp4_write_failed_count += 1
			_depth_last_mp4_write_error = "writeDepthFrame returned false"
		# Capture the exact bytes confirmed by the muxer call, in the same order
		# as the mp4 depth frames, so verify_depth_ffv1.py can prove the FFV1
		# round-trip is bit-exact. Guarded by dump_raw_depth so production runs
		# pay nothing.
		if mp4_write_ok and not _depth_raw_dir.is_empty():
			var raw_file := FileAccess.open(
				"%s/frame_%05d.u16" % [_depth_raw_dir, _depth_raw_index], FileAccess.WRITE)
			if raw_file:
				raw_file.store_buffer(depth_u16_mm)
				raw_file.close()
				_depth_raw_index += 1
	# Counts every depth frame handed to the writer; feeds the manifest
	# stream_confirmations.depth.sidecar_frame_count with the same per-call
	# semantics as before WP5 (the depth/frames.jsonl line itself is written
	# by JsonlSidecarSink).
	_depth_sidecar_frame_count += 1


# Body joints and motion trackers are written by the hand_capture
# GDExtension's NativeBodyMotionWriter (HJNT payload + metadata JSON + JSONL
# sidecars, serialized in C++) — no GDScript write surface remains for them.


func ticks_us_to_session_us(ticks_us: int) -> int:
	return ticks_us - session_start_ticks_us


func get_session_dir() -> String:
	return session_dir


func get_session_dir_absolute() -> String:
	return _absolute_path(session_dir)


func get_output_mp4_path_absolute() -> String:
	return _absolute_path(output_mp4_path)


func get_partial_mp4_path_absolute() -> String:
	return _absolute_path(partial_mp4_path)


func get_saved_path() -> String:
	return saved_path


func set_android_plugin(plugin: Object) -> void:
	android_plugin = plugin


func set_muxer_plugin(plugin: Object) -> void:
	muxer_plugin = plugin


# Capture the body-tracking sampler's runtime snapshot just before close() so
# `_rewrite_manifest_with_media_integrity` can patch it into the on-disk
# manifest alongside the mp4 hash + bytes. Cleared by start_session() so a
# stale value from a prior session can't leak into the next.
func set_body_tracking_runtime_info(info: Dictionary) -> void:
	_body_tracking_runtime_info = info.duplicate(true) if info != null else {}


func get_session_start_unix_us() -> int:
	return session_start_unix_us


func get_session_start_ticks_us() -> int:
	return session_start_ticks_us


func _absolute_path(path: String) -> String:
	if path.begins_with("/"):
		return path
	return ProjectSettings.globalize_path(path)


func _write_muxer_metadata_json(method_name: String, timestamp_ns: int, record: Dictionary) -> bool:
	if muxer_plugin == null or _muxer_contract_version() < 5:
		return false
	var result: Variant = muxer_plugin.call(method_name, timestamp_ns, JSON.stringify(record))
	return true if result == null else bool(result)


func _muxer_contract_version() -> int:
	if muxer_plugin == null:
		return 0
	if _muxer_contract_version_cache >= 0:
		return _muxer_contract_version_cache
	# Do not use has_method() here: Godot 4's Android singleton reflection can
	# fail to enumerate @UsedByGodot methods even though direct call() works.
	var version: Variant = muxer_plugin.call("getMuxerContractVersion")
	_muxer_contract_version_cache = int(version) if (typeof(version) == TYPE_INT or typeof(version) == TYPE_FLOAT) else 0
	return _muxer_contract_version_cache


func _depth_metadata_record(
	timestamp_ns: int,
	eye: String,
	image_path: String,
	width: int,
	height: int,
	metadata: Dictionary
) -> Dictionary:
	return {
		"timestamp_ns": timestamp_ns,
		"eye": eye,
		"image_path": image_path,
		"width": width,
		"height": height,
		"metadata": _json_safe_value(metadata)
	}


func _json_safe_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var out := {}
			var dict := value as Dictionary
			for key in dict.keys():
				out[key] = _json_safe_value(dict[key])
			return out
		TYPE_ARRAY:
			var out: Array = []
			for item in value:
				out.append(_json_safe_value(item))
			return out
		TYPE_PACKED_BYTE_ARRAY:
			return "<bytes:%d>" % (value as PackedByteArray).size()
		TYPE_VECTOR2:
			var v2 := value as Vector2
			return {"x": v2.x, "y": v2.y}
		TYPE_VECTOR3:
			var v3 := value as Vector3
			return {"x": v3.x, "y": v3.y, "z": v3.z}
		TYPE_QUATERNION:
			var q := value as Quaternion
			return {"x": q.x, "y": q.y, "z": q.z, "w": q.w}
		TYPE_TRANSFORM3D:
			var t := value as Transform3D
			var q := t.basis.get_rotation_quaternion()
			return {
				"position": {"x": t.origin.x, "y": t.origin.y, "z": t.origin.z},
				"rotation": {"x": q.x, "y": q.y, "z": q.z, "w": q.w}
			}
		_:
			return value


func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(value, "\t"))
		file.close()


func _make_session_id() -> String:
	var dt := Time.get_datetime_dict_from_system(true)
	return "%04d%02d%02d_%02d%02d%02d" % [
		dt.year,
		dt.month,
		dt.day,
		dt.hour,
		dt.minute,
		dt.second
	]


func _make_dir(path: String) -> Error:
	var absolute := ProjectSettings.globalize_path(path)
	return DirAccess.make_dir_recursive_absolute(absolute)


func _capture_enabled(option: String) -> bool:
	# record_audio is privacy-sensitive (it opens the microphone) so the
	# default is OFF when the host did not explicitly request it. Every other
	# stream defaults ON for backward-compat with existing capture flows.
	if option == "record_audio":
		return bool(capture_options.get(option, false))
	return bool(capture_options.get(option, true))


# Mirror of the headset identity that the muxer writes into the mp4 moov/udta
# metadata, so the session manifest.json sidecar carries the same device_type
# (pico4_ultra / quest3 / quest3s / ...) without having to demux the mp4.
#
# When the Android plugin isn't wired up (desktop editor / unit tests / old
# plugin AAR without `getDeviceIdentityJson`), we leave the device fields
# blank and record the runtime OS name in a separate `runtime_os` slot. We
# explicitly do NOT shove `OS.get_name()` into `device_manufacturer` -- doing
# so would produce semantically wrong manifests like
# `{device_manufacturer: "Linux"}` that look plausible to downstream tooling.
func _resolve_device_identity() -> Dictionary:
	var identity := {
		"device_type": "",
		"device_model": "",
		"device_manufacturer": "",
		"device_build_device": "",
		"runtime_os": OS.get_name()
	}
	if android_plugin == null:
		push_warning("session_spool_writer: android_plugin not bound; manifest device fields will be blank")
		return identity
	# Skip has_method() guard: Godot 4's Android plugin reflection doesn't
	# consistently report @UsedByGodot methods through has_method(), and the
	# rest of this file already trusts plain .call() on android_plugin /
	# muxer_plugin. An old plugin AAR returns "" here, which we handle below.
	var raw: String = str(android_plugin.call("getDeviceIdentityJson"))
	if raw.is_empty():
		push_warning("session_spool_writer: getDeviceIdentityJson returned empty; old plugin AAR?")
		return identity
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("session_spool_writer: getDeviceIdentityJson did not return a JSON object: %s" % raw)
		return identity
	for key in ["device_type", "device_model", "device_manufacturer", "device_build_device"]:
		if parsed.has(key):
			identity[key] = str(parsed[key])
	return identity


# Maps the manifest-visible channel-layout label to its channel count. Mirrors
# com.spatialmp4.contract.AudioChannelLayout.channelCount on the JVM side.
func _audio_channel_count_for_layout(layout: String) -> int:
	match layout:
		"mono":
			return 1
		"stereo":
			return 2
		"foa_acn_sn3d", "raw_4ch":
			return 4
		_:
			return 2


func _effective_audio_layout_for_request(layout: String) -> String:
	match layout:
		"mono", "stereo":
			return layout
		"foa_acn_sn3d", "raw_4ch":
			# Current Android path uses AudioRecord MIC, which exposes mono/stereo
			# channel masks here. Keep the manifest aligned with the actual AAC
			# track metadata until a FOA/4-channel provider is wired up.
			return "stereo"
		_:
			return "stereo"
