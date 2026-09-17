class_name PicoTrackingCalibration
extends RefCounted
## Process-local USER confirmation, not automatic proof of system calibration.
## Requires a successful setup launch, return to the app and a separate click
## with live tracking available. No confirmation is saved across app launches.

var _confirmed := false
var _pending := false
var _launched := false
var _left_app := false
var _returned := false
var _focused := true
var _disconnect_epoch := -1
var _body_lost_epoch := -1
var revision := 0


func observe(continuity: Dictionary, runtime: Dictionary) -> Dictionary:
	var disconnected := int(runtime.get("tracker_disconnect_epoch", 0))
	var body_lost := int(continuity.get("body_lost_epoch", 0))
	if _disconnect_epoch >= 0 and disconnected != _disconnect_epoch:
		invalidate()
	if _body_lost_epoch >= 0 and body_lost != _body_lost_epoch:
		# Tracking can be interrupted by setup itself. Physical disconnect
		# events above still cancel an in-flight request.
		invalidate(not _pending)
	_disconnect_epoch = disconnected
	_body_lost_epoch = body_lost
	var available := bool(continuity.get("available", false)) and bool(runtime.get("session_created", false))
	var phase := "required"
	if not available:
		phase = "unavailable"
	elif _pending:
		phase = "confirming" if _launched and _returned else "calibrating"
	elif _confirmed:
		phase = "ready"
	return {"phase": phase, "confirmed": _confirmed and available,
		"pending": _pending, "revision": revision,
		"needs_confirmation": _pending and _launched and _returned,
		"can_confirm": _pending and _launched and _returned and _focused and available,
		"confirmation_source": "user" if _confirmed else ""}


func invalidate(cancel_pending: bool = true) -> void:
	_confirmed = false
	if cancel_pending:
		_pending = false
		_launched = false
		_left_app = false
		_returned = false
	revision += 1


func begin_calibration() -> void:
	_confirmed = false
	_pending = true
	_launched = false
	_left_app = false
	_returned = false
	revision += 1


func launch_failed() -> void:
	invalidate()


func launch_succeeded() -> void:
	if _pending:
		_launched = true
		revision += 1


func note_focus(focused: bool) -> void:
	var previous_focus := _focused
	_focused = focused
	if not _pending:
		return
	var previous := _returned
	if not focused:
		_left_app = true
	elif _left_app:
		_returned = true
	# Returning from calibration is a milestone. A later independent-tracker
	# setup dialog must not send the service back into full-body setup mode.
	if previous != _returned or previous_focus != _focused:
		revision += 1


func confirm(live_tracking_ready: bool) -> bool:
	if not _pending or not _launched or not _returned or not _focused or not live_tracking_ready:
		return false
	_confirmed = true
	_pending = false
	revision += 1
	return true
