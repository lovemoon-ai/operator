class_name PicoXRCaptureProvider
extends RefCounted

signal camera_ready(left_id: String, right_id: String)
signal camera_frame_saved(eye: String, path: String, timestamp_ns: int)
signal error(message: String)

var _plugin: Object


func bind() -> bool:
	if _plugin != null:
		return true
	if not Engine.has_singleton("PicoCapturePlugin"):
		return false
	_plugin = Engine.get_singleton("PicoCapturePlugin")
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
	if _plugin == null or muxer == null:
		return false
	return bool(_plugin.call("bindMuxer", muxer))


func open_video_in_system_player(path: String) -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call("openVideoInSystemPlayer", path))


func set_body_motion_capture_options(record_body_tracking: bool, record_motion_trackers: bool, max_motion_trackers: int = 2) -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call("setBodyMotionCaptureOptions", record_body_tracking, record_motion_trackers, max_motion_trackers))


func configure_spatialmp4_session(
	output_mp4_path: String,
	partial_mp4_path: String,
	sidecar_path: String,
	session_start_unix_us: int,
	session_start_godot_ticks_us: int,
	configure_godot_ticks_us: int,
	stereo_rgb: bool,
	rgb_fps: int,
	rgb_bitrate_bps: int,
	record_head_pose: bool,
	record_controller_pose: bool,
	record_hand_data: bool,
	record_controller_input: bool
) -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call(
		"configureSpatialMp4SessionWithTime",
		output_mp4_path,
		partial_mp4_path,
		sidecar_path,
		session_start_unix_us,
		session_start_godot_ticks_us,
		configure_godot_ticks_us,
		false,
		record_head_pose,
		record_controller_pose,
		record_hand_data,
		record_controller_input,
		stereo_rgb,
		rgb_bitrate_bps,
		rgb_fps
	))


func start_cameras() -> bool:
	return _plugin != null and bool(_plugin.call("startCameras"))


func stop_cameras() -> void:
	if _plugin != null:
		_plugin.call("stopCameras")


func get_xr_time_to_godot_ticks_offset_ns() -> int:
	if _plugin == null:
		return 0
	return int(_plugin.call("getXrTimeToGodotTicksOffsetNs"))


func pop_metrics_json() -> String:
	if _plugin == null:
		return "{}"
	return str(_plugin.call("popMetricsJson"))


func _relay_camera_ready(left_id: String, right_id: String) -> void:
	emit_signal("camera_ready", left_id, right_id)


func _relay_camera_frame_saved(eye: String, path: String, timestamp_ns: int) -> void:
	emit_signal("camera_frame_saved", eye, path, timestamp_ns)


func _relay_error(message: String) -> void:
	emit_signal("error", message)
