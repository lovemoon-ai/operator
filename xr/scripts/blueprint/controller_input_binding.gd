extends Node3D
## No visible UI: a Blueprint-declared chord -> remote request -> matched ack.
signal action_triggered(action_id: StringName, request_id: Variant)
signal feedback_requested(pattern: String)

const Hold := preload("res://scripts/input/dual_trigger_hold.gd")
const GROUP := "operator_blueprint_input_binding"
const STATE_MAX_AGE_US := 1000000
var _hold := Hold.new()
var _left: XRController3D
var _right: XRController3D
var _active := false
var _available := false
var _required := true
var _message := ""
var _failure := ""
var _state_received_us := 0
var _pending_id := ""
var _pending_since_us := 0
var _ack_timeout_us := 3000000
var _source_ids: Array = []
var target_component := ""
var target_ready: Callable


func configure(properties: Dictionary, left: XRController3D, right: XRController3D) -> bool:
	if str(properties.get("gesture", "dual_trigger_hold")) != "dual_trigger_hold":
		return false
	_left = left
	_right = right
	_hold.hold_seconds = float(properties.get("hold_seconds", 1.0))
	_ack_timeout_us = int(float(properties.get("ack_timeout_seconds", 3.0)) * 1000000.0)
	target_component = str(properties.get("target_component", ""))
	return true


func _ready() -> void:
	add_to_group(GROUP)
	feedback_requested.connect(_play_feedback)


func set_active(value: bool) -> void:
	_active = value
	if not value:
		cancel()


func cancel() -> void:
	if not _pending_id.is_empty():
		_failure = tr("UI_RESET_ACK_TIMEOUT")
	_hold.reset()
	_pending_id = ""
	_pending_since_us = 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_RESUMED:
		cancel()


func set_bound_state(available: bool, required: bool, acknowledged_request: String, success: bool,
		message: String, received_us: int) -> void:
	_available = available
	_required = required
	_message = message
	_state_received_us = received_us
	if _pending_id.is_empty() or acknowledged_request != _pending_id:
		return
	# Old/replayed state can never acknowledge a new request; a late reply
	# after pause, tracking loss or timeout cannot vibrate a success either.
	var valid := _active and _controllers_tracked() and _fresh() and _source_signature() == _source_ids \
		and _now_us() - _pending_since_us <= _ack_timeout_us
	_pending_id = ""
	_pending_since_us = 0
	if not valid:
		_failure = tr("UI_RESET_ACK_TIMEOUT")
		return
	var accepted := success and not required
	_failure = "" if accepted else (message if not message.is_empty() else tr("UI_RESET_FAILED"))
	feedback_requested.emit("success" if accepted else "error")


func available() -> bool:
	return _active and _available and _fresh() \
		and (not target_ready.is_valid() or bool(target_ready.call(target_component)))


func _fresh() -> bool:
	return _state_received_us > 0 and _now_us() - _state_received_us <= STATE_MAX_AGE_US


func _now_us() -> int:
	return Time.get_ticks_usec()


func _source_signature() -> Array:
	var result: Array = []
	for controller in [_left, _right]:
		if not is_instance_valid(controller):
			return []
		var tracker := XRServer.get_tracker(controller.tracker)
		result.append(tracker.get_instance_id() if tracker != null else 0)
	return result


func _controllers_tracked() -> bool:
	if not is_instance_valid(_left) or not is_instance_valid(_right):
		return false
	var interaction := get_node_or_null("/root/OperatorInteraction")
	if interaction == null:
		return false
	for controller in [_left, _right]:
		if not controller.global_transform.is_finite() \
				or not bool(interaction.call("is_controller_source_active", controller)):
			return false
	return true


func sample_input() -> void:
	var tracked := _controllers_tracked()
	var now := _now_us()
	var source_ids: Array = _source_signature() if tracked else []
	if source_ids != _source_ids:
		cancel()
		_source_ids = source_ids
	if not tracked or not _active:
		cancel()
		return
	if not _pending_id.is_empty() and now - _pending_since_us > _ack_timeout_us:
		_pending_id = ""
		_failure = tr("UI_RESET_ACK_TIMEOUT")
		feedback_requested.emit("error")
	var request := _hold.advance(_left.get_float(&"trigger"), _right.get_float(&"trigger"),
		tracked, _active, _pending_id.is_empty(), now)
	if request:
		if not available():
			_failure = _message if not _message.is_empty() else tr("UI_RESET_FAILED")
			if not _fresh():
				_failure = tr("UI_RESET_ACK_TIMEOUT")
			elif target_ready.is_valid() and not bool(target_ready.call(target_component)):
				_failure = tr("UI_ROBOT_MODEL_LOADING")
			feedback_requested.emit("error")
			return
		# Strings preserve request identity through Godot's JSON float decoder.
		_pending_id = Crypto.new().generate_random_bytes(16).hex_encode()
		_pending_since_us = now
		_failure = ""
		action_triggered.emit(&"action", _pending_id)


func reserves_pointer() -> bool:
	if not _active or not _controllers_tracked():
		return false
	return _hold.reserved or (_left.get_float(&"trigger") >= Hold.PRESS and _right.get_float(&"trigger") >= Hold.PRESS)


func ui_status() -> Dictionary:
	return {
		"present": true,
		"required": _required or not _fresh() or not _failure.is_empty(),
		"pending": not _pending_id.is_empty() or _hold.started_us >= 0,
		"available": available(),
		"message": _failure if not _failure.is_empty() else _message,
		"target_component": target_component,
	}


func get_debug_state() -> String:
	var model_state := "none"
	var owner := get_parent()
	if owner != null and owner.has_method("component_node") and not target_component.is_empty():
		var model: Node3D = owner.call("component_node", target_component)
		if model != null:
			model_state = "ready=%s visible=%s fresh=%s error=%s" % [
				str(model.call("is_asset_ready")), str(model.is_visible_in_tree()),
				str(model.call("sample_is_fresh")), str(model.call("asset_error"))]
	return "active=%s tracked=%s available=%s remote_available=%s fresh=%s triggers=(%.2f,%.2f) armed=%s held_us=%d pending=%s required=%s model[%s]" % [
		str(_active), str(_controllers_tracked()), str(available()), str(_available), str(_fresh()),
		_left.get_float(&"trigger") if is_instance_valid(_left) else -1.0,
		_right.get_float(&"trigger") if is_instance_valid(_right) else -1.0,
		str(_hold.armed), _now_us() - _hold.started_us if _hold.started_us >= 0 else 0,
		str(not _pending_id.is_empty()), str(_required), model_state]


func _play_feedback(pattern: String) -> void:
	if not _active or not _controllers_tracked():
		return
	var haptics := get_node_or_null("/root/Haptics")
	if haptics != null:
		print("[BlueprintInput] haptic=%s physical_controllers=true" % pattern)
		haptics.call("fire_both", "connected" if pattern == "success" else "error", _left, _right)
