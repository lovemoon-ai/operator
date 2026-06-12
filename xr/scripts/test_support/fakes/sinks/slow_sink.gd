class_name SlowSink
extends SensorSink
## v2 test harness (WP7): simulates a slow consumer for backpressure tests.
## Instead of real blocking (which would stall the test runner), it accepts
## at most `capacity` queued frames per drain cycle and reports drops —
## deterministic backpressure without wall-clock sleeps.

var _accepted_types: Array = []
var capacity := 4
var queued: Array = []  # Array[SensorFrame]
var processed := 0
var dropped := 0


func _init(p_capacity := 4, accepted_types: Array = []) -> void:
	capacity = p_capacity
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
	if queued.size() >= capacity:
		dropped += 1
		return false
	queued.append(frame)
	return true


## Deterministic stand-in for the consumer catching up.
func drain(count := -1) -> int:
	var n := queued.size() if count < 0 else mini(count, queued.size())
	for i in range(n):
		queued.pop_front()
		processed += 1
	return n


func health() -> Dictionary:
	return {
		"queued": queued.size(),
		"processed": processed,
		"dropped": dropped,
		"capacity": capacity,
	}


func policy() -> Dictionary:
	return {"ordering": "ordered", "durability": "none", "drop_policy": "drop_new"}
