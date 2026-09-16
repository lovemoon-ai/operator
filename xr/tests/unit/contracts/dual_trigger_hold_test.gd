extends RefCounted
const CASE_ID := "contracts.dual_trigger_hold"
const Hold := preload("res://scripts/input/dual_trigger_hold.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var hold := Hold.new()
	# Held inputs at connection/resume never count as a fresh reset.
	for tick in range(15):
		t.is_false(hold.advance(1, 1, true, true, true, tick * 100000), "cached held triggers cannot reset")
	t.is_true(hold.reserved, "even an unarmed chord cannot click through to a menu")
	hold.advance(0, 0, true, true, true, 1500000)
	hold.advance(1, 0, true, true, true, 1600000)
	t.is_false(hold.advance(1, 1, true, true, true, 1700000), "second trigger starts the timer")
	for tick in range(1, 10):
		t.is_false(hold.advance(1, 1, true, true, true, 1700000 + tick * 100000), "less than one second cannot trigger")
	t.is_false(hold.advance(1, 1, true, true, true, 2699999), "one microsecond short cannot trigger")
	t.is_true(hold.advance(1, 1, true, true, true, 2700000), "exactly one second triggers once")
	for tick in range(1, 15):
		t.is_false(hold.advance(1, 1, true, true, true, 2700000 + tick * 100000), "continued holding cannot repeat")
	hold.advance(0, 1, true, true, true, 4200000)
	t.is_false(hold.advance(1, 1, true, true, true, 4300000), "releasing only one trigger cannot rearm after firing")
	hold.advance(0, 0, true, true, true, 4400000)
	t.is_false(hold.reserved, "releasing both returns pointer ownership")
	t.is_true(hold.armed, "both released rearms the gesture")
	hold.advance(1, 1, true, true, true, 4500000)
	hold.advance(0, 1, true, true, true, 4600000)
	t.eq(hold.started_us, -1, "one trigger release cancels an unfinished hold")
	hold.advance(1, 1, true, true, true, 4700000)
	hold.advance(1, 1, false, true, true, 4800000)
	t.is_false(hold.armed, "tracking loss disarms")
	hold.advance(0, 0, true, true, true, 4900000)
	hold.advance(1, 1, true, true, true, 5000000)
	t.is_false(hold.advance(1, 1, true, true, true, 7000000), "a render stall does not count as continuous tracked input")
	t.is_false(hold.armed, "stalled input must be released before rearming")
	hold.advance(0, 0, true, true, true, 7100000)
	hold.advance(1, 1, true, true, false, 7200000)
	t.is_true(hold.reserved, "unavailable reset still suppresses chord click-through")
	t.is_false(hold.advance(1, 1, true, true, true, 7300000), "availability recovery while held does not reset")
	hold.advance(0, 0, true, true, true, 7400000)
	hold.advance(1, 1, true, false, true, 7500000)
	t.is_false(hold.armed, "suspension cancels reset")
	t.is_false(hold.advance(NAN, 1, true, true, true, 7600000), "invalid trigger values cannot reset")
