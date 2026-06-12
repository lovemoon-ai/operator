class_name FakePlatformRuntime
extends RefCounted
## v2 test harness (WP7): bundles the fake platform pieces a composition
## test needs: capability registry, permission provider, and per-capability
## fake sensor providers — all built from one platform fixture.

var registry: FakeCapabilityRegistry
var permissions: FakePermissionProvider
var _sensor_providers: Dictionary = {}  # SensorFrameType id -> Object


static func from_fixture(fixture: Dictionary) -> FakePlatformRuntime:
	var runtime := FakePlatformRuntime.new()
	runtime.registry = FakeCapabilityRegistry.from_fixture(fixture)
	runtime.permissions = FakePermissionProvider.new()
	if not bool(fixture.get("permission_granted", true)):
		runtime.permissions.deny()
	return runtime


func attach_sensor_provider(frame_type: int, provider: Object) -> void:
	_sensor_providers[frame_type] = provider


func sensor_provider(frame_type: int) -> Object:
	return _sensor_providers.get(frame_type)


func has_capability(id: int) -> bool:
	return registry != null and registry.has_capability(id)


func capability_info(id: int) -> CapabilityInfo:
	if registry == null:
		return CapabilityInfo.create(id, "", CapabilityState.UNAVAILABLE, "no registry")
	return registry.capability_info(id)


func capabilities() -> Array:
	return registry.capabilities() if registry != null else []
