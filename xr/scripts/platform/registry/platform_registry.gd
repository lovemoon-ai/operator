class_name PlatformRegistry
extends RefCounted

const PicoPlatformAdapterScript := preload("res://scripts/platform/pico/pico_platform_adapter.gd")
const QuestPlatformAdapterScript := preload("res://scripts/platform/quest/quest_platform_adapter.gd")
const GenericOpenXRPlatformAdapterScript := preload("res://scripts/platform/openxr/generic_openxr_adapter.gd")
const CapabilityInfoScript := preload("res://scripts/contracts/platform/capability_info.gd")
const CapabilityStateScript := preload("res://scripts/contracts/platform/capability_state.gd")
const SensorCapabilityScript := preload("res://scripts/contracts/platform/sensor_capability.gd")
const LiveStreamProviderScript := preload("res://scripts/platform/registry/live_stream_provider.gd")
const QrProviderScript := preload("res://scripts/platform/registry/qr_provider.gd")

## v2 platform capability registry. Owns the vendor platform adapters and is
## the app/core entry point for capability queries and provider objects.
## Dependency rule: app/core/sinks code never references vendor singleton
## names — it goes through this registry (or an injected adapter).

## Outcome of apply_boundary_policy(). NOT_APPLICABLE ("this platform has no
## boundary call to make, and needs none") must stay distinguishable from
## FAILED ("there was a call to make and it did not work") so XRSessionPolicy
## warns about the second and stays quiet about the first. PARTIAL covers the
## PICO subset runtimes: guardian disabled, mesh possibly still drawn.
const BOUNDARY_NOT_APPLICABLE := 0
const BOUNDARY_APPLIED := 1
const BOUNDARY_PARTIAL := 2
const BOUNDARY_FAILED := 3

const _BOUNDARY_STATUS_NAMES := {
	BOUNDARY_NOT_APPLICABLE: "not_applicable",
	BOUNDARY_APPLIED: "applied",
	BOUNDARY_PARTIAL: "partial",
	BOUNDARY_FAILED: "failed",
}

static var _shared: Object

var _pico_adapter: Object
var _quest_adapter: Object
var _generic_adapter: Object
var _capabilities: Dictionary = {}  # capability_id -> CapabilityInfo (best provider wins)
var _providers: Dictionary = {}     # capability_id -> Object


static func create() -> Object:
	var registry := PlatformRegistry.new()
	registry._initialize()
	return registry


## Process-wide cached registry for call sites that have no injection path
## (legacy sampler fallbacks). Cheap to build; adapters are stateless probes.
static func shared() -> Object:
	if _shared == null:
		_shared = create()
	return _shared


func _initialize() -> void:
	_pico_adapter = PicoPlatformAdapterScript.new()
	_quest_adapter = QuestPlatformAdapterScript.new()
	_generic_adapter = GenericOpenXRPlatformAdapterScript.new()
	# Priority order: Pico > Quest > generic. Later (lower-priority) entries
	# only fill capability ids not already AVAILABLE from a higher-priority
	# adapter that is present on this device.
	var ordered: Array = []
	if _pico_adapter.is_present():
		ordered.append(_pico_adapter)
	if _quest_adapter.is_present():
		ordered.append(_quest_adapter)
	ordered.append(_generic_adapter)
	# Absent vendor adapters still contribute UNAVAILABLE infos last so every
	# probed capability id has an answer.
	if not _pico_adapter.is_present():
		ordered.append(_pico_adapter)
	if not _quest_adapter.is_present():
		ordered.append(_quest_adapter)
	for adapter in ordered:
		for info_v in adapter.capabilities():
			var info: Object = info_v
			if info == null:
				continue
			var existing: Object = _capabilities.get(info.capability_id)
			if existing == null or (not existing.available() and info.available()):
				_capabilities[info.capability_id] = info
				_providers[info.capability_id] = adapter
	# Cross-cutting providers.
	var live_plugin: Object = LiveStreamProviderScript.bind()
	_capabilities[SensorCapabilityScript.LIVE_STREAM_SERVER] = CapabilityInfoScript.create(
		SensorCapabilityScript.LIVE_STREAM_SERVER, "live_stream",
		CapabilityStateScript.AVAILABLE if live_plugin != null else CapabilityStateScript.UNAVAILABLE)
	var qr_plugin: Object = QrProviderScript.bind()
	_capabilities[SensorCapabilityScript.QR_SCAN] = CapabilityInfoScript.create(
		SensorCapabilityScript.QR_SCAN, "qr_scanner",
		CapabilityStateScript.AVAILABLE if qr_plugin != null else CapabilityStateScript.UNAVAILABLE)


func has_capability(id: int) -> bool:
	var info: Object = capability_info(id)
	return info != null and info.available()


func capability_info(id: int) -> Object:
	if id == SensorCapabilityScript.DEPTH_MAP and _generic_adapter != null:
		var live_environment_depth: Object = _generic_adapter.environment_depth_capability()
		_capabilities[id] = live_environment_depth
		_providers[id] = _generic_adapter
	var info: Object = _capabilities.get(id)
	if info != null:
		return info
	return CapabilityInfoScript.create(id, "", CapabilityStateScript.UNAVAILABLE, "no provider")


func provider_for(id: int) -> Object:
	match id:
		SensorCapabilityScript.LIVE_STREAM_SERVER:
			return LiveStreamProviderScript.bind()
		SensorCapabilityScript.QR_SCAN:
			return QrProviderScript.bind()
	return _providers.get(id)


func capabilities() -> Array:
	# Environment depth is an active-runtime property, not a headset-model property.
	capability_info(SensorCapabilityScript.DEPTH_MAP)
	var out: Array = []
	for id in _capabilities.keys():
		out.append(_capabilities[id])
	return out


func pico_adapter() -> Object:
	return _pico_adapter


func quest_adapter() -> Object:
	return _quest_adapter


# -- legacy-parity convenience helpers ------------------------------------

## Camera capture provider selection with the legacy device-score semantics
## (CaptureProviderRegistry.bind()): probe Quest then PICO, prefer the highest
## getCaptureProviderDeviceScore (fallback scores: PICO 10, Quest 5).
func bind_camera_provider() -> Object:
	var best_plugin: Object
	var best_score := -1000000
	for entry in [[_quest_adapter.camera_plugin(), 5], [_pico_adapter.camera_plugin(), 10]]:
		var plugin: Object = entry[0]
		if plugin == null:
			continue
		var score: int = entry[1]
		var raw: Variant = _call_or_null(plugin, "getCaptureProviderDeviceScore")
		if raw != null:
			score = int(raw)
		if best_plugin == null or score > best_score:
			best_plugin = plugin
			best_score = score
	return best_plugin


func muxer_plugin() -> Object:
	var plugin: Object = _quest_adapter.muxer_plugin()
	if plugin != null:
		return plugin
	return _pico_adapter.muxer_plugin()


func live_server_plugin() -> Object:
	return LiveStreamProviderScript.bind()


func boundary_extension() -> Object:
	return _quest_adapter.boundary_extension()


static func boundary_status_to_string(status: int) -> String:
	return str(_BOUNDARY_STATUS_NAMES.get(status, "unknown"))


## Applies the XR safety-boundary policy on every vendor adapter that has one.
## Returns {"status": int (one of BOUNDARY_*), "detail": String}.
##
## The four outcomes are deliberately distinct. Collapsing them into a single
## bool (`pico_applied or quest_applied`) made "no boundary API on this
## platform" indistinguishable from "the call failed" — which is why the app
## used to warn about a missing API on Quest, where the guardian is already
## suppressed by a manifest feature and there is nothing to call — and it also
## hid a real failure whenever the other adapter succeeded.
func apply_boundary_policy(visible: bool) -> Dictionary:
	var results: Array[Dictionary] = [
		_pico_boundary_result(visible),
		_quest_boundary_result(visible),
	]
	var failed := false
	var partial := false
	var applied := false
	for result in results:
		if not bool(result.get("applicable", false)):
			continue
		if not bool(result.get("applied", false)):
			failed = true
		elif not bool(result.get("complete", false)):
			partial = true
		else:
			applied = true
	var status := BOUNDARY_NOT_APPLICABLE
	if failed:
		status = BOUNDARY_FAILED
	elif partial:
		status = BOUNDARY_PARTIAL
	elif applied:
		status = BOUNDARY_APPLIED
	var notes: PackedStringArray = PackedStringArray()
	for result in results:
		# Adapters for absent hardware would only add noise to the log line.
		if bool(result.get("applicable", false)) or bool(result.get("present", false)):
			notes.append("%s: %s" % [result.get("provider", "?"), result.get("reason", "")])
	if notes.is_empty():
		notes.append("no vendor boundary API on this device")
	return {"status": status, "detail": ", ".join(notes)}


## PICO drives the boundary through the native GDExtension bridge. The bridge's
## bool return only covers the required xrSetVirtualBoundaryEnablePICO call, so
## the companion status getter is what tells "guardian off, mesh gone" from
## "guardian off, mesh may still be drawn".
func _pico_boundary_result(visible: bool) -> Dictionary:
	var bridge: Object = _pico_adapter.openxr_bridge_native()
	if bridge == null or not bridge.has_method("set_boundary_visible"):
		return {
			"provider": "pico", "present": false, "applicable": false, "applied": false,
			"complete": not visible, "reason": "no PICO OpenXR bridge in this runtime",
		}
	if not bool(_pico_adapter.set_boundary_visible(visible)):
		return {
			"provider": "pico", "present": true, "applicable": true, "applied": false,
			"complete": false, "reason": "XR_PICO_virtual_boundary enable call did not apply",
		}
	var complete := true
	var reason := "XR_PICO_virtual_boundary applied"
	if bridge.has_method("get_boundary_status"):
		var native_status: Dictionary = bridge.call("get_boundary_status")
		complete = bool(native_status.get("complete", true))
		if not complete:
			reason = "guardian disabled, but the best-effort visibility setters did not all apply (visible=%s see_through=%s)" % [
				native_status.get("visible_applied", false),
				native_status.get("see_through_applied", false),
			]
	return {
		"provider": "pico", "present": true, "applicable": true, "applied": true,
		"complete": complete, "reason": reason,
	}


func _quest_boundary_result(visible: bool) -> Dictionary:
	var result: Dictionary = _quest_adapter.apply_boundary_policy(visible)
	result["provider"] = "quest"
	result["present"] = _quest_adapter.is_present()
	return result


func depth_extension_info() -> Dictionary:
	return _generic_adapter.environment_depth_info()


func depth_time_extension() -> Object:
	return _generic_adapter.environment_depth_time_extension()


## Fallback used by samplers when no capture provider was injected. Select the
## active Android provider by runtime score so depth conversion and timestamps
## work in the same APK across supported OpenXR devices.
func fallback_capture_provider() -> Object:
	return bind_camera_provider()


static func _call_or_null(plugin: Object, method: String) -> Variant:
	if plugin == null:
		return null
	if plugin.has_method(method):
		return plugin.call(method)
	# Android plugin singletons sometimes do not reflect @UsedByGodot methods
	# through has_method(); the provider-score getter is implemented by every
	# current provider so call it directly.
	if method == "getCaptureProviderDeviceScore":
		return plugin.call(method)
	return null
