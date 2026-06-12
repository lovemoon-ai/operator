class_name FakeCaptureWriterAdapter
extends CaptureWriterAdapter
## v2 test harness (WP7): in-memory CaptureWriterAdapter so the
## CaptureSessionController state machine can run deterministically without
## SessionSpoolWriter / vendor muxers / device storage.

var fail_start := false
var sessions_started := 0
var sessions_closed := 0
var last_options: Dictionary = {}
var body_runtime_info: Dictionary = {}
var _session_dir := ""
var _open := false


func _init(session_dir := "user://test_tmp/fake_session") -> void:
	super._init(null)
	_session_dir = session_dir


func start_session(options: Dictionary) -> bool:
	if fail_start:
		return false
	sessions_started += 1
	last_options = options.duplicate(true)
	_open = true
	return true


func close() -> void:
	if _open:
		sessions_closed += 1
	_open = false


func is_open() -> bool:
	return _open


func session_dir() -> String:
	return _session_dir


func saved_path() -> String:
	return _session_dir


func set_body_tracking_runtime_info(info: Dictionary) -> void:
	body_runtime_info = info.duplicate(true)
