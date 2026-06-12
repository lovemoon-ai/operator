## CaptureWriterAdapter over the spool pipeline. Since WP5 this adapter is
## the composition of SpatialMp4Sink (SessionSpoolWriter engine: dirs,
## manifest, muxer, sha256) + JsonlSidecarSink (debug/replay sidecars). The
## lifecycle order is byte-compatible with the pre-WP5 monolithic writer:
##   start: writer.start_session (dirs + manifest) -> jsonl files open
##   close: jsonl files close -> writer.close (mp4 finalize + manifest
##          rewrite)
##
## Wraps an injected writer instance when provided (capture_app constructs
## the writer itself so all of its direct accessors keep working), or
## creates a fresh SessionSpoolWriter when used standalone (WP7 harness).
##
## The sidecar sink is duck-typed (core/ must stay below sinks/).
class_name SpoolWriterAdapter
extends CaptureWriterAdapter

const SessionSpoolWriterScript := preload("res://scripts/core/capture/session_spool_writer.gd")

# JsonlSidecarSink (or null). Injected by the composition root so the same
# instance also sits in the samplers' StreamBinding fanout.
var _jsonl_sink: Object = null


func _init(writer_obj: Object = null, jsonl_sink: Object = null) -> void:
	if writer_obj == null:
		writer_obj = SessionSpoolWriterScript.new()
	_jsonl_sink = jsonl_sink
	super(writer_obj)


func jsonl_sink() -> Object:
	return _jsonl_sink


func start_session(options: Dictionary) -> bool:
	if not super(options):
		return false
	if _jsonl_sink != null:
		_jsonl_sink.start_in_session(str(_writer.get_session_dir()), options)
	return true


func close() -> void:
	# Legacy order: sidecar files closed first, then the mp4 finalize +
	# manifest rewrite (previously both inside SessionSpoolWriter.close()).
	if _jsonl_sink != null:
		_jsonl_sink.stop()
	super()
