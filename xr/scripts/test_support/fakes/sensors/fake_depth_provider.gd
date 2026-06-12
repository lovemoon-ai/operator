class_name FakeDepthProvider
extends RefCounted
## v2 test harness (WP7): deterministic synthetic depth source. Emits
## DepthFrame SensorFrames with a flat synthetic depth plane (every pixel
## the same u16 millimetre value) so payload sizes/routing are testable
## without a real depth camera.

var _clock: OperatorTestClock
var _width := 8
var _height := 8
var _plane_depth_mm := 1500
var _rate_hz := 5.0
var sequence := 0


func _init(clock: OperatorTestClock = null) -> void:
	_clock = clock if clock != null else OperatorTestClock.new()


func configure(fixture: Dictionary) -> void:
	_width = int(fixture.get("width", 8))
	_height = int(fixture.get("height", 8))
	_plane_depth_mm = int(fixture.get("plane_depth_mm", 1500))
	_rate_hz = float(fixture.get("rate_hz", 5.0))
	sequence = 0


func next_frame(eye := "left") -> SensorFrame:
	_clock.advance_ns(int(round(1_000_000_000.0 / maxf(_rate_hz, 1.0))))
	sequence += 1
	var depth_u16 := PackedByteArray()
	depth_u16.resize(_width * _height * 2)
	for i in range(_width * _height):
		depth_u16.encode_u16(i * 2, _plane_depth_mm)
	var frame := DepthFrame.build(
		_clock.now_ticks_ns(), eye, _width, _height,
		{"source": "fake_depth_provider", "plane_depth_mm": _plane_depth_mm},
		depth_u16)
	frame.sequence = sequence
	return frame


func emit_into(sink: Object, count: int, eye := "left") -> Array:
	var emitted: Array = []
	for i in range(count):
		var frame := next_frame(eye)
		sink.on_frame(frame)
		emitted.append(frame)
	return emitted
