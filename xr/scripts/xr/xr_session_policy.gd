extends Node

const PlatformRegistryScript := preload("res://scripts/platform/registry/platform_registry.gd")

## Autoload that keeps the XR safety boundary suppressed for every mode. The
## OpenXR interface only exists once the runtime has initialized, so binding is
## polled — but only for a bounded window, because a desktop/editor run never
## initializes OpenXR and must not poll forever.
const BIND_TIMEOUT_SECONDS := 15.0

var _xr_interface: Object
var _bind_elapsed_seconds := 0.0
var _last_logged_status := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	_bind_openxr_interface()
	if _xr_interface != null and _xr_interface.is_initialized():
		call_deferred("_apply_boundary_policy")
	else:
		set_process(true)


func _process(delta: float) -> void:
	if _xr_interface == null:
		_bind_openxr_interface()
	if _xr_interface != null and _xr_interface.is_initialized():
		set_process(false)
		_apply_boundary_policy()
		return
	# Non-XR run (desktop tooling, headless export checks): give up instead of
	# re-probing XRServer every frame for the life of the process. Session
	# signals still re-apply the policy if OpenXR comes up later.
	_bind_elapsed_seconds += delta
	if _bind_elapsed_seconds >= BIND_TIMEOUT_SECONDS:
		set_process(false)
		print("[Operator] OpenXR did not initialize within %.0fs; XR safety boundary policy idle" % BIND_TIMEOUT_SECONDS)


func _bind_openxr_interface() -> void:
	if _xr_interface != null:
		return
	_xr_interface = XRServer.find_interface("OpenXR")
	if _xr_interface == null:
		return
	_connect_openxr_signal("session_begun", Callable(self, "_on_openxr_session_ready"))
	_connect_openxr_signal("session_focussed", Callable(self, "_on_openxr_session_ready"))


func _connect_openxr_signal(signal_name: StringName, callback: Callable) -> void:
	if _xr_interface.has_signal(signal_name) and not _xr_interface.is_connected(signal_name, callback):
		_xr_interface.connect(signal_name, callback)


func _on_openxr_session_ready() -> void:
	call_deferred("_apply_boundary_policy")


func _apply_boundary_policy() -> void:
	var result := apply_policy(PlatformRegistryScript.shared())
	var status := int(result.get("status", PlatformRegistryScript.BOUNDARY_FAILED))
	# session_focussed fires on every re-don, so only report state changes.
	var repeat := status == _last_logged_status
	_last_logged_status = status
	if repeat:
		return
	var detail := str(result.get("detail", ""))
	if status == PlatformRegistryScript.BOUNDARY_APPLIED:
		print("[Operator] XR safety boundary disabled (%s)" % detail)
	elif status == PlatformRegistryScript.BOUNDARY_NOT_APPLICABLE:
		# Quest: the guardian is removed by the BOUNDARYLESS_APP manifest
		# feature, so there is no API to call and nothing to warn about.
		print("[Operator] XR safety boundary policy not applicable on this platform (%s)" % detail)
	elif status == PlatformRegistryScript.BOUNDARY_PARTIAL:
		push_warning("[Operator] XR safety boundary only partially suppressed; the guardian may still be drawn (%s)" % detail)
	else:
		push_warning("[Operator] XR safety boundary could not be disabled (%s)" % detail)


## Requests the hidden boundary state from `registry` and reports the outcome as
## {"status": int (PlatformRegistry.BOUNDARY_*), "detail": String}. Static and
## duck-typed so tests can drive it with a stand-in registry.
static func apply_policy(registry: Object) -> Dictionary:
	if registry == null or not registry.has_method("apply_boundary_policy"):
		return {
			"status": PlatformRegistryScript.BOUNDARY_FAILED,
			"detail": "no platform registry with a boundary policy",
		}
	var result: Variant = registry.call("apply_boundary_policy", false)
	if typeof(result) != TYPE_DICTIONARY:
		return {
			"status": PlatformRegistryScript.BOUNDARY_FAILED,
			"detail": "platform registry did not return a boundary result",
		}
	var status_result: Dictionary = result
	return {
		"status": int(status_result.get("status", PlatformRegistryScript.BOUNDARY_FAILED)),
		"detail": str(status_result.get("detail", "")),
	}
