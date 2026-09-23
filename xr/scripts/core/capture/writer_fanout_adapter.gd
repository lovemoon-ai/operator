## CaptureWriterAdapter that drives several sink writers as one capture
## session, e.g. a local SpatialMP4 recording and an ingest push fed by the same
## sources. The first adapter is primary: the capture's session directory,
## saved path and start result are its own. A secondary writer that fails to
## start is reported and skipped, so a network outage never costs the user the
## local recording.
class_name WriterFanoutAdapter
extends CaptureWriterAdapter

var _adapters: Array = []
var _started: Array = []


func _init(adapters: Array = []) -> void:
	_adapters = adapters.filter(func(adapter: Variant) -> bool: return adapter != null)
	super((_adapters[0] as CaptureWriterAdapter).writer() if not _adapters.is_empty() else null)


func adapters() -> Array:
	return _adapters


func start_session(options: Dictionary) -> bool:
	_started = []
	for index in _adapters.size():
		var adapter := _adapters[index] as CaptureWriterAdapter
		if adapter.start_session(options):
			_started.append(adapter)
		elif index == 0:
			return false
		else:
			push_warning("Secondary capture writer failed to start; continuing without it")
	return true


func close() -> void:
	# Reverse order: the primary (local recording) finalizes last so a slow
	# network teardown cannot delay the file it already owns.
	for index in range(_started.size() - 1, -1, -1):
		(_started[index] as CaptureWriterAdapter).close()
	_started = []


func set_body_tracking_runtime_info(info: Dictionary) -> void:
	for adapter_v in _adapters:
		(adapter_v as CaptureWriterAdapter).set_body_tracking_runtime_info(info)
