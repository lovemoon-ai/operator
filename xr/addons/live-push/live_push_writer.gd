extends RefCounted
class_name LivePushWriter

const DEFAULT_SERVER_HOST := "127.0.0.1"
const DEFAULT_SERVER_PORT := 63910
const DEFAULT_QUEUE_FRAMES := 256
const PUSH_PLUGIN_SINGLETON := "LivePushPlugin"
const PUSH_PLUGIN_FALLBACK_SINGLETONS := ["LiveFeedServerPlugin", "LiveCaptureServerPlugin"]

var session_id := ""
var session_dir := ""
var output_mp4_path := ""
var partial_mp4_path := ""
var saved_path := ""
var last_endpoint := ""
var session_start_unix_us := 0
var session_start_ticks_us := 0
var capture_options: Dictionary = {}
var android_plugin: Object
var live_server_plugin: Object

var _server_host := DEFAULT_SERVER_HOST
var _server_port := DEFAULT_SERVER_PORT
var _auth_token := ""
var _max_queue_frames := DEFAULT_QUEUE_FRAMES


func configure_server(host: String, port: int, auth_token: String = "", max_queue_frames: int = DEFAULT_QUEUE_FRAMES) -> void:
	_server_host = host.strip_edges()
	if _server_host.is_empty():
		_server_host = DEFAULT_SERVER_HOST
	_server_port = clampi(port, 1, 65535)
	_auth_token = auth_token
	_max_queue_frames = clampi(max_queue_frames, 16, 2048)


func set_android_plugin(plugin: Object) -> void:
	android_plugin = plugin


func set_live_server_plugin(plugin: Object) -> void:
	live_server_plugin = plugin


func set_muxer_plugin(_plugin: Object) -> void:
	pass


func start_session(options: Dictionary = {}) -> bool:
	close()
	capture_options = options.duplicate(true)
	configure_server(
		str(capture_options.get("server_host", _server_host)),
		int(capture_options.get("server_port", _server_port)),
		str(capture_options.get("server_auth_token", _auth_token)),
		int(capture_options.get("server_queue_frames", _max_queue_frames))
	)
	if not _bind_live_plugin():
		push_error("LivePushPlugin singleton is not installed.")
		return false

	session_start_unix_us = Time.get_unix_time_from_system() * 1000000
	session_start_ticks_us = Time.get_ticks_usec()
	session_id = _make_session_id()
	saved_path = ""
	var root := "user://live_feed"
	session_dir = root.path_join(session_id)
	output_mp4_path = root.path_join("%s.mp4" % session_id)
	partial_mp4_path = root.path_join("%s.partial.mp4" % session_id)
	var absolute_dir := get_session_dir_absolute()
	var err := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if err != OK:
		push_error("Unable to prepare live feed working directory: %s" % absolute_dir)
		session_dir = ""
		return false

	var configured := bool(live_server_plugin.call(
		"configureServer",
		_server_host,
		_server_port,
		session_id,
		_auth_token,
		_max_queue_frames,
		int(capture_options.get("server_connect_timeout_ms", 2500))
	))
	if not configured:
		push_error("Live feed server sink could not be configured.")
		return false
	print("Live feed push configured: %s:%d session=%s" % [_server_host, _server_port, session_id])
	return true


func close() -> void:
	if live_server_plugin != null:
		var finish_method := "finishLiveFeed" if live_server_plugin.has_method("finishLiveFeed") else "finishLiveCapture"
		var result := str(live_server_plugin.call(finish_method))
		if not result.is_empty():
			last_endpoint = result
	saved_path = ""


func write_head_pose(timestamp_ns: int, transform: Transform3D, tracking_valid: bool, _write_metadata: bool = true) -> bool:
	if live_server_plugin == null:
		return false
	var q := transform.basis.get_rotation_quaternion()
	var p := transform.origin
	return bool(live_server_plugin.call(
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
	))


func write_controller_pose(source: String, timestamp_ns: int, transform: Transform3D, tracking_valid: bool, _write_metadata: bool = true) -> bool:
	if live_server_plugin == null:
		return false
	var q := transform.basis.get_rotation_quaternion()
	var p := transform.origin
	return bool(live_server_plugin.call(
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
	))


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
	if live_server_plugin == null:
		return false
	return bool(live_server_plugin.call(
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
	))


func write_depth_frame(
	timestamp_ns: int,
	_eye: String,
	_image_path: String,
	width: int,
	height: int,
	metadata: Dictionary,
	depth_u16_mm: PackedByteArray = PackedByteArray()
) -> void:
	if live_server_plugin == null or depth_u16_mm.is_empty():
		return
	var fov: Dictionary = metadata.get("fov_tangent", {})
	live_server_plugin.call(
		"writeDepthFrame",
		timestamp_ns,
		width,
		height,
		depth_u16_mm,
		float(fov.get("left", 0.0)),
		float(fov.get("right", 0.0)),
		float(fov.get("top", 0.0)),
		float(fov.get("bottom", 0.0)),
		JSON.stringify(metadata)
	)


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


func get_session_start_unix_us() -> int:
	return session_start_unix_us


func get_session_start_ticks_us() -> int:
	return session_start_ticks_us


func get_saved_path() -> String:
	return saved_path


func pop_metrics() -> Dictionary:
	if live_server_plugin == null:
		return {}
	var raw: Variant = live_server_plugin.call("popMetricsJson")
	if typeof(raw) != TYPE_STRING or String(raw).is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(String(raw))
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed as Dictionary
	return {}


func _bind_live_plugin() -> bool:
	if live_server_plugin != null:
		return true
	if Engine.has_singleton(PUSH_PLUGIN_SINGLETON):
		live_server_plugin = Engine.get_singleton(PUSH_PLUGIN_SINGLETON)
	else:
		for singleton in PUSH_PLUGIN_FALLBACK_SINGLETONS:
			if Engine.has_singleton(singleton):
				live_server_plugin = Engine.get_singleton(singleton)
				break
	return live_server_plugin != null


func _make_session_id() -> String:
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "").replace("-", "").replace(" ", "_")
	return "live_%s_%d" % [stamp, Time.get_ticks_usec() % 1000000]


func _absolute_path(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path
