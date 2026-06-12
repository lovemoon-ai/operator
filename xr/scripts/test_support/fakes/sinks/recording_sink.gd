class_name RecordingSink
extends SensorSink
## v2 test harness (WP7): records every received frame in memory and tracks
## per-type counters + timestamp monotonicity, the main observable sink for
## pipeline/capture integration tests.

var _accepted_types: Array = []
var frames: Array = []  # Array[SensorFrame] in arrival order
var received_by_type: Dictionary = {}  # frame_type -> count
var undeclared_frames: Array = []  # frames received outside accepted types
var non_monotonic_count := 0
var started := false
var stopped := false
var start_options: Dictionary = {}
var _last_timestamp_by_source: Dictionary = {}


func _init(accepted_types: Array = []) -> void:
	# Default: accept every canonical frame type.
	if accepted_types.is_empty():
		for type_id in range(SensorFrameType.CLOCK + 1):
			_accepted_types.append(type_id)
	else:
		_accepted_types = accepted_types.duplicate()


func accepted_frame_types() -> Array:
	return _accepted_types


func start(options: Dictionary) -> bool:
	started = true
	start_options = options.duplicate(true)
	return true


func stop() -> Dictionary:
	stopped = true
	return {"final_path": "", "frames_received": frames.size()}


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	if not accepts(frame.frame_type):
		# Invariant violation: the fanout routed a type we did not declare.
		undeclared_frames.append(frame)
	frames.append(frame)
	received_by_type[frame.frame_type] = int(received_by_type.get(frame.frame_type, 0)) + 1
	var stream_key := "%d/%s" % [frame.frame_type, frame.source_id]
	var last_ts := int(_last_timestamp_by_source.get(stream_key, 0))
	if frame.timestamp_ns < last_ts:
		non_monotonic_count += 1
	_last_timestamp_by_source[stream_key] = frame.timestamp_ns
	return true


func count(frame_type: int) -> int:
	return int(received_by_type.get(frame_type, 0))


func health() -> Dictionary:
	return {
		"frames_received": frames.size(),
		"undeclared_frames": undeclared_frames.size(),
		"non_monotonic_count": non_monotonic_count,
	}


func policy() -> Dictionary:
	return {"ordering": "ordered", "durability": "memory", "drop_policy": "none"}


## Invariants per the harness doc: declared types only + monotonic streams.
func invariant_failures() -> Array:
	var out: Array = []
	if not undeclared_frames.is_empty():
		out.append(OperatorTestFailure.create(
			"sink_undeclared_frame",
			"RecordingSink received %d frame(s) of undeclared types" % undeclared_frames.size()))
	if non_monotonic_count > 0:
		out.append(OperatorTestFailure.create(
			"sink_non_monotonic",
			"RecordingSink saw %d non-monotonic timestamp(s)" % non_monotonic_count))
	return out
