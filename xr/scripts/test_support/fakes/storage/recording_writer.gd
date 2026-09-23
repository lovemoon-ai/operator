class_name RecordingWriter
extends RefCounted
## v2 test harness: stands in for SessionSpoolWriter / LivePushWriter behind a
## sink. Records every write call with the timestamp it received so tests can
## prove a SensorFrame's timestamp reaches the writer surface unchanged.

## Array of {"call": String, "timestamp_ns": int, "source": String}.
var calls: Array = []
var sessions_started := 0
var sessions_closed := 0
var server := {}


func configure_server(host: String, port: int, auth_token: String = "", _max_queue_frames: int = 0) -> void:
	server = {"host": host, "port": port, "auth_token": auth_token}


func start_session(_options: Dictionary = {}) -> bool:
	sessions_started += 1
	return true


func close() -> void:
	sessions_closed += 1


func get_session_dir() -> String:
	return "user://recording_writer"


func write_head_pose(timestamp_ns: int, _transform: Transform3D, _tracking_valid: bool, _write_metadata: bool = true) -> bool:
	calls.append({"call": "head_pose", "timestamp_ns": timestamp_ns, "source": "head"})
	return true


func write_controller_pose(source: String, timestamp_ns: int, _transform: Transform3D, _tracking_valid: bool, _write_metadata: bool = true) -> bool:
	calls.append({"call": "controller_pose", "timestamp_ns": timestamp_ns, "source": source})
	return true


func write_controller_input(
	controller: String,
	timestamp_ns: int,
	_packet_type: int,
	_available_mask: int,
	_pressed_mask: int,
	_touched_mask: int,
	_changed_mask: int,
	_trigger_value: float,
	_grip_value: float,
	_thumbstick: Vector2,
	_trackpad: Vector2
) -> bool:
	calls.append({"call": "controller_input", "timestamp_ns": timestamp_ns, "source": controller})
	return true


func write_depth_frame(
	timestamp_ns: int,
	eye: String,
	_image_path: String,
	_width: int,
	_height: int,
	_metadata: Dictionary,
	_depth_u16_mm: PackedByteArray = PackedByteArray()
) -> void:
	calls.append({"call": "depth", "timestamp_ns": timestamp_ns, "source": eye})


func timestamps() -> Array:
	var out: Array = []
	for call_v in calls:
		out.append(int((call_v as Dictionary).get("timestamp_ns", 0)))
	return out
