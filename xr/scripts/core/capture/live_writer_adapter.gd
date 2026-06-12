## CaptureWriterAdapter over the existing LiveFeedNetworkWriter /
## LivePushWriter (unchanged). Live sessions have no finalized on-disk path;
## the adapter still reports saved_path() via the writer's own accessors so
## behavior matches the pre-WP3 direct calls (capture_app never reads the
## saved path in live-feed mode).
class_name LiveWriterAdapter
extends CaptureWriterAdapter

const LivePushWriterScript := preload("res://addons/live-push/live_push_writer.gd")


func _init(writer_obj: Object = null) -> void:
	if writer_obj == null:
		writer_obj = LivePushWriterScript.new()
	super(writer_obj)
