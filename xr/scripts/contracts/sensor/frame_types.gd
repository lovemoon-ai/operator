class_name SensorFrameType
extends RefCounted
## v2 contracts: canonical sensor frame type ids (consumed from WP4 onward).

const POSE := 0
const CONTROLLER := 1
const HAND := 2
const BODY := 3
const CAMERA := 4
const DEPTH := 5
const AUDIO := 6
const INPUT_EVENT := 7
const MOTION_TRACKER := 8
const CLOCK := 9

const _NAMES := {
	POSE: "pose",
	CONTROLLER: "controller",
	HAND: "hand",
	BODY: "body",
	CAMERA: "camera",
	DEPTH: "depth",
	AUDIO: "audio",
	INPUT_EVENT: "input_event",
	MOTION_TRACKER: "motion_tracker",
	CLOCK: "clock",
}


static func id_to_string(id: int) -> String:
	return str(_NAMES.get(id, ""))


static func from_string(name: String) -> int:
	for id in _NAMES.keys():
		if _NAMES[id] == name:
			return int(id)
	return -1
