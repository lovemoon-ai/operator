class_name GenericOpenXRPlatformAdapter
extends RefCounted

const CapabilityInfoScript := preload("res://scripts/contracts/platform/capability_info.gd")
const CapabilityStateScript := preload("res://scripts/contracts/platform/capability_state.gd")
const SensorCapabilityScript := preload("res://scripts/contracts/platform/sensor_capability.gd")

## Fallback platform adapter: capabilities every OpenXR runtime provides via
## Godot's XRServer (pose / controllers / hand tracking).

const PROVIDER_ID := "generic_openxr"


func provider_id() -> String:
	return PROVIDER_ID


func is_present() -> bool:
	return XRServer.find_interface("OpenXR") != null


func capabilities() -> Array:
	var present := is_present()
	var state := CapabilityStateScript.AVAILABLE if present else CapabilityStateScript.UNAVAILABLE
	return [
		CapabilityInfoScript.create(SensorCapabilityScript.POSE, PROVIDER_ID, state, "", "", "openxr_play_space", "openxr_runtime_display_time"),
		CapabilityInfoScript.create(SensorCapabilityScript.CONTROLLER, PROVIDER_ID, state, "", "", "openxr_play_space"),
		CapabilityInfoScript.create(SensorCapabilityScript.HAND_TRACKING, PROVIDER_ID, state, "", "", "openxr_play_space"),
	]
