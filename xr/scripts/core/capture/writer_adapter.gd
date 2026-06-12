## Thin writer interface consumed by CaptureSessionController (WP3). Concrete
## adapters (SpoolWriterAdapter, LiveWriterAdapter) wrap the existing writer
## scripts unchanged; the base class also carries a generic duck-typed
## implementation so both adapters stay byte-compatible with the pre-refactor
## direct writer calls in capture_app.gd.
##
## core/ dependency rule: this file must never reference vendor singleton
## names — plugin wiring stays in the wrapped writer + platform/ layer.
class_name CaptureWriterAdapter
extends RefCounted

var _writer: Object = null


func _init(writer_obj: Object = null) -> void:
	_writer = writer_obj


## The wrapped writer object (SessionSpoolWriter / LivePushWriter). Exposed so
## composition code (capture_app.gd) can keep using writer-specific accessors
## (get_session_dir_absolute, pop_metrics, set_*_plugin, ...) untouched.
func writer() -> Object:
	return _writer


func start_session(options: Dictionary) -> bool:
	if _writer == null:
		return false
	return bool(_writer.start_session(options))


func close() -> void:
	if _writer != null:
		_writer.close()


func session_dir() -> String:
	if _writer == null:
		return ""
	return str(_writer.get_session_dir())


## Mirrors the legacy fallback: get_saved_path() when available, else the
## session dir (identical to the pre-WP3 expression in stop_capture).
func saved_path() -> String:
	if _writer == null:
		return ""
	if _writer.has_method("get_saved_path"):
		return str(_writer.get_saved_path())
	return session_dir()


func set_body_tracking_runtime_info(info: Dictionary) -> void:
	if _writer != null and _writer.has_method("set_body_tracking_runtime_info"):
		_writer.set_body_tracking_runtime_info(info)
