class_name FakeCapabilityRegistry
extends RefCounted
## v2 test harness (WP7): fake with the same query API as PlatformRegistry
## (has_capability / capability_info / provider_for / capabilities).
## Capabilities are mutable at runtime so tests can simulate sources
## appearing, disconnecting, or losing permission mid-test.

var _infos: Dictionary = {}      # capability_id -> CapabilityInfo
var _providers: Dictionary = {}  # capability_id -> Object


## Build from a platform fixture dict:
## {"capabilities": ["pose", "camera_rgb", ...]} or
## {"capabilities": [{"capability": "depth_map", "state": "unavailable",
##   "provider_id": "fake_quest", "reason": "..."}]}.
static func from_fixture(fixture: Dictionary) -> FakeCapabilityRegistry:
	var registry := FakeCapabilityRegistry.new()
	var provider_id := str(fixture.get("provider_id", "fake_platform"))
	for entry_v in fixture.get("capabilities", []):
		if typeof(entry_v) == TYPE_STRING:
			registry.set_available(SensorCapability.from_string(String(entry_v)), provider_id)
		elif typeof(entry_v) == TYPE_DICTIONARY:
			var entry := entry_v as Dictionary
			var cap_id := SensorCapability.from_string(str(entry.get("capability", "")))
			var state := CapabilityState.AVAILABLE
			var state_name := str(entry.get("state", "available"))
			for known_state in range(CapabilityState.ERROR + 1):
				if CapabilityState.id_to_string(known_state) == state_name:
					state = known_state
					break
			registry.set_capability(
				cap_id, state,
				str(entry.get("provider_id", provider_id)),
				str(entry.get("reason", "")))
	return registry


func set_available(capability_id: int, provider_id := "fake_platform") -> void:
	set_capability(capability_id, CapabilityState.AVAILABLE, provider_id)


func set_unavailable(capability_id: int, reason := "fixture: unavailable") -> void:
	set_capability(capability_id, CapabilityState.UNAVAILABLE, "fake_platform", reason)


func set_capability(capability_id: int, state: int, provider_id := "fake_platform", reason := "") -> void:
	if capability_id < 0:
		return
	_infos[capability_id] = CapabilityInfo.create(capability_id, provider_id, state, reason)


func set_provider(capability_id: int, provider: Object) -> void:
	_providers[capability_id] = provider


func remove_capability(capability_id: int) -> void:
	_infos.erase(capability_id)
	_providers.erase(capability_id)


# -- PlatformRegistry-compatible query surface -----------------------------

func has_capability(id: int) -> bool:
	var info: CapabilityInfo = _infos.get(id)
	return info != null and info.available()


func capability_info(id: int) -> CapabilityInfo:
	var info: CapabilityInfo = _infos.get(id)
	if info != null:
		return info
	return CapabilityInfo.create(id, "", CapabilityState.UNAVAILABLE, "no provider")


func provider_for(id: int) -> Object:
	return _providers.get(id)


func capabilities() -> Array:
	var out: Array = []
	for id in _infos.keys():
		out.append(_infos[id])
	return out
