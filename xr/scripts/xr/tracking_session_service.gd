class_name TrackingSessionService
extends Node
## Application-wide tracking ownership and publication boundary. Consumers
## acquire weak-owner leases; only this service starts/stops Pico trackers.
## Calibration probes may run before readiness, but data never escapes then.

signal changed

const POLL_USEC := 100_000
const RETRY_USEC := 1_000_000
var _leases: Dictionary = {}
var _native: Object
var _pico := false
var _policy := PicoTrackingCalibration.new()
var _continuity: Dictionary = {}
var _confirmation_ready := false
var _runtime: Dictionary = {}
var _body: Dictionary = {}
var _policy_report: Dictionary = {"phase": "required", "confirmed": false}
var _mode := "off"
var _body_started := false
var _motion_count := 0
var _monitor_enabled := false
var _last_poll := -POLL_USEC
var _last_start := -RETRY_USEC
var _dirty := true
var _updating := false
var _state_key := ""
var _generation := 0


static func shared() -> TrackingSessionService:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("TrackingSessions") as TrackingSessionService if tree != null else null


func _ready() -> void:
	process_priority = -100
	_pico = PicoPlatformAdapter.is_pico_build()
	if _pico:
		_native = _resolve_native_bridge()
		var xr := XRServer.find_interface("OpenXR")
		if xr != null:
			xr.connect("session_focussed", _on_tracking_focus.bind(true))
			xr.connect("session_visible", _on_tracking_focus.bind(false))
			xr.connect("session_stopping", _on_tracking_focus.bind(false))


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_on_tracking_focus(false)
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_on_tracking_focus(true)


func _on_tracking_focus(focused: bool) -> void:
	if bool(_policy_report.get("pending", false)):
		print("[TrackingSessions] calibration flow focused=%s" % focused)
	_policy.note_focus(focused)
	_dirty = true



func _resolve_native_bridge() -> Object:
	# Share the existing camera/clock bridge, including its ClassDB fallback;
	# never instantiate a second OpenXR extension wrapper for tracking.
	var tree := Engine.get_main_loop() as SceneTree
	var bridge: Node = tree.root.get_node_or_null("PicoOpenXRBridge") if tree != null else null
	if bridge != null and bridge.has_method("get_bridge"):
		var raw: Variant = bridge.call("get_bridge")
		if raw is Object:
			return raw as Object
	return PlatformRegistry.shared().pico_adapter().openxr_bridge_native()


func _process(_delta: float) -> void:
	_refresh()


func is_pico() -> bool:
	return _pico


func acquire(owner: Object, capabilities: Array, motion_count: int = 2) -> void:
	if owner == null:
		return
	var wanted: Array = []
	for capability in ["body", "motion"]:
		if capabilities.has(capability):
			wanted.append(capability)
	if wanted.is_empty():
		release(owner)
		return
	var id := owner.get_instance_id()
	var count := clampi(motion_count, 1, 3)
	var previous: Dictionary = _leases.get(id, {})
	if previous.get("capabilities") == wanted and previous.get("motion_count") == count:
		return
	_leases[id] = {"owner": weakref(owner), "capabilities": wanted, "motion_count": count}
	_dirty = true
	_refresh()


func release(owner: Object) -> void:
	if owner != null and _leases.erase(owner.get_instance_id()):
		_dirty = true
		_refresh()


func status(owner: Object, force_refresh: bool = false) -> Dictionary:
	_refresh(force_refresh)
	var lease: Dictionary = _leases.get(owner.get_instance_id(), {}) if owner != null else {}
	return _status_for(lease)


func summary() -> Dictionary:
	_refresh()
	var capabilities: Array = ["body"] if _mode == "body" else (["motion"] if _mode == "motion" else [])
	var result := _status_for({"capabilities": capabilities, "motion_count": _motion_count})
	result["needed"] = not _leases.is_empty()
	result["consumers"] = _leases.size()
	for lease: Dictionary in _leases.values():
		if _status_for(lease).get("phase") == "mode_conflict":
			result["phase"] = "mode_conflict"
			result["allowed"] = false
	return result


func begin_calibration() -> bool:
	_refresh(true)
	if not _pico or _leases.is_empty() or _native == null \
			or not _native.has_method("start_body_tracking_calibration_app"):
		return false
	_policy.begin_calibration()
	_policy_report = _policy.observe(_continuity, _runtime)
	_confirmation_ready = false
	_generation += 1
	changed.emit() # Invalidate consumers before opening another Android app.
	if _motion_count > 0:
		_native.call("request_motion_trackers", 0)
		_motion_count = 0
	if not _body_started:
		_body_started = bool(_native.call("start_body_tracking", {}))
	var opened := bool(_native.call("start_body_tracking_calibration_app"))
	if not opened:
		_policy.launch_failed()
	else:
		_policy.launch_succeeded()
	_dirty = true
	_refresh(true)
	return opened


func confirm_calibration() -> bool:
	# Explicit user attestation, never inferred from focus or a VALID flag.
	# Refresh/probe again so a stale enabled button cannot accept a disconnect.
	_refresh(true)
	if not _pico or _leases.is_empty() or not bool(_policy_report.get("can_confirm", false)):
		return false
	if not _policy.confirm(_confirmation_ready):
		return false
	print("[TrackingSessions] user confirmed this calibration; live tracking verified")
	_dirty = true
	_refresh(true)
	return true


func retry_setup() -> void:
	_last_start = -RETRY_USEC
	_dirty = true
	_refresh(true)


func sample_body(owner: Object) -> Dictionary:
	var report := status(owner)
	if not _pico or _native == null or not bool(report.get("allowed", false)) or report.get("mode") != "body":
		return {}
	var sample: Dictionary = _native.call("sample_body_joints")
	if not _usable_body_sample(sample):
		_body = {"available": true, "status": 0}
		_dirty = true
		return {}
	return sample


func sample_motion(owner: Object) -> Array:
	var report := status(owner)
	if not _pico or _native == null or not bool(report.get("allowed", false)) or report.get("mode") != "motion":
		return []
	var lease: Dictionary = _leases.get(owner.get_instance_id(), {})
	var samples: Array = _native.call("sample_motion_trackers", int(lease.get("motion_count", 2)))
	if not _usable_motion_samples(samples, int(lease.get("motion_count", 2))):
		_dirty = true
		return []
	return samples


func _status_for(lease: Dictionary) -> Dictionary:
	var wanted: Array = lease.get("capabilities", [])
	var mode := "body" if wanted.has("body") else ("motion" if wanted.has("motion") else "off")
	var phase := "off"
	var allowed := wanted.is_empty() or not _pico
	if not wanted.is_empty():
		phase = "ready" if not _pico else str(_policy_report.get("phase", "required"))
		if phase == "confirming" and not _confirmation_ready:
			phase = "confirmation_waiting_tracking"
		if _pico and bool(_policy_report.get("confirmed", false)):
			if (wanted.has("motion") and _mode != "motion") or (wanted.has("body") and _mode != "body"):
				phase = "mode_conflict"
			elif mode == "body":
				var state := int(_body.get("status", 0))
				allowed = _body_started and bool(_runtime.get("session_created", false)) \
						and bool(_runtime.get("body_tracker_created", false)) and bool(_body.get("available", false)) and state in [1, 2]
				phase = ("ready" if state == 1 else "limited") if allowed else "waiting_body"
			else:
				allowed = _motion_count > 0 and int(_runtime.get("motion_tracker_count", 0)) >= int(lease.get("motion_count", 2)) \
						and bool(_runtime.get("motion_request_sent", false)) and int(_runtime.get("last_motion_request_result", -1)) >= 0
				phase = "ready" if allowed else "motion_setup"
	return {"mode": mode, "phase": phase, "allowed": allowed, "generation": _generation,
		"confirmation_source": _policy_report.get("confirmation_source", ""),
		"needs_confirmation": not wanted.is_empty() and bool(_policy_report.get("needs_confirmation", false)),
		"can_confirm": mode == _mode and bool(_policy_report.get("can_confirm", false)) and _confirmation_ready,
		"tracker_count": int(_runtime.get("motion_tracker_count", 0)),
		"can_calibrate": _pico and bool(_runtime.get("session_created", false)) and bool(_runtime.get("pico_body_tracking2_extension", false))}


func _refresh(force_refresh: bool = false) -> void:
	if _updating:
		return
	for id in _leases.keys():
		var ref: WeakRef = _leases[id]["owner"]
		if ref.get_ref() == null:
			_leases.erase(id)
			_dirty = true
	var now := Time.get_ticks_usec()
	# Publication checks see native invalidation epochs immediately, without
	# issuing another IPC state query for each consumer/sample in the frame.
	if _pico and _native != null and _monitor_enabled:
		var latest: Dictionary = _native.call("get_tracking_continuity_state", false)
		var runtime: Dictionary = _native.call("get_status")
		if latest != _continuity:
			_dirty = true
		for key in ["tracker_disconnect_epoch", "session_created", "body_tracker_created", "motion_tracker_count", "motion_request_sent", "last_motion_request_result"]:
			if runtime.get(key) != _runtime.get(key):
				_dirty = true
	if not force_refresh and not _dirty and now - _last_poll < POLL_USEC:
		return
	_updating = true
	_dirty = false
	_confirmation_ready = false
	_last_poll = now
	var has_body := false
	var wanted_motion := 0
	for lease: Dictionary in _leases.values():
		has_body = has_body or lease["capabilities"].has("body")
		if lease["capabilities"].has("motion"):
			wanted_motion = maxi(wanted_motion, int(lease["motion_count"]))
	var mode := "body" if has_body else ("motion" if wanted_motion > 0 else "off")
	# A newly enabled display/recorder must not preempt a mode still owned by
	# another consumer. Body priority within a protocol request is normalized
	# by that consumer; cross-consumer conflicts stay explicit and symmetric.
	if _mode == "motion" and wanted_motion > 0:
		mode = "motion"
	if _pico and _native == null:
		_native = _resolve_native_bridge()
		if _native == null:
			_policy_report = {"phase": "unavailable", "confirmed": false}
	if _pico and _native != null:
		_runtime = _native.call("get_status")
		if mode != "off":
			_monitor_enabled = bool(_native.call("set_tracking_monitor_enabled", true))
			_continuity = _native.call("get_tracking_continuity_state", force_refresh)
			_body = _native.call("get_body_tracking_state")
			_policy_report = _policy.observe(_continuity, _runtime)
		if mode == "off":
			_stop_body()
			if _motion_count > 0:
				_native.call("request_motion_trackers", 0)
			_motion_count = 0
			if _monitor_enabled:
				_native.call("set_tracking_monitor_enabled", false)
				_monitor_enabled = false
		elif bool(_policy_report.get("confirmed", false)) or bool(_policy_report.get("pending", false)):
			# Probes/setup are allowed while publication is blocked. Motion-only
			# returns from calibration, prepares independent tracking, and then
			# checks those actual poses before enabling the confirmation button.
			var prepare_body := mode == "body" or (not bool(_policy_report.get("needs_confirmation", false)) and bool(_policy_report.get("pending", false)))
			if prepare_body:
				if _motion_count > 0:
					_native.call("request_motion_trackers", 0)
				_motion_count = 0
				_body_started = _body_started and bool(_runtime.get("body_tracker_created", false))
				if not _body_started and now - _last_start >= RETRY_USEC:
					_last_start = now
					_body_started = bool(_native.call("start_body_tracking", {}))
				_runtime = _native.call("get_status")
				_body = _native.call("get_body_tracking_state")
			else:
				_stop_body()
				if (_motion_count != wanted_motion or int(_runtime.get("last_motion_request_result", -1)) < 0) and now - _last_start >= RETRY_USEC:
					_last_start = now
					if bool(_native.call("request_motion_trackers", wanted_motion)):
						_motion_count = wanted_motion
				_runtime = _native.call("get_status")
			if bool(_policy_report.get("can_confirm", false)):
				if mode == "body" and _body_started:
					var sample: Dictionary = _native.call("sample_body_joints")
					_confirmation_ready = _usable_body_sample(sample)
				elif mode == "motion" and _motion_count >= wanted_motion and int(_runtime.get("motion_tracker_count", 0)) >= wanted_motion:
					var samples: Array = _native.call("sample_motion_trackers", wanted_motion)
					_confirmation_ready = _usable_motion_samples(samples, wanted_motion)
	_mode = mode
	var key := str([_mode, _policy_report, _confirmation_ready, _body.get("status"), _runtime.get("motion_tracker_count"), _runtime.get("session_created")])
	var notify := key != _state_key
	if notify:
		_state_key = key
		_generation += 1
	_updating = false
	if notify:
		changed.emit()


static func _usable_body_sample(sample: Dictionary) -> bool:
	if not bool(sample.get("active", false)) or not int(sample.get("status", 0)) in [1, 2]:
		return false
	var have_bounds := false
	var lower := Vector3.ZERO
	var upper := Vector3.ZERO
	for joint_v in sample.get("joints", []):
		if not (joint_v is Dictionary) or (int(joint_v.get("flags", 0)) & 2) == 0:
			continue
		var position_v: Variant = joint_v.get("position")
		if not (position_v is Dictionary):
			continue
		var p := Vector3(float(position_v.get("x", NAN)), float(position_v.get("y", NAN)), float(position_v.get("z", NAN)))
		if not p.is_finite():
			return false
		lower = lower.min(p) if have_bounds else p
		upper = upper.max(p) if have_bounds else p
		have_bounds = true
	# Reject the runtime's collapsed placeholder skeleton as well as no data.
	return have_bounds and (upper - lower).length() >= 0.05


static func _usable_motion_samples(samples: Array, required_count: int) -> bool:
	if required_count <= 0 or samples.size() < required_count:
		return false
	for sample_v in samples:
		if not (sample_v is Dictionary) or not bool(sample_v.get("tracking_valid", false)):
			return false
		var transform: Variant = sample_v.get("transform")
		if not (transform is Transform3D) or not (transform as Transform3D).is_finite():
			return false
	return true


func _stop_body() -> void:
	if _body_started:
		_native.call("stop_body_tracking")
		_body_started = false


func _exit_tree() -> void:
	_leases.clear()
	_dirty = true
	_refresh(true)
