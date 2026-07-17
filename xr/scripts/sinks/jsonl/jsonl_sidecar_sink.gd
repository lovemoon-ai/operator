class_name JsonlSidecarSink
extends SensorSink
## v2 sinks/jsonl (WP5): debug/replay JSONL sidecar writer extracted verbatim
## from session_spool_writer.gd. Filenames, directory layout, option gating
## and per-line JSON shapes are byte-identical to the pre-WP5 writer:
##
##   poses/head.jsonl              save_head_pose_sidecar && record_head_pose
##                                 (per-frame throttle via payload write_jsonl)
##   poses/controllers.jsonl       save_controller_hand_sidecar && record_controller_pose
##   depth/frames.jsonl            record_depth
##
## poses/hands.jsonl, body_motion/body_joints.jsonl and
## body_motion/motion_trackers.jsonl are NOT written here: the hand_capture
## GDExtension owns those pipelines in C++ and writes the sidecars itself on
## a background thread (NativeHandSampler / NativeBodyMotionWriter).
##
## Directory creation stays in SessionSpoolWriter.start_session() (it owns
## the session dir + manifest); this sink only opens files inside it.

var _capture_options: Dictionary = {}
var _session_dir := ""

var _head_file: FileAccess
var _controller_file: FileAccess
var _depth_file: FileAccess


func accepted_frame_types() -> Array:
	return [
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.DEPTH,
	]


## SensorSink.start: requires options["session_dir"] (set by
## SpoolWriterAdapter via start_in_session below).
func start(options: Dictionary) -> bool:
	return start_in_session(str(options.get("session_dir", "")), options)


func start_in_session(session_dir: String, options: Dictionary) -> bool:
	stop()
	_session_dir = session_dir
	_capture_options = options.duplicate(true)
	if _session_dir.is_empty():
		return false
	var save_head_pose_sidecar := bool(_capture_options.get("save_head_pose_sidecar", false))
	var save_controller_hand_sidecar := bool(_capture_options.get("save_controller_hand_sidecar", false))
	if save_head_pose_sidecar and _capture_enabled("record_head_pose"):
		_head_file = FileAccess.open(_session_dir.path_join(SessionLayout.HEAD_JSONL), FileAccess.WRITE)
	if save_controller_hand_sidecar and _capture_enabled("record_controller_pose"):
		_controller_file = FileAccess.open(_session_dir.path_join(SessionLayout.CONTROLLERS_JSONL), FileAccess.WRITE)
	if _capture_enabled("record_depth"):
		_depth_file = FileAccess.open(_session_dir.path_join(SessionLayout.DEPTH_FRAMES_JSONL), FileAccess.WRITE)
	return true


func stop() -> Dictionary:
	if _head_file:
		_head_file.close()
		_head_file = null
	if _controller_file:
		_controller_file.close()
		_controller_file = null
	if _depth_file:
		_depth_file.close()
		_depth_file = null
	return {"final_path": _session_dir}


func policy() -> Dictionary:
	return {
		"ordering": "in_order",
		"durability": "local_file",
		"drop_policy": "never",
	}


func health() -> Dictionary:
	return {
		"session_dir": _session_dir,
		"head_open": _head_file != null,
		"controller_open": _controller_file != null,
		"depth_open": _depth_file != null,
	}


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	var p := frame.payload
	match frame.frame_type:
		SensorFrameType.POSE:
			# Head JSONL is throttled by the sampler; the throttle decision
			# rides on the frame payload (legacy write_jsonl arg).
			if bool(p.get("write_jsonl", true)):
				_write_jsonl(_head_file, _pose_record(
					frame.timestamp_ns,
					"head",
					p.get("transform", Transform3D.IDENTITY) as Transform3D,
					bool(p.get("tracking_valid", false))
				))
			return null
		SensorFrameType.CONTROLLER:
			_write_jsonl(_controller_file, _pose_record(
				frame.timestamp_ns,
				frame.source_id,
				p.get("transform", Transform3D.IDENTITY) as Transform3D,
				bool(p.get("tracking_valid", false))
			))
			return null
		SensorFrameType.DEPTH:
			_write_jsonl(_depth_file, {
				"timestamp_ns": frame.timestamp_ns,
				"eye": str(p.get("eye", frame.source_id)),
				"image_path": str(p.get("image_path", "")),
				"width": int(p.get("width", 0)),
				"height": int(p.get("height", 0)),
				"metadata": p.get("metadata", {})
			})
			return null
	return null


func _capture_enabled(option: String) -> bool:
	if option == "record_audio":
		return bool(_capture_options.get(option, false))
	return bool(_capture_options.get(option, true))


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


func _write_jsonl(file: FileAccess, record: Dictionary) -> void:
	if file:
		file.store_line(JSON.stringify(record))
