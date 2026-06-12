class_name FakePoseProvider
extends RefCounted
## v2 test harness (WP7): deterministic head-pose source. Emits canonical
## PoseFrame SensorFrames from fixture data + the injected OperatorTestClock.
##
## Fixture shape (fixtures/sensors/synthetic_walk_pose_stream.json):
## {"rate_hz": 60, "frames": [{"position": [x,y,z],
##  "rotation": [x,y,z,w], "valid": true}, ...]} — frames loop when the
## stream is stepped past its end.

var _clock: OperatorTestClock
var _frames: Array = []
var _rate_hz := 60.0
var _index := 0
var sequence := 0


func _init(clock: OperatorTestClock = null) -> void:
	_clock = clock if clock != null else OperatorTestClock.new()


func configure(fixture: Dictionary) -> void:
	_frames = fixture.get("frames", [])
	_rate_hz = float(fixture.get("rate_hz", 60.0))
	_index = 0
	sequence = 0


func frame_interval_ns() -> int:
	return int(round(1_000_000_000.0 / maxf(_rate_hz, 1.0)))


## Advance the clock by one frame interval and emit the next pose frame.
func next_frame() -> SensorFrame:
	var record: Dictionary = {}
	if not _frames.is_empty():
		record = _frames[_index % _frames.size()]
		_index += 1
	_clock.advance_ns(frame_interval_ns())
	sequence += 1
	var frame := PoseFrame.build(
		_clock.now_ticks_ns(),
		transform_from_record(record),
		bool(record.get("valid", true)))
	frame.sequence = sequence
	return frame


## Emit `count` frames into a sink/fanout (anything with on_frame()).
func emit_into(sink: Object, count: int) -> Array:
	var emitted: Array = []
	for i in range(count):
		var frame := next_frame()
		sink.on_frame(frame)
		emitted.append(frame)
	return emitted


static func transform_from_record(record: Dictionary) -> Transform3D:
	var position_v: Variant = record.get("position", [0.0, 1.6, 0.0])
	var rotation_v: Variant = record.get("rotation", [0.0, 0.0, 0.0, 1.0])
	var position := Vector3.ZERO
	if typeof(position_v) == TYPE_ARRAY and (position_v as Array).size() >= 3:
		var p := position_v as Array
		position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	var rotation := Quaternion.IDENTITY
	if typeof(rotation_v) == TYPE_ARRAY and (rotation_v as Array).size() >= 4:
		var q := rotation_v as Array
		rotation = Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])).normalized()
	return Transform3D(Basis(rotation), position)
