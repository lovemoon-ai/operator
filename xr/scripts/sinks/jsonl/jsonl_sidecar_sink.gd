class_name JsonlSidecarSink
extends SensorSink
## v2 sinks/jsonl (WP5): debug/replay JSONL sidecar writer extracted verbatim
## from session_spool_writer.gd. Filenames, directory layout, option gating
## and per-line JSON shapes are byte-identical to the pre-WP5 writer:
##
##   poses/head.jsonl              save_head_pose_sidecar && record_head_pose
##                                 (per-frame throttle via payload write_jsonl)
##   poses/controllers.jsonl       save_controller_hand_sidecar && record_controller_pose
##   poses/hands.jsonl             save_controller_hand_sidecar && record_hand_data
##   body_motion/body_joints.jsonl save_body_sidecar && record_body_tracking
##   body_motion/motion_trackers.jsonl  record_motion_trackers
##   depth/frames.jsonl            record_depth
##
## Directory creation stays in SessionSpoolWriter.start_session() (it owns
## the session dir + manifest); this sink only opens files inside it.

var _capture_options: Dictionary = {}
var _session_dir := ""

var _head_file: FileAccess
var _controller_file: FileAccess
var _hand_file: FileAccess
var _body_file: FileAccess
var _motion_file: FileAccess
var _depth_file: FileAccess


func accepted_frame_types() -> Array:
	return [
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.HAND,
		SensorFrameType.BODY,
		SensorFrameType.DEPTH,
		SensorFrameType.MOTION_TRACKER,
	]


## Legacy guard surface (body_motion_sampler checks the frame sink for it;
## StreamBinding forwards). The spool pipeline always supported motion
## tracker events — whether anything is written depends on the option-gated
## motion file, exactly as before.
func supports_motion_tracker_events() -> bool:
	return true


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
	var save_body_sidecar := bool(_capture_options.get("save_body_sidecar", false))
	if save_head_pose_sidecar and _capture_enabled("record_head_pose"):
		_head_file = FileAccess.open(_session_dir.path_join(SessionLayout.HEAD_JSONL), FileAccess.WRITE)
	if save_controller_hand_sidecar and _capture_enabled("record_controller_pose"):
		_controller_file = FileAccess.open(_session_dir.path_join(SessionLayout.CONTROLLERS_JSONL), FileAccess.WRITE)
	if save_controller_hand_sidecar and _capture_enabled("record_hand_data"):
		_hand_file = FileAccess.open(_session_dir.path_join(SessionLayout.HANDS_JSONL), FileAccess.WRITE)
	if save_body_sidecar and _capture_enabled("record_body_tracking"):
		_body_file = FileAccess.open(_session_dir.path_join(SessionLayout.BODY_JOINTS_JSONL), FileAccess.WRITE)
	if _capture_enabled("record_motion_trackers"):
		_motion_file = FileAccess.open(_session_dir.path_join(SessionLayout.MOTION_TRACKERS_JSONL), FileAccess.WRITE)
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
	if _hand_file:
		_hand_file.close()
		_hand_file = null
	if _body_file:
		_body_file.close()
		_body_file = null
	if _motion_file:
		_motion_file.close()
		_motion_file = null
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
		"hand_open": _hand_file != null,
		"body_open": _body_file != null,
		"motion_open": _motion_file != null,
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
		SensorFrameType.HAND:
			var joints: Array = p.get("joints", [])
			_write_jsonl(_hand_file, {
				"timestamp_ns": frame.timestamp_ns,
				"hand": str(p.get("hand", frame.source_id)),
				"joint_count": joints.size(),
				"joints": joints
			})
			return null
		SensorFrameType.BODY:
			return _write_body_joints(
				frame.timestamp_ns,
				int(p.get("body_flags", 0)),
				p.get("joints", []) as Array,
				p.get("metadata", {}) as Dictionary
			)
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
		SensorFrameType.MOTION_TRACKER:
			if MotionTrackerFrame.is_event(frame):
				return _write_motion_tracker_event(
					frame.timestamp_ns,
					str(p.get("event_type", "")),
					p.get("event", {}) as Dictionary
				)
			return _write_motion_tracker_pose(
				int(p.get("tracker_index", 0)),
				frame.source_id,
				frame.timestamp_ns,
				p.get("transform", Transform3D.IDENTITY) as Transform3D,
				bool(p.get("tracking_valid", false)),
				p.get("metadata", {}) as Dictionary
			)
	return null


## Legacy return semantics: true when the body sidecar accepted the record
## (joints non-empty and the sidecar file is open). The mp4 half of the old
## write_body_joints OR lives in SpatialMp4Sink; StreamBinding ORs them.
func _write_body_joints(timestamp_ns: int, body_flags: int, joints: Array, metadata: Dictionary) -> bool:
	if joints.is_empty():
		return false
	if _body_file == null:
		return false
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
	return true


func _write_motion_tracker_pose(
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


func _write_motion_tracker_event(timestamp_ns: int, event_type: String, event: Dictionary) -> bool:
	if _motion_file == null:
		return false
	_write_jsonl(_motion_file, {
		"timestamp_ns": timestamp_ns,
		"event_type": event_type,
		"event": _json_safe_value(event)
	})
	return true


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


func _write_jsonl(file: FileAccess, record: Dictionary) -> void:
	if file:
		file.store_line(JSON.stringify(record))
