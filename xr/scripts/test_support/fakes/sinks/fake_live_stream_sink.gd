class_name FakeLiveStreamSink
extends SensorSink
## v2 test harness (WP7): live-stream sink double simulating network ack,
## timeout, and disconnect without sockets.

const STATE_DISCONNECTED := "disconnected"
const STATE_CONNECTED := "connected"
const STATE_TIMED_OUT := "timed_out"

var connection_state := STATE_DISCONNECTED
var frames_sent := 0
var frames_acked := 0
var frames_dropped_disconnected := 0


func accepted_frame_types() -> Array:
	return [
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.INPUT_EVENT,
		SensorFrameType.HAND,
		SensorFrameType.DEPTH,
		SensorFrameType.CAMERA,
	]


func start(_options: Dictionary) -> bool:
	connection_state = STATE_CONNECTED
	return true


func stop() -> Dictionary:
	connection_state = STATE_DISCONNECTED
	return {"frames_sent": frames_sent, "frames_acked": frames_acked}


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	if connection_state != STATE_CONNECTED:
		frames_dropped_disconnected += 1
		return false
	frames_sent += 1
	return true


func simulate_ack(count := 1) -> void:
	frames_acked = mini(frames_acked + count, frames_sent)


func simulate_timeout() -> void:
	connection_state = STATE_TIMED_OUT


func simulate_disconnect() -> void:
	connection_state = STATE_DISCONNECTED


func simulate_reconnect() -> void:
	connection_state = STATE_CONNECTED


func health() -> Dictionary:
	return {
		"connection_state": connection_state,
		"frames_sent": frames_sent,
		"frames_acked": frames_acked,
		"frames_dropped_disconnected": frames_dropped_disconnected,
	}


func policy() -> Dictionary:
	return {"ordering": "ordered", "durability": "none", "drop_policy": "drop_new"}
