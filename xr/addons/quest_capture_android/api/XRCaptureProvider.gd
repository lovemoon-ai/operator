class_name XRCaptureProvider
extends RefCounted
# Typed GDScript facade over the QuestCapturePlugin Android singleton. Pair
# with SpatialMP4Writer (from the spatialmp4_muxer addon) for full sessions:
#
#     var muxer := SpatialMP4Writer.new(); muxer.bind()
#     var provider := XRCaptureProvider.new(); provider.bind()
#     if not provider.bind_muxer(muxer):
#         push_error("muxer / provider contract mismatch")
#     provider.configure_spatialmp4_session(
#         "/sdcard/Movies/SpatialMP4/sess.mp4",
#         Time.get_unix_time_from_system() * 1_000_000,
#         Time.get_ticks_usec(),
#         /* stereo */ true,
#         /* fps   */ 30,
#         /* bps   */ 25_000_000,
#         /* recordDepth */ true,
#         /* recordHeadPose */ true,
#         /* recordControllerPose */ true,
#         /* recordHandData */ true,
#         /* recordControllerInput */ true,
#     )
#     provider.start_cameras()
#     # ... record ...
#     provider.stop_cameras()
#     muxer.finish()

signal camera_ready(left_id: String, right_id: String)
signal camera_frame_saved(eye: String, path: String, timestamp_ns: int)
signal error(message: String)

var _plugin: Object


# ---- bind / muxer wiring --------------------------------------------------

func bind() -> bool:
	# Resolve the QuestCapturePlugin Engine singleton and connect its signals
	# so the host listens to a single typed surface. Safe to call repeatedly.
	if _plugin != null:
		return true
	if not Engine.has_singleton("QuestCapturePlugin"):
		return false
	_plugin = Engine.get_singleton("QuestCapturePlugin")
	if _plugin.has_signal("camera_ready"):
		_plugin.connect("camera_ready", Callable(self, "_relay_camera_ready"))
	if _plugin.has_signal("camera_frame_saved"):
		_plugin.connect("camera_frame_saved", Callable(self, "_relay_camera_frame_saved"))
	if _plugin.has_signal("camera_error"):
		_plugin.connect("camera_error", Callable(self, "_relay_error"))
	return true


func singleton() -> Object:
	return _plugin


func bind_muxer(muxer: Object) -> bool:
	# `muxer` is the SpatialMp4MuxerPlugin Engine singleton (or a
	# SpatialMP4Writer.singleton() return value). The provider's Kotlin side
	# stores it as a SpatialDataSink so RGB packets bypass GDScript on the
	# per-frame path.
	if _plugin == null or muxer == null:
		return false
	return bool(_plugin.call("bindMuxer", muxer))


# ---- camera permissions / configuration -----------------------------------

func request_camera_permission() -> void:
	if _plugin != null:
		_plugin.call("requestCameraPermission")


func has_camera_permission() -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call("hasCameraPermission"))


func request_storage_permission() -> void:
	if _plugin != null:
		_plugin.call("requestStoragePermission")


func has_storage_permission() -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call("hasStoragePermission"))


func ensure_output_directory(path: String) -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call("ensureOutputDirectory", path))


func get_storage_usage_json(path: String) -> String:
	if _plugin == null:
		return "{}"
	return str(_plugin.call("getStorageUsageJson", path))


# ---- session configure / camera lifecycle ---------------------------------

func configure_spatialmp4_session(
	output_mp4_path: String,
	session_start_unix_us: int,
	session_start_godot_ticks_us: int,
	stereo_rgb: bool,
	rgb_fps: int,
	rgb_bitrate_bps: int,
	record_depth: bool,
	record_head_pose: bool,
	record_controller_pose: bool,
	record_hand_data: bool,
	record_controller_input: bool
) -> bool:
	# Forwards to the singleton's @UsedByGodot
	# `configureSpatialMp4SessionWithTime` -- the host gives us absolute paths
	# and clock anchors so the writer can run without GDScript on the hot
	# path.
	if _plugin == null:
		return false
	return bool(_plugin.call(
		"configureSpatialMp4SessionWithTime",
		output_mp4_path,
		session_start_unix_us,
		session_start_godot_ticks_us,
		stereo_rgb,
		rgb_fps,
		rgb_bitrate_bps,
		record_depth,
		record_head_pose,
		record_controller_pose,
		record_hand_data,
		record_controller_input
	))


func start_cameras() -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call("startCameras"))


func stop_cameras() -> void:
	if _plugin != null:
		_plugin.call("stopCameras")


# ---- clocks / metadata ----------------------------------------------------

func get_xr_time_to_godot_ticks_offset_ns() -> int:
	# Add this offset to any CLOCK_MONOTONIC-since-boot timestamp (e.g.
	# OpenXR XrTime) to bring it into the Godot ticks ns domain that every
	# stream's PTS uses. Returns 0 until the camera session is configured.
	if _plugin == null:
		return 0
	return int(_plugin.call("getXrTimeToGodotTicksOffsetNs"))


func get_left_camera_metadata_json() -> String:
	if _plugin == null:
		return "{}"
	return str(_plugin.call("getLeftCameraMetadataJson"))


func get_right_camera_metadata_json() -> String:
	if _plugin == null:
		return "{}"
	return str(_plugin.call("getRightCameraMetadataJson"))


# ---- depth conversion helper (Kotlin-side fast path) ----------------------

func convert_openxr_depth_rh_to_u16_mm(
	raw_d16_bytes: PackedByteArray,
	width: int,
	height: int,
	inv_proj_view_row3: PackedFloat64Array
) -> PackedByteArray:
	# Drop-in replacement for the GDScript inner loop in depth_sampler.gd's
	# fallback path. Runs the inverse-projection math in JVM primitives at
	# roughly 100x the GDScript speed; returns the resulting GRAY16LE
	# millimetre buffer.
	if _plugin == null:
		return PackedByteArray()
	var result: Variant = _plugin.call(
		"convertOpenxrDepthRhToU16Mm",
		raw_d16_bytes, width, height, inv_proj_view_row3
	)
	if result is PackedByteArray:
		return result
	return PackedByteArray()


# ---- metrics --------------------------------------------------------------

func pop_metrics_json() -> String:
	if _plugin == null:
		return "{}"
	return str(_plugin.call("popMetricsJson"))


# ---- signal relays --------------------------------------------------------

func _relay_camera_ready(left_id: String, right_id: String) -> void:
	emit_signal("camera_ready", left_id, right_id)


func _relay_camera_frame_saved(eye: String, path: String, timestamp_ns: int) -> void:
	emit_signal("camera_frame_saved", eye, path, timestamp_ns)


func _relay_error(message: String) -> void:
	emit_signal("error", message)
