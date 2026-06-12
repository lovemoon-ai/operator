class_name SensorCapability
extends RefCounted
## v2 contracts: capability ids the platform layer reports to app/core code.
## App and core modules must gate behavior on these ids — never on device
## names or vendor singleton names (those live under xr/scripts/platform/).

const POSE := 0
const CONTROLLER := 1
const HAND_TRACKING := 2
const BODY_TRACKING := 3
const MOTION_TRACKERS := 4
const CAMERA_RGB := 5
const CAMERA_STEREO := 6
const DEPTH_MAP := 7
const AUDIO_CAPTURE := 8
const PASSTHROUGH := 9
const BOUNDARY := 10
const OPENXR_TIMEBASE := 11
const SPATIAL_MP4_MUX := 12
const LIVE_STREAM_SERVER := 13
const QR_SCAN := 14
const ROBOT_CONTROL := 15

const _NAMES := {
	POSE: "pose",
	CONTROLLER: "controller",
	HAND_TRACKING: "hand_tracking",
	BODY_TRACKING: "body_tracking",
	MOTION_TRACKERS: "motion_trackers",
	CAMERA_RGB: "camera_rgb",
	CAMERA_STEREO: "camera_stereo",
	DEPTH_MAP: "depth_map",
	AUDIO_CAPTURE: "audio_capture",
	PASSTHROUGH: "passthrough",
	BOUNDARY: "boundary",
	OPENXR_TIMEBASE: "openxr_timebase",
	SPATIAL_MP4_MUX: "spatial_mp4_mux",
	LIVE_STREAM_SERVER: "live_stream_server",
	QR_SCAN: "qr_scan",
	ROBOT_CONTROL: "robot_control",
}


static func id_to_string(id: int) -> String:
	return str(_NAMES.get(id, ""))


static func from_string(name: String) -> int:
	for id in _NAMES.keys():
		if _NAMES[id] == name:
			return int(id)
	return -1


static func all_ids() -> Array[int]:
	var out: Array[int] = []
	for id in _NAMES.keys():
		out.append(int(id))
	out.sort()
	return out
