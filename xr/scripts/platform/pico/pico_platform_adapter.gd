class_name PicoPlatformAdapter
extends RefCounted

const CapabilityInfoScript := preload("res://scripts/contracts/platform/capability_info.gd")
const CapabilityStateScript := preload("res://scripts/contracts/platform/capability_state.gd")
const SensorCapabilityScript := preload("res://scripts/contracts/platform/sensor_capability.gd")

## Platform adapter for PICO. Only xr/scripts/platform/ may reference the
## PICO vendor singleton names.

const PROVIDER_ID := "pico"

const CAMERA_SINGLETON := "PicoCapturePlugin"
const MUXER_SINGLETON := "SpatialMp4MuxerPlugin"
const OPENXR_BRIDGE_NATIVE_SINGLETON := "PicoOpenXRBridgeNative"
const OPENXR_BRIDGE_CLASS := "PicoOpenXRExtension"


# WP6 sweep: PICO build/device probes used by app-level scripts live here so
# vendor-name strings stay inside xr/scripts/platform/.

## The export preset's custom feature tag — the cheap, reliable signal for
## "this APK was built for Pico".
static func is_pico_build() -> bool:
	return OS.has_feature("pico")


## Heuristic XRServer tracker-name match for external motion trackers
## (PICO waist/feet pucks via XR_PICO_motion_tracking). `name` must be
## lower-cased by the caller.
static func looks_like_motion_tracker_name(name: String) -> bool:
	return name.contains("motion") or name.contains("tracker") or name.contains("waist") \
		or name.contains("foot") or name.contains("ankle") or name.contains("pico")


## OpenXR runtime-name match for sideloads/editor builds without the
## export feature tag. `runtime_name` must be lower-cased by the caller.
static func is_pico_openxr_runtime_name(runtime_name: String) -> bool:
	return runtime_name.contains("pico") or runtime_name.contains("bytedance")


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


## Native OpenXR bridge singleton (body tracking + motion-tracker pucks).
## The PicoOpenXRBridge autoload and ClassDB fallback remain in caller code
## (xr/scripts/xr/pico_openxr_bridge.gd shim + capture_app) — this exposes
## only the singleton probe so vendor names stay inside platform/.
func openxr_bridge_native() -> Object:
	if Engine.has_singleton(OPENXR_BRIDGE_NATIVE_SINGLETON):
		return Engine.get_singleton(OPENXR_BRIDGE_NATIVE_SINGLETON)
	return null


func instantiate_openxr_bridge() -> Object:
	if not ClassDB.class_exists(OPENXR_BRIDGE_CLASS):
		return null
	return ClassDB.instantiate(OPENXR_BRIDGE_CLASS)


func capabilities() -> Array:
	var caps: Array = []
	var present := is_present()
	var cam_state := CapabilityStateScript.AVAILABLE if present else CapabilityStateScript.UNAVAILABLE
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.CAMERA_RGB, PROVIDER_ID, cam_state))
	var body_state := CapabilityStateScript.AVAILABLE if openxr_bridge_native() != null else CapabilityStateScript.UNAVAILABLE
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.BODY_TRACKING, PROVIDER_ID, body_state, "", "pico_bd"))
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.MOTION_TRACKERS, PROVIDER_ID, body_state))
	var mux_state := CapabilityStateScript.AVAILABLE if muxer_plugin() != null else CapabilityStateScript.UNAVAILABLE
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.SPATIAL_MP4_MUX, PROVIDER_ID, mux_state))
	caps.append(CapabilityInfoScript.create(
		SensorCapabilityScript.DEPTH_MAP, PROVIDER_ID,
		CapabilityStateScript.UNAVAILABLE, "no depth camera stream"))
	return caps
