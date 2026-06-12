class_name OperatorTestClock
extends Timebase
## v2 test harness (WP7): deterministic manual-advance clock implementing
## the core/time Timebase interface. Fakes and drivers stamp SensorFrames
## from this clock so test inputs are fully reproducible.

var _now_ticks_ns := 1_000_000  # start non-zero so frames validate (>0)


func now_ticks_ns() -> int:
	return _now_ticks_ns


func set_now_ticks_ns(value_ns: int) -> void:
	_now_ticks_ns = value_ns


func advance_ns(delta_ns: int) -> int:
	_now_ticks_ns += delta_ns
	return _now_ticks_ns


func advance_seconds(delta_s: float) -> int:
	return advance_ns(int(round(delta_s * 1_000_000_000.0)))
