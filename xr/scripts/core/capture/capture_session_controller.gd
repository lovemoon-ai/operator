## Capture session state machine (v2 architecture, WP3).
##
## Owns the recording lifecycle: permission/storage check -> writer
## start_session() -> sampler set_capture_options() -> RUNNING; stop ->
## stop-chain (samplers etc.) -> writer close() -> STOPPED -> IDLE. All state
## changes go through the CaptureState legal-transition table; illegal
## requests return an error result and never crash.
##
## The controller is composition-agnostic: deps are injected (writer adapter,
## permission check Callable, samplers, stop chain), no vendor singletons, no
## scene-tree access, no prints of product logcat markers — those stay in the
## composition root (capture_app.gd) via the signals below so the existing
## "Capture session started/stopped:" lines remain byte-identical and in the
## same order (signals are emitted synchronously).
class_name CaptureSessionController
extends RefCounted

signal state_changed(from: int, to: int)
signal session_started(session_dir: String)
signal session_stopped(final_path: String)
signal session_error(message: String)

# Exact legacy error message printed by capture_app when the writer refuses
# to open a session (kept byte-identical for behavior compatibility).
const START_FAILED_MESSAGE := "Capture session did not start because its output directory could not be created."

var _state: int = CaptureState.IDLE
var _writer_adapter: CaptureWriterAdapter = null
var _permission_check: Callable = Callable()
# Objects exposing set_capture_options(options) called right after the writer
# session opens (pose / body-motion samplers today).
var _option_samplers: Array = []
# Ordered stop chain: each entry is either an object exposing stop() or a
# bare Callable. Runs before writer close(), preserving the legacy ordering
# (body_motion.stop -> live-pull disconnect -> depth.stop -> writer.close).
var _stop_chain: Array = []
var _live_mode := false
var _session_dir := ""
var _options: Dictionary = {}


func configure(deps: Dictionary) -> void:
	_writer_adapter = deps.get("writer_adapter")
	_permission_check = deps.get("permission_check", Callable())
	_option_samplers = deps.get("option_samplers", [])
	_stop_chain = deps.get("stop_chain", [])
	_live_mode = bool(deps.get("live_mode", false))


func state() -> int:
	return _state


## True while a session is live from the app's point of view — the exact
## window the legacy `_recording` boolean covered (writer session open
## through writer close).
func is_session_active() -> bool:
	return _state == CaptureState.RUNNING \
			or _state == CaptureState.RECOVERING \
			or _state == CaptureState.STOPPING


func request_start(options: Dictionary) -> bool:
	if _state != CaptureState.IDLE:
		push_warning("CaptureSessionController: start requested in state %s" % CaptureState.state_name(_state))
		return false
	_options = options.duplicate(true)
	if _permission_check.is_valid():
		_transition(CaptureState.REQUESTING_PERMISSION)
		if not bool(_permission_check.call()):
			# Storage / permission not ready. The check surfaces its own logs
			# (legacy behavior: silent return from start_capture).
			_transition(CaptureState.ERROR)
			_transition(CaptureState.IDLE)
			_options = {}
			return false
		_transition(CaptureState.READY)
	else:
		_transition(CaptureState.READY)
	_transition(CaptureState.STARTING)
	if _writer_adapter == null or not _writer_adapter.start_session(_options):
		_transition(CaptureState.ERROR)
		_transition(CaptureState.IDLE)
		_options = {}
		session_error.emit(START_FAILED_MESSAGE)
		return false
	_session_dir = _writer_adapter.session_dir()
	for sampler in _option_samplers:
		if sampler != null and sampler.has_method("set_capture_options"):
			sampler.set_capture_options(_options)
	_transition(CaptureState.RUNNING)
	session_started.emit(_session_dir)
	return true


func request_stop() -> Dictionary:
	# A stop while paused (RECOVERING) implicitly resumes first so the table
	# stays small; reachable from the device-test pause-finalize path.
	if _state == CaptureState.RECOVERING:
		_transition(CaptureState.RUNNING)
	if _state != CaptureState.RUNNING:
		return {
			"ok": false,
			"error": "stop requested in state %s" % CaptureState.state_name(_state),
		}
	_transition(CaptureState.STOPPING)
	for entry in _stop_chain:
		if entry is Callable:
			(entry as Callable).call()
		elif entry != null and entry.has_method("stop"):
			entry.stop()
	_writer_adapter.close()
	var final_path := ""
	if not _live_mode:
		final_path = _writer_adapter.saved_path()
	_transition(CaptureState.STOPPED)
	_transition(CaptureState.IDLE)
	_options = {}
	session_stopped.emit(final_path)
	return {"ok": true, "final_path": final_path}


## Transient APPLICATION_PAUSED while recording: bookkeeping only — the
## capture pipeline itself keeps its legacy pause semantics.
func notify_pause() -> bool:
	if _state != CaptureState.RUNNING:
		return false
	return _transition(CaptureState.RECOVERING)


func notify_resume() -> bool:
	if _state != CaptureState.RECOVERING:
		return false
	return _transition(CaptureState.RUNNING)


## WP7 test surface: deterministic view of the controller for snapshot asserts.
func snapshot() -> Dictionary:
	return {
		"state": _state,
		"state_name": CaptureState.state_name(_state),
		"session_dir": _session_dir,
		"options": _options.duplicate(true),
		"live_mode": _live_mode,
		"writer_bound": _writer_adapter != null,
		"option_sampler_count": _option_samplers.size(),
		"stop_chain_size": _stop_chain.size(),
	}


func _transition(to: int) -> bool:
	if not CaptureState.legal(_state, to):
		push_warning("CaptureSessionController: illegal transition %s -> %s" % [
			CaptureState.state_name(_state), CaptureState.state_name(to)])
		return false
	var from := _state
	_state = to
	state_changed.emit(from, to)
	return true
