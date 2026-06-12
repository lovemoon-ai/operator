class_name NullSink
extends SensorSink
## v2 test harness (WP7): accepts frames and only reports counts.

var _accepted_types: Array = []
var frames_received := 0


func _init(accepted_types: Array = []) -> void:
	if accepted_types.is_empty():
		for type_id in range(SensorFrameType.CLOCK + 1):
			_accepted_types.append(type_id)
	else:
		_accepted_types = accepted_types.duplicate()


func accepted_frame_types() -> Array:
	return _accepted_types


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	frames_received += 1
	return true


func health() -> Dictionary:
	return {"frames_received": frames_received}


func policy() -> Dictionary:
	return {"ordering": "none", "durability": "none", "drop_policy": "accept_all"}
