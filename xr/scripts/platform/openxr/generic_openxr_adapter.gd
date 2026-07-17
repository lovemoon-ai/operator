class_name GenericOpenXRPlatformAdapter
extends RefCounted
## Fallback platform adapter: capabilities every OpenXR runtime provides via
## Godot's XRServer (pose / controllers / hand tracking).

const PROVIDER_ID := "generic_openxr"


func provider_id() -> String:
	return PROVIDER_ID


func is_present() -> bool:
	return XRServer.find_interface("OpenXR") != null


func capabilities() -> Array:
	var present := is_present()
	var state := CapabilityState.AVAILABLE if present else CapabilityState.UNAVAILABLE
	return [
		CapabilityInfo.create(SensorCapability.POSE, PROVIDER_ID, state, "", "", "openxr_play_space", "openxr_runtime_display_time"),
		CapabilityInfo.create(SensorCapability.CONTROLLER, PROVIDER_ID, state, "", "", "openxr_play_space"),
		CapabilityInfo.create(SensorCapability.HAND_TRACKING, PROVIDER_ID, state, "", "", "openxr_play_space"),
	]
