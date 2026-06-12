class_name FakeBodyProvider
extends RefCounted
## v2 test harness (WP7): deterministic body-tracking source emitting
## canonical BodyFrame SensorFrames with a fixed synthetic skeleton.

var _clock: OperatorTestClock
var _joint_count := 24
var _runtime := "fake_body_runtime"
var _rate_hz := 60.0
var sequence := 0


func _init(clock: OperatorTestClock = null) -> void:
	_clock = clock if clock != null else OperatorTestClock.new()


func configure(fixture: Dictionary) -> void:
	_joint_count = int(fixture.get("joint_count", 24))
	_runtime = str(fixture.get("runtime", "fake_body_runtime"))
	_rate_hz = float(fixture.get("rate_hz", 60.0))
	sequence = 0


func next_frame() -> SensorFrame:
	_clock.advance_ns(int(round(1_000_000_000.0 / maxf(_rate_hz, 1.0))))
	sequence += 1
	var joints: Array = []
	for i in range(_joint_count):
		joints.append({
			"joint": i,
			"flags": 3,
			"position": [0.0, 0.05 * float(i), 0.0],
			"rotation": [0.0, 0.0, 0.0, 1.0],
		})
	var frame := BodyFrame.build(_clock.now_ticks_ns(), 3, joints, _runtime, {})
	frame.sequence = sequence
	return frame


func emit_into(sink: Object, count: int) -> Array:
	var emitted: Array = []
	for i in range(count):
		var frame := next_frame()
		sink.on_frame(frame)
		emitted.append(frame)
	return emitted
