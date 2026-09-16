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
# Official minimum for XR_BD_body_tracking and XR_PICO_body_tracking2:
# https://developer.picoxr.com/document/native/body-tracking/
# Meeting the version floor does not replace runtime capability checks.
const MIN_BODY_TRACKING_OS_VERSION := [5, 13, 0]


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


func system_compatibility() -> Dictionary:
	if not is_pico_build():
		return evaluate_system_compatibility(false, "", {})
	var bridge := openxr_bridge_native()
	var version := ""
	var status: Dictionary = {}
	if bridge != null:
		if bridge.has_method("get_os_version"):
			version = str(bridge.call("get_os_version")).strip_edges()
		if bridge.has_method("get_status"):
			var raw: Variant = bridge.call("get_status")
			if raw is Dictionary:
				status = raw as Dictionary
	return evaluate_system_compatibility(true, version, status)


static func parse_os_version(version: String) -> Array[int]:
	var pattern := RegEx.new()
	pattern.compile("(?i)^(?:PICO[ _-]*(?:OS[ _-]*)?)?(\\d+)\\.(\\d+)\\.(\\d+)(?:[^0-9].*)?$")
	var found := pattern.search(version.strip_edges())
	if found == null:
		return []
	return [int(found.get_string(1)), int(found.get_string(2)), int(found.get_string(3))]


static func evaluate_system_compatibility(is_pico: bool, version: String, status: Dictionary) -> Dictionary:
	var report := {
		"version": version,
		"minimum_version": "%d.%d.%d" % MIN_BODY_TRACKING_OS_VERSION,
		"needs_upgrade": false,
		"reason": "",
	}
	if not is_pico:
		return report
	var parsed := parse_os_version(version)
	var below_minimum := false
	for index in range(parsed.size()):
		if parsed[index] != MIN_BODY_TRACKING_OS_VERSION[index]:
			below_minimum = parsed[index] < MIN_BODY_TRACKING_OS_VERSION[index]
			break
	if below_minimum:
		report["needs_upgrade"] = true
		report["reason"] = "old_os"
	elif bool(status.get("session_created", false)) \
			and status.has("bd_body_tracking_extension") \
			and not bool(status["bd_body_tracking_extension"]):
		# New/unrecognised version but a known missing API: do not claim the
		# version is old, or mistake an uninitialized XR session for one.
		report["needs_upgrade"] = true
		report["reason"] = "body_extension_unavailable"
	return report


func set_boundary_visible(visible: bool) -> bool:
	var bridge := openxr_bridge_native()
	if bridge == null or not bridge.has_method("set_boundary_visible"):
		return false
	return bool(bridge.call("set_boundary_visible", visible))


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
	var boundary_bridge := openxr_bridge_native()
	var boundary_state := CapabilityStateScript.AVAILABLE \
			if boundary_bridge != null and boundary_bridge.has_method("set_boundary_visible") \
			else CapabilityStateScript.UNAVAILABLE
	caps.append(CapabilityInfoScript.create(SensorCapabilityScript.BOUNDARY, PROVIDER_ID, boundary_state))
	# Environment depth is contributed by GenericOpenXRPlatformAdapter after a
	# live extension probe; it must not be inferred from the PICO camera plugin
	# or from a headset identity.
	return caps
