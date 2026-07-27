extends Node
## Runtime boundary for a Teleop embodiment. Inside targets own an in-headset
## robot and retargeting pipeline; outside targets own a robot-service link.

signal target_ready(descriptor: Dictionary)
signal stopped
signal state_changed(state: int, detail: String)
signal telemetry_received(data: Dictionary)
signal warning_raised(code: String, message: String)
signal faulted(code: String, message: String)

enum State {
	IDLE,
	STARTING,
	READY,
	ACTIVE,
	STOPPING,
	FAULTED,
}

var target_kind := ""
var state: State = State.IDLE
var descriptor: Dictionary = {}
var control_enabled := false


func start(_config: Dictionary) -> void:
	push_error("TeleopTarget.start must be implemented by a concrete target")


func stop() -> void:
	control_enabled = false
	_set_state(State.IDLE, "stopped")
	stopped.emit()


func reset() -> void:
	pass


func set_control_enabled(enabled: bool) -> void:
	control_enabled = enabled
	if enabled and state == State.READY:
		_set_state(State.ACTIVE, "control enabled")
	elif not enabled and state == State.ACTIVE:
		_set_state(State.READY, "control disabled")


func submit_operator_frame(_frame: Dictionary) -> Error:
	return ERR_UNAVAILABLE


## Nothing is running: no embodiment, no link, nothing to tear down.
func is_stopped() -> bool:
	return state == State.IDLE


func is_ready() -> bool:
	return state == State.READY or state == State.ACTIVE


func _set_state(next: State, detail := "") -> void:
	if state == next and detail.is_empty():
		return
	state = next
	state_changed.emit(state, detail)


func _fail(code: String, message: String) -> void:
	control_enabled = false
	_set_state(State.FAULTED, message)
	faulted.emit(code, message)
