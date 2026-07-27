extends RefCounted
## Shared driver for the Inside Robot remote-retargeting device probes.
##
## Wraps the real `RemoteRetargeter` client and steps its poll loop by hand:
## the test runner calls `run()` synchronously, so the scene tree never gets a
## chance to deliver `_process` while a case is executing.
##
## Host requirements for any case using this probe:
##   pyoperator serve --service retargeting --port 8000
##   adb reverse tcp:8000 tcp:8000

const RemoteRetargeterScript := preload("res://scripts/teleop/retargeting/remote_retargeter.gd")

const HOST := "127.0.0.1"
const PORT := 8000
const TIMEOUT_MSEC := 15000
const STEP_MSEC := 10

var service_profile: Dictionary = {}
var faults: Array[Dictionary] = []

var _client: Node = null
var _results: Array[Dictionary] = []


## Connect and negotiate. Returns "" on success, or a human-readable reason.
func open(profile: Dictionary) -> String:
	_client = RemoteRetargeterScript.new()
	_client.service_ready.connect(_on_ready)
	_client.result_received.connect(_on_result)
	_client.faulted.connect(_on_fault)
	var err: int = _client.start({"host": HOST, "port": PORT, "profile": profile})
	if err != OK:
		return "client refused the connection config (error %d)" % err
	if _step_until(func() -> bool: return not service_profile.is_empty()):
		return ""
	return _reason(
		(
			"no handshake within %dms; start `pyoperator serve --service retargeting` "
			+ "and `adb reverse tcp:%d tcp:%d`"
		)
		% [TIMEOUT_MSEC, PORT, PORT]
	)


## Submit one frame and wait for its result. Empty dictionary means no result.
func solve(payload: Dictionary) -> Dictionary:
	_results.clear()
	_client.submit_payload(payload, Time.get_ticks_usec() * 1000)
	if _step_until(func() -> bool: return not _results.is_empty()):
		return _results[0]
	return {}


func reset_session() -> void:
	_client.reset()
	var deadline := Time.get_ticks_msec() + 200
	while Time.get_ticks_msec() < deadline:
		_client._process(float(STEP_MSEC) / 1000.0)
		OS.delay_msec(STEP_MSEC)


func close() -> void:
	if _client == null:
		return
	_client.stop()
	_client.free()
	_client = null


func fault_suffix() -> String:
	if faults.is_empty():
		return ""
	var first: Dictionary = faults[0]
	return " (%s: %s)" % [str(first.get("code", "")), str(first.get("message", ""))]


## One canonical joint record in the shape the XR body pipeline emits.
static func joint_record(position: Array) -> Dictionary:
	return {"valid": true, "pose": {"p": position, "q": [0.0, 0.0, 0.0, 1.0]}}


func _step_until(done: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		_client._process(float(STEP_MSEC) / 1000.0)
		if done.call():
			return true
		if not faults.is_empty():
			return false
		OS.delay_msec(STEP_MSEC)
	return false


func _reason(fallback: String) -> String:
	return fallback if faults.is_empty() else fault_suffix().strip_edges()


func _on_ready(profile: Dictionary) -> void:
	service_profile = profile.duplicate(true)


func _on_result(result: Dictionary) -> void:
	_results.append(result.duplicate(true))


func _on_fault(code: String, message: String) -> void:
	faults.append({"code": code, "message": message})
