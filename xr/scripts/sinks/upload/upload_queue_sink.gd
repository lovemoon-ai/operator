class_name UploadQueueSink
extends SensorSink
## v2 sinks/upload (WP5): durable upload queue behind the SensorSink
## contract. Wraps the existing EgoUploader Node unchanged — same queue file
## (user://ego_upload_queue.json), TUS resume behavior, backoff, and
## signals. The composition root owns the uploader's scene-tree lifecycle
## (add_child / signal wiring); this sink owns the session hand-off surface.
##
## Consumes no per-sample frames: its input is finalized session artifacts.

const EgoUploaderScript := preload("res://scripts/ego_uploader.gd")

var _uploader: Node


func _init(uploader: Node = null) -> void:
	_uploader = uploader if uploader != null else EgoUploaderScript.new()


## The wrapped EgoUploader node (signals, pending_jobs, cancel, ... stay
## reachable for UI glue).
func uploader() -> Node:
	return _uploader


func accepted_frame_types() -> Array:
	return []


func pause() -> void:
	if _uploader != null:
		_uploader.pause()


func resume() -> void:
	if _uploader != null:
		_uploader.resume()


## Hand a finalized session to the durable queue. Mirrors
## EgoUploader.enqueue (cheap O(1) main-thread append).
func enqueue_session(session_dir: String, mp4_path: String, options: Dictionary) -> bool:
	if _uploader == null:
		return false
	return bool(_uploader.enqueue(session_dir, mp4_path, options))


func prioritize(session_id: String) -> bool:
	if _uploader == null or not _uploader.has_method("prioritize"):
		return false
	return bool(_uploader.prioritize(session_id))


func policy() -> Dictionary:
	return {
		"ordering": "queue",
		"durability": "persistent_queue",
		"drop_policy": "never",
	}


func health() -> Dictionary:
	return {"uploader_bound": _uploader != null}
