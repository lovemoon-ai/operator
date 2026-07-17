## CaptureWriterAdapter over the spool pipeline. It wraps SessionSpoolWriter
## (dirs, manifest, muxer, sha256) behind the CaptureWriterAdapter contract.
##
## Wraps an injected writer instance when provided (capture_app constructs
## the writer itself so all of its direct accessors keep working), or
## creates a fresh SessionSpoolWriter when used standalone (WP7 harness).
##
class_name SpoolWriterAdapter
extends CaptureWriterAdapter

const SessionSpoolWriterScript := preload("res://scripts/core/capture/session_spool_writer.gd")

func _init(writer_obj: Object = null) -> void:
	if writer_obj == null:
		writer_obj = SessionSpoolWriterScript.new()
	super(writer_obj)
