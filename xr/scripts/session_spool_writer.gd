extends RefCounted
class_name SessionSpoolWriter

const DEFAULT_CAPTURE_ROOT := "/sdcard/DCIM/SpatialMP4"
const HAND_JOINTS_MAGIC := 0x544E4A48 # "HJNT" in little-endian bytes.

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

var _head_file: FileAccess
var _controller_file: FileAccess
var _hand_file: FileAccess
var _depth_file: FileAccess
var _body_file: FileAccess
var _motion_file: FileAccess
# Debug-only: when capture option `dump_raw_depth` is true, every pre-encode
# depth payload is written here in capture order so the FFV1 mp4 track can be
# checked bit-for-bit offline (scripts/verify_depth_ffv1.py --reference).
var _depth_raw_dir := ""
var _depth_raw_index := 0


func start_session(options: Dictionary = {}) -> bool:
	close()
	capture_options = options.duplicate(true)
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
	sources["rgb"] = "Android Camera2 stereo side-by-side + HEVC MediaCodec" if _capture_enabled("stereo_rgb") else "Android Camera2 left camera + HEVC MediaCodec"
	if _capture_enabled("record_depth"):
		sources["depth"] = "OpenXRMetaEnvironmentDepthExtension converted to uint16 millimeters, FFV1 lossless (intra) in the mp4 depth track; PTS from OpenXR runtime_display_time_ns when available"
	if _capture_enabled("record_head_pose") or _capture_enabled("record_controller_pose") or _capture_enabled("record_hand_data"):
		sources["pose"] = "Godot OpenXR nodes and XRHandTracker; PTS from OpenXRMetaEnvironmentDepthExtensionWrapper.get_predicted_display_time_ns() when available, else Time.get_ticks_usec()"
	if _capture_enabled("record_body_tracking"):
		sources["body_tracking"] = "PICO OpenXR XR_BD_body_tracking joints in the mp4 mett track `spatialmp4:body_joints:body` (HJNT v1 layout; per-joint flags are XrSpaceLocationFlags low bits); XR_PICO_body_tracking2 state/velocity/acceleration plus frame-level body_flags are kept only in the optional body_motion/body_joints.jsonl sidecar (capture option save_body_sidecar)"
	if _capture_enabled("record_motion_trackers"):
		sources["motion_trackers"] = "PICO OpenXR XR_PICO_motion_tracking tracker poses, velocities, accelerations, battery state, and power-key events when available; stored as body_motion/motion_trackers.jsonl sidecar"
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
		"sources": sources,
		"device": _resolve_device_identity()
	})

	# Every pose stream (head, controllers, hands) flows into the MP4's `mett`
	# tracks via the muxer plugin -- the JSONL sidecars are debug-only mirrors.
	# Stage 5 made the head sidecar optional too (it used to be the only place
	# downstream tools could read pose data; SpatialMP4/scripts/read_mett_pose.py
	# now decodes the mp4 `mett:head` track directly, so the sidecar's only
	# remaining job is to feed the legacy SpatialMP4/scripts/godot_spool_pack.py
	# offline packer).
	var save_head_pose_sidecar := bool(capture_options.get("save_head_pose_sidecar", false))
	var save_controller_hand_sidecar := bool(capture_options.get("save_controller_hand_sidecar", false))
	if save_head_pose_sidecar and _capture_enabled("record_head_pose"):
		_head_file = FileAccess.open("%s/poses/head.jsonl" % session_dir, FileAccess.WRITE)
	if save_controller_hand_sidecar and _capture_enabled("record_controller_pose"):
		_controller_file = FileAccess.open("%s/poses/controllers.jsonl" % session_dir, FileAccess.WRITE)
	if save_controller_hand_sidecar and _capture_enabled("record_hand_data"):
		_hand_file = FileAccess.open("%s/poses/hands.jsonl" % session_dir, FileAccess.WRITE)
	if save_body_sidecar and _capture_enabled("record_body_tracking"):
		_body_file = FileAccess.open("%s/body_motion/body_joints.jsonl" % session_dir, FileAccess.WRITE)
	if _capture_enabled("record_motion_trackers"):
		_motion_file = FileAccess.open("%s/body_motion/motion_trackers.jsonl" % session_dir, FileAccess.WRITE)
	if _capture_enabled("record_depth"):
		_depth_file = FileAccess.open("%s/depth/frames.jsonl" % session_dir, FileAccess.WRITE)
	return true


func close() -> void:
	if _head_file:
		_head_file.close()
		_head_file = null
	if _controller_file:
		_controller_file.close()
		_controller_file = null
	if _hand_file:
		_hand_file.close()
		_hand_file = null
	if _depth_file:
		_depth_file.close()
		_depth_file = null
	if _body_file:
		_body_file.close()
		_body_file = null
	if _motion_file:
		_motion_file.close()
		_motion_file = null
	var attempted_native_finish := muxer_plugin != null
	if muxer_plugin != null:
		var finalized: String = str(muxer_plugin.call("finishSpatialMp4"))
		if not finalized.is_empty():
			saved_path = finalized
	if saved_path.is_empty() and not attempted_native_finish and not output_mp4_path.is_empty():
		saved_path = output_mp4_path

	# Compute SHA-256 of the finalized mp4 and patch it into the
	# manifest. The ingest server uses this to detect transit corruption
	# (proxy bug, half-PATCH on flaky Wi-Fi that somehow still satisfied
	# Content-Length, etc.). Hashing a 100 MB mp4 takes ~200 ms on the
	# Quest 3, well inside the post-stop UX budget — the user already
	# sees the "Saved" toast while we run.
	if not saved_path.is_empty():
		var media_hash := _compute_file_sha256(saved_path)
		if not media_hash.is_empty():
			_rewrite_manifest_with_media_integrity(saved_path, media_hash)
		else:
			push_warning("session_spool_writer: sha256 compute failed for %s" % saved_path)


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


# Rewrite manifest.json in place to add the freshly-computed media
# hash + size + filename under `artifacts.media`. We keep the original
# top-level fields untouched so any v3 reader that doesn't know about
# `artifacts` keeps working — this is purely additive.
func _rewrite_manifest_with_media_integrity(media_path: String, media_sha256: String) -> void:
	var manifest_path := "%s/manifest.json" % session_dir
	var reader := FileAccess.open(manifest_path, FileAccess.READ)
	if reader == null:
		push_warning("session_spool_writer: manifest missing at %s; skipping integrity rewrite" % manifest_path)
		return
	var text := reader.get_as_text()
	reader.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("session_spool_writer: manifest at %s is not a JSON object; skipping integrity rewrite" % manifest_path)
		return
	var manifest: Dictionary = parsed
	var media_bytes := 0
	var size_probe := FileAccess.open(media_path, FileAccess.READ)
	if size_probe != null:
		media_bytes = int(size_probe.get_length())
		size_probe.close()
	var artifacts_field: Variant = manifest.get("artifacts", {})
	var artifacts: Dictionary = artifacts_field if artifacts_field is Dictionary else {}
	artifacts["media"] = {
		"filename": media_path.get_file(),
		"bytes": media_bytes,
		"sha256": media_sha256,
		"hash_algo": "sha256",
	}
	manifest["artifacts"] = artifacts
	_write_json(manifest_path, manifest)


func write_head_pose(timestamp_ns: int, transform: Transform3D, tracking_valid: bool, write_jsonl: bool = true) -> void:
	# The mp4 `mett` head-pose stream is always fed at the caller's sample
	# rate via a fast JNI Enqueue (~50 µs). The GDScript-side JSONL is far
	# more expensive (Dictionary + JSON.stringify + FileAccess.store_line ~
	# 150-200 µs each) and is throttled by the caller via write_jsonl=false
	# to keep the main thread responsive at the XR refresh rate.
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
	if write_jsonl:
		_write_jsonl(_head_file, _pose_record(timestamp_ns, "head", transform, tracking_valid))


func write_controller_pose(source: String, timestamp_ns: int, transform: Transform3D, tracking_valid: bool, write_jsonl: bool = true) -> void:
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
	if write_jsonl:
		_write_jsonl(_controller_file, _pose_record(timestamp_ns, source, transform, tracking_valid))


func write_hand_joints(hand: String, timestamp_ns: int, joints: Array) -> void:
	if muxer_plugin != null and not joints.is_empty():
		muxer_plugin.call("writeHandJointsPayload", hand, timestamp_ns, _pack_hand_joints_payload(joints))
	_write_jsonl(_hand_file, {
		"timestamp_ns": timestamp_ns,
		"hand": hand,
		"joint_count": joints.size(),
		"joints": joints
	})


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
		muxer_plugin.call(
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
		# Capture the exact bytes handed to the encoder, in the same order as the
		# mp4 depth frames, so verify_depth_ffv1.py can prove the FFV1 round-trip
		# is bit-exact. Guarded by dump_raw_depth so production runs pay nothing.
		if not _depth_raw_dir.is_empty():
			var raw_file := FileAccess.open(
				"%s/frame_%05d.u16" % [_depth_raw_dir, _depth_raw_index], FileAccess.WRITE)
			if raw_file:
				raw_file.store_buffer(depth_u16_mm)
				raw_file.close()
				_depth_raw_index += 1
	var record := {
		"timestamp_ns": timestamp_ns,
		"eye": eye,
		"image_path": image_path,
		"width": width,
		"height": height,
		"metadata": metadata
	}
	_write_jsonl(_depth_file, record)


func write_body_joints(timestamp_ns: int, body_flags: int, joints: Array, metadata: Dictionary = {}) -> bool:
	if joints.is_empty():
		return false
	# The mp4 `mett:body_joints` track is the primary store: the joint dicts
	# share the {joint, flags, radius_m, position, rotation} shape with hand
	# joints, so the HJNT packer is reused verbatim. The JSONL sidecar is
	# opt-in (capture option save_body_sidecar) and is the only place the
	# frame-level body_flags + PICO velocity/acceleration extras survive.
	var wrote := false
	if muxer_plugin != null:
		muxer_plugin.call("writeBodyJointsPayload", timestamp_ns, _pack_hand_joints_payload(joints))
		wrote = true
	if _body_file != null:
		var json_joints: Array = []
		for joint in joints:
			if typeof(joint) == TYPE_DICTIONARY:
				json_joints.append(_json_safe_joint_record(joint))
		var record := {
			"timestamp_ns": timestamp_ns,
			"body_flags": body_flags,
			"joint_count": json_joints.size(),
			"joints": json_joints
		}
		for key in metadata.keys():
			if key == "joints" or key == "transform":
				continue
			record[key] = _json_safe_value(metadata[key])
		_write_jsonl(_body_file, record)
		wrote = true
	return wrote


func write_motion_tracker_pose(
	tracker_index: int,
	source: String,
	timestamp_ns: int,
	transform: Transform3D,
	tracking_valid: bool,
	metadata: Dictionary = {}
) -> bool:
	if _motion_file == null:
		return false
	var record := _pose_record(timestamp_ns, source, transform, tracking_valid)
	record["tracker_index"] = tracker_index
	for key in metadata.keys():
		if key == "transform" or key == "position" or key == "rotation" or key == "tracker_index":
			continue
		record[key] = _json_safe_value(metadata[key])
	_write_jsonl(_motion_file, record)
	return true


func write_motion_tracker_event(timestamp_ns: int, event_type: String, event: Dictionary) -> bool:
	if _motion_file == null:
		return false
	_write_jsonl(_motion_file, {
		"timestamp_ns": timestamp_ns,
		"event_type": event_type,
		"event": _json_safe_value(event)
	})
	return true


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


func get_session_start_unix_us() -> int:
	return session_start_unix_us


func get_session_start_ticks_us() -> int:
	return session_start_ticks_us


func _absolute_path(path: String) -> String:
	if path.begins_with("/"):
		return path
	return ProjectSettings.globalize_path(path)


func _pose_record(timestamp_ns: int, source: String, transform: Transform3D, tracking_valid: bool) -> Dictionary:
	var q := transform.basis.get_rotation_quaternion()
	var p := transform.origin
	return {
		"timestamp_ns": timestamp_ns,
		"source": source,
		"tracking_valid": tracking_valid,
		"position": {"x": p.x, "y": p.y, "z": p.z},
		"rotation": {"x": q.x, "y": q.y, "z": q.z, "w": q.w}
	}


func _json_safe_joint_record(joint_record: Dictionary) -> Dictionary:
	var out := {}
	for key in joint_record.keys():
		if key == "transform":
			continue
		out[key] = _json_safe_value(joint_record[key])
	return out


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


func _pack_hand_joints_payload(joints: Array) -> PackedByteArray:
	var payload := PackedByteArray()
	payload.resize(8 + joints.size() * 36)
	var offset := 0
	payload.encode_u32(offset, HAND_JOINTS_MAGIC)
	offset += 4
	payload.encode_u16(offset, 1)
	offset += 2
	payload.encode_u16(offset, joints.size())
	offset += 2
	for joint_record in joints:
		var position: Dictionary = joint_record.get("position", {})
		var rotation: Dictionary = joint_record.get("rotation", {})
		payload.encode_u16(offset, int(joint_record.get("joint", 0)))
		offset += 2
		payload.encode_u16(offset, int(joint_record.get("flags", 0)))
		offset += 2
		payload.encode_float(offset, float(joint_record.get("radius_m", 0.0)))
		offset += 4
		payload.encode_float(offset, float(position.get("x", 0.0)))
		offset += 4
		payload.encode_float(offset, float(position.get("y", 0.0)))
		offset += 4
		payload.encode_float(offset, float(position.get("z", 0.0)))
		offset += 4
		payload.encode_float(offset, float(rotation.get("x", 0.0)))
		offset += 4
		payload.encode_float(offset, float(rotation.get("y", 0.0)))
		offset += 4
		payload.encode_float(offset, float(rotation.get("z", 0.0)))
		offset += 4
		payload.encode_float(offset, float(rotation.get("w", 1.0)))
		offset += 4
	return payload


func _write_jsonl(file: FileAccess, record: Dictionary) -> void:
	if file:
		file.store_line(JSON.stringify(record))


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
