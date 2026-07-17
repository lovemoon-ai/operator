class_name QuestPlatformAdapter
extends RefCounted

const CapabilityInfoScript := preload("res://scripts/contracts/platform/capability_info.gd")
const CapabilityStateScript := preload("res://scripts/contracts/platform/capability_state.gd")
const SensorCapabilityScript := preload("res://scripts/contracts/platform/sensor_capability.gd")

## Platform adapter for Meta Quest. This file (and the rest of
## xr/scripts/platform/) is the only place allowed to reference the Quest
## vendor singleton names. App/core code reaches these objects through
## PlatformRegistry / SensorCapability ids.

const PROVIDER_ID := "quest"

const CAMERA_SINGLETON := "QuestCapturePlugin"
const MUXER_SINGLETON := "SpatialMp4MuxerPlugin"
const BOUNDARY_SINGLETON := "OpenXRMetaBoundaryVisibilityExtensionWrapper"
## Depth extensions probed in legacy order. The first two also expose the
## OpenXR predicted display time used by PoseSampler.
const DEPTH_TIME_SINGLETONS := [
	"OpenXRMetaEnvironmentDepthExtensionWrapper",
	"OpenXRMetaEnvironmentDepthExtension",
]
const DEPTH_SINGLETONS := [
	"OpenXRMetaEnvironmentDepthExtensionWrapper",
	"OpenXRMetaEnvironmentDepthExtension",
	"OpenXRAndroidEnvironmentDepthExtensionWrapper",
	"OpenXRAndroidEnvironmentDepthExtension",
]


func provider_id() -> String:
	return PROVIDER_ID


func is_present() -> bool:
	return Engine.has_singleton(CAMERA_SINGLETON)


func camera_plugin() -> Object:
	if Engine.has_singleton(CAMERA_SINGLETON):
		return Engine.get_singleton(CAMERA_SINGLETON)
	return null


func muxer_plugin() -> Object:
	if Engine.has_singleton(MUXER_SINGLETON):
		return Engine.get_singleton(MUXER_SINGLETON)
	return null


## Depth extension probe preserving the exact legacy singleton order used by
## DepthSampler. Returns {"extension": Object, "name": String} or {}.
func depth_extension_info() -> Dictionary:
	for singleton_name in DEPTH_SINGLETONS:
		if Engine.has_singleton(singleton_name):
			var ext := Engine.get_singleton(singleton_name)
			if ext != null:
				return {"extension": ext, "name": singleton_name}
	return {}


## Probe restricted to the Meta wrappers historically used by PoseSampler for
## get_predicted_display_time_ns. Returns the extension object or null.
func depth_time_extension() -> Object:
	for singleton_name in DEPTH_TIME_SINGLETONS:
		if Engine.has_singleton(singleton_name):
			var candidate := Engine.get_singleton(singleton_name)
			if candidate != null and candidate.has_method("get_predicted_display_time_ns"):
				return candidate
	return null


func boundary_extension() -> Object:
	if Engine.has_singleton(BOUNDARY_SINGLETON):
		return Engine.get_singleton(BOUNDARY_SINGLETON)
	return null


## XrTime (CLOCK_MONOTONIC ns) -> Godot ticks ns offset captured by the
## Android plugin. Returns 0 until the plugin has captured its clock anchors.
func timebase_offset_ns() -> int:
	var plugin := camera_plugin()
	if plugin == null:
		return 0
	var raw: Variant = plugin.call("getXrTimeToGodotTicksOffsetNs")
	if raw == null:
		return 0
	return int(raw)


## Kotlin fast-path D16 depth conversion. Returns PackedByteArray (may be
## empty) or null when the provider is absent.
func convert_depth_to_u16mm(data: PackedByteArray, width: int, height: int, row3: PackedFloat64Array) -> Variant:
	var plugin := camera_plugin()
	if plugin == null:
		return null
	return plugin.call("convertOpenxrDepthRhToU16Mm", data, width, height, row3)


func capabilities() -> Array:
	var caps: Array = []
	var present := is_present()
	var cam_state := CapabilityStateScript.AVAILABLE if present else CapabilityStateScript.UNAVAILABLE
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.CAMERA_RGB, PROVIDER_ID, cam_state))
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.CAMERA_STEREO, PROVIDER_ID, cam_state))
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.AUDIO_CAPTURE, PROVIDER_ID, cam_state))
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.OPENXR_TIMEBASE, PROVIDER_ID, cam_state))
	var depth_state := CapabilityStateScript.AVAILABLE if not depth_extension_info().is_empty() else CapabilityStateScript.REQUIRES_RUNTIME_EXTENSION
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.DEPTH_MAP, PROVIDER_ID, depth_state))
	var boundary_state := CapabilityStateScript.AVAILABLE if boundary_extension() != null else CapabilityStateScript.UNAVAILABLE
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.BOUNDARY, PROVIDER_ID, boundary_state))
	var mux_state := CapabilityStateScript.AVAILABLE if muxer_plugin() != null else CapabilityStateScript.UNAVAILABLE
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.SPATIAL_MP4_MUX, PROVIDER_ID, mux_state))
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.BODY_TRACKING, PROVIDER_ID, cam_state, "", "godot_xr_body_tracker"))
	return caps
