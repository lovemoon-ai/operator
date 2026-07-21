class_name GenericOpenXRPlatformAdapter
extends RefCounted

const CapabilityInfoScript := preload("res://scripts/contracts/platform/capability_info.gd")
const CapabilityStateScript := preload("res://scripts/contracts/platform/capability_state.gd")
const SensorCapabilityScript := preload("res://scripts/contracts/platform/sensor_capability.gd")

## Fallback platform adapter: capabilities every OpenXR runtime provides via
## Godot's XRServer (pose / controllers / hand tracking).

const PROVIDER_ID := "generic_openxr"
## Godot OpenXR Vendors singleton names for the standard runtime depth APIs.
## These are implementation entry points, not device identifiers: support is
## decided by is_environment_depth_supported() at runtime.
const ENVIRONMENT_DEPTH_TIME_SINGLETONS := [
	"OpenXRMetaEnvironmentDepthExtensionWrapper",
	"OpenXRMetaEnvironmentDepthExtension",
]
const ENVIRONMENT_DEPTH_SINGLETONS := [
	"OpenXRMetaEnvironmentDepthExtensionWrapper",
	"OpenXRMetaEnvironmentDepthExtension",
	"OpenXRAndroidEnvironmentDepthExtensionWrapper",
	"OpenXRAndroidEnvironmentDepthExtension",
]


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
		environment_depth_capability(),
	]


## Returns the first installed environment-depth wrapper that the active
## runtime reports as supported. Keep the first installed wrapper only as a
## diagnostic fallback when none are supported; this prevents one inactive
## vendor wrapper from hiding a later, working standard wrapper.
func environment_depth_info() -> Dictionary:
	var first_installed := {}
	for singleton_name in ENVIRONMENT_DEPTH_SINGLETONS:
		if not Engine.has_singleton(singleton_name):
			continue
		var extension := Engine.get_singleton(singleton_name)
		if extension == null:
			continue
		var info := {"extension": extension, "name": singleton_name}
		if first_installed.is_empty():
			first_installed = info
		if extension.has_method("is_environment_depth_supported") and bool(
				extension.call("is_environment_depth_supported")):
			return info
	return first_installed


func environment_depth_capability() -> Object:
	var info := environment_depth_info()
	if info.is_empty():
		return CapabilityInfoScript.create(
			SensorCapabilityScript.DEPTH_MAP,
			PROVIDER_ID,
			CapabilityStateScript.REQUIRES_RUNTIME_EXTENSION,
			"environment depth wrapper unavailable")
	var extension: Object = info.get("extension")
	if extension == null or not extension.has_method("is_environment_depth_supported"):
		return CapabilityInfoScript.create(
			SensorCapabilityScript.DEPTH_MAP,
			PROVIDER_ID,
			CapabilityStateScript.REQUIRES_RUNTIME_EXTENSION,
			"environment depth capability probe unavailable")
	var supported := bool(extension.call("is_environment_depth_supported"))
	return CapabilityInfoScript.create(
		SensorCapabilityScript.DEPTH_MAP,
		PROVIDER_ID,
		CapabilityStateScript.AVAILABLE if supported else CapabilityStateScript.REQUIRES_RUNTIME_EXTENSION,
		"" if supported else "XR environment depth is not supported by the active runtime",
		"openxr_depth",
		"openxr_play_space",
		"openxr_runtime_display_time")


## The patched Meta wrapper exposes predicted display time for both the depth
## sampler and the pose sampler. Keep this probe at the generic OpenXR layer so
## any conforming runtime can use it.
func environment_depth_time_extension() -> Object:
	for singleton_name in ENVIRONMENT_DEPTH_TIME_SINGLETONS:
		if not Engine.has_singleton(singleton_name):
			continue
		var extension := Engine.get_singleton(singleton_name)
		if extension != null and extension.has_method("get_predicted_display_time_ns"):
			return extension
	return null
