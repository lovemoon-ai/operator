class_name FakeControllerProvider
extends RefCounted
## v2 test harness (WP7): deterministic controller input/pose source.
##
## Fixture shape (fixtures/sensors/synthetic_controller_grip_sequence.json):
## {"rate_hz": 30, "steps": [{"hand": "right",
##   "input": {"trigger_value": 0.0, "grip_value": 1.0,
##             "thumbstick": [x, y], "pressed_mask": 0}}, ...]}

var _clock: OperatorTestClock
var _steps: Array = []
var _rate_hz := 30.0
var _index := 0
var sequence := 0


func _init(clock: OperatorTestClock = null) -> void:
	_clock = clock if clock != null else OperatorTestClock.new()


func configure(fixture: Dictionary) -> void:
	_steps = fixture.get("steps", [])
	_rate_hz = float(fixture.get("rate_hz", 30.0))
	_index = 0
	sequence = 0


func steps() -> Array:
	return _steps


func frame_interval_ns() -> int:
	return int(round(1_000_000_000.0 / maxf(_rate_hz, 1.0)))


## Next input packet as a canonical INPUT_EVENT SensorFrame.
func next_input_frame() -> SensorFrame:
	var step: Dictionary = {}
	if not _steps.is_empty():
		step = _steps[_index % _steps.size()]
		_index += 1
	_clock.advance_ns(frame_interval_ns())
	sequence += 1
	var hand := str(step.get("hand", "right"))
	var state := input_state_from_step(step)
	var frame := ControllerFrame.build_input(
		"%s_controller" % hand,
		_clock.now_ticks_ns(),
		int(step.get("packet_type", 0)),
		state,
		int(step.get("changed_mask", 0)))
	frame.sequence = sequence
	return frame


func emit_into(sink: Object, count: int) -> Array:
	var emitted: Array = []
	for i in range(count):
		var frame := next_input_frame()
		sink.on_frame(frame)
		emitted.append(frame)
	return emitted


static func input_state_from_step(step: Dictionary) -> Dictionary:
	var input: Dictionary = step.get("input", {})
	var thumbstick_v: Variant = input.get("thumbstick", [0.0, 0.0])
	var thumbstick := Vector2.ZERO
	if typeof(thumbstick_v) == TYPE_ARRAY and (thumbstick_v as Array).size() >= 2:
		var ts := thumbstick_v as Array
		thumbstick = Vector2(float(ts[0]), float(ts[1]))
	return {
		"available_mask": int(input.get("available_mask", 0)),
		"pressed_mask": int(input.get("pressed_mask", 0)),
		"touched_mask": int(input.get("touched_mask", 0)),
		"trigger_value": float(input.get("trigger_value", 0.0)),
		"grip_value": float(input.get("grip_value", 0.0)),
		"thumbstick": thumbstick,
		"trackpad": Vector2.ZERO,
	}
