extends RefCounted
## Pure timing state machine used by the declarative input_binding primitive.
const PRESS := 0.75
const RELEASE := 0.35
const MAX_SAMPLE_GAP_US := 150000

var hold_seconds := 1.0
var armed := false
var reserved := false
var fired := false
var left_down := false
var right_down := false
var started_us := -1
var last_us := -1


func reset() -> void:
	armed = false
	reserved = false
	fired = false
	left_down = false
	right_down = false
	started_us = -1
	last_us = -1


func advance(left: float, right: float, tracked: bool, active: bool, available: bool, now_us: int) -> bool:
	if not tracked or not active or not is_finite(left) or not is_finite(right):
		reset()
		return false
	if last_us >= 0 and (now_us < last_us or now_us - last_us > MAX_SAMPLE_GAP_US):
		reset() # A stalled/lost frame cannot count toward a continuous hold.
	last_us = now_us
	left_down = left > RELEASE if left_down else left >= PRESS
	right_down = right > RELEASE if right_down else right >= PRESS
	if not left_down and not right_down:
		armed = true
		fired = false
		reserved = false
		started_us = -1
		return false
	if left_down and right_down:
		reserved = true
	else:
		started_us = -1
	if not available:
		armed = false
		started_us = -1
		return false
	if not (left_down and right_down) or not armed or fired:
		return false
	if started_us < 0:
		started_us = now_us
	if now_us - started_us < int(hold_seconds * 1000000.0):
		return false
	fired = true
	armed = false
	started_us = -1
	return true
