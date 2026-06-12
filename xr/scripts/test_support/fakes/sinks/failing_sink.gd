class_name FailingSink
extends SensorSink
## v2 test harness (WP7): fails after N accepted frames (and/or on demand)
## to exercise sink-failure isolation during recording.

var _accepted_types: Array = []
var fail_after := 3
var frames_received := 0
var failed := false
var last_error := ""


func _init(p_fail_after := 3, accepted_types: Array = []) -> void:
	fail_after = p_fail_after
	if accepted_types.is_empty():
		for type_id in range(SensorFrameType.CLOCK + 1):
			_accepted_types.append(type_id)
	else:
		_accepted_types = accepted_types.duplicate()


func accepted_frame_types() -> Array:
	return _accepted_types


## Force the failure immediately (driver command `fail_sink`).
func fail_now(reason := "forced failure") -> void:
	failed = true
	last_error = reason


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	if failed:
		return false
	frames_received += 1
	if frames_received >= fail_after:
		failed = true
		last_error = "failed after %d frames" % frames_received
		return false
	return true


func health() -> Dictionary:
	return {
		"frames_received": frames_received,
		"failed": failed,
		"last_error": last_error,
	}


func policy() -> Dictionary:
	return {"ordering": "ordered", "durability": "none", "drop_policy": "fail_fast"}
