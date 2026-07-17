class_name OpenXRExportSpace
extends RefCounted
## Canonical export-space contract shared by the capture UI and samplers.
##
## These values name OpenXR reference-space types, not Godot scene spaces.
## The active OpenXRInterface play space is switched to the selected type
## before a recording starts, then raw XRPose transforms and native hand
## joints are written relative to that same XrSpace.

const STAGE := "stage"
const LOCAL := "local"
const LOCAL_FLOOR := "local_floor"
const DEFAULT := STAGE
const VALUES := [STAGE, LOCAL, LOCAL_FLOOR]


static func normalize(value: Variant) -> String:
	var normalized := str(value).strip_edges().to_lower().replace("-", "_")
	if normalized in VALUES:
		return normalized
	return DEFAULT


static func coordinate_space_id(value: Variant) -> String:
	return "openxr_%s" % normalize(value)


static func display_label(value: Variant) -> String:
	return normalize(value).to_upper()


static func play_area_mode(value: Variant) -> int:
	match normalize(value):
		LOCAL:
			return XRInterface.XR_PLAY_AREA_SITTING
		LOCAL_FLOOR:
			return XRInterface.XR_PLAY_AREA_ROOMSCALE
		_:
			return XRInterface.XR_PLAY_AREA_STAGE


static func from_play_area_mode(mode: int) -> String:
	match mode:
		XRInterface.XR_PLAY_AREA_SITTING:
			return LOCAL
		XRInterface.XR_PLAY_AREA_ROOMSCALE:
			return LOCAL_FLOOR
		XRInterface.XR_PLAY_AREA_STAGE:
			return STAGE
		_:
			return ""
