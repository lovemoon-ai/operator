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
	var info: Object = _capabilities.get(id)
	return info != null and info.available()


func capability_info(id: int) -> Object:
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


func depth_extension_info() -> Dictionary:
	return _quest_adapter.depth_extension_info()


func depth_time_extension() -> Object:
	return _quest_adapter.depth_time_extension()


## Legacy fallback used by samplers when no capture provider was injected:
## historically they fell back to QuestCapturePlugin only.
func fallback_capture_provider() -> Object:
	return _quest_adapter.camera_plugin()


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
