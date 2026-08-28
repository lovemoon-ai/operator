class_name PalmMenuVisibilityState
extends RefCounted

const FACING_ENTER_THRESHOLD := 0.72
const FACING_EXIT_THRESHOLD := 0.55
const OPEN_ENTER_THRESHOLD := 0.72
const OPEN_EXIT_THRESHOLD := 0.55
const SHOW_STABLE_SEC := 0.18
const HIDE_STABLE_SEC := 0.12

var visible := false
var _show_elapsed := 0.0
var _hide_elapsed := 0.0


func update(tracked: bool, facing: float, openness: float, delta: float) -> bool:
	var elapsed := maxf(delta, 0.0)
	if not tracked:
		reset()
		return false

	if visible:
		_show_elapsed = 0.0
		if meets_exit_pose(facing, openness):
			_hide_elapsed = 0.0
		else:
			_hide_elapsed += elapsed
			if _hide_elapsed >= HIDE_STABLE_SEC:
				visible = false
				_hide_elapsed = 0.0
	else:
		_hide_elapsed = 0.0
		if meets_enter_pose(facing, openness):
			_show_elapsed += elapsed
			if _show_elapsed >= SHOW_STABLE_SEC:
				visible = true
				_show_elapsed = 0.0
		else:
			_show_elapsed = 0.0
	return visible


func reset() -> void:
	visible = false
	_show_elapsed = 0.0
	_hide_elapsed = 0.0


static func meets_enter_pose(facing: float, openness: float) -> bool:
	return facing >= FACING_ENTER_THRESHOLD and openness >= OPEN_ENTER_THRESHOLD


static func meets_exit_pose(facing: float, openness: float) -> bool:
	return facing >= FACING_EXIT_THRESHOLD and openness >= OPEN_EXIT_THRESHOLD
