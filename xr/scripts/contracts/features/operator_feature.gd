class_name OperatorFeature

## Stable product feature ids for the XR client (architecture-v2).
##
## Each id maps 1:1 to an `operator_feature_<string>` export option in
## `xr/export_presets.cfg` and to a runtime feature tag with the same
## name emitted by the `operator_features` export plugin.

# Ids are process-local (never serialized), so gaps are harmless: 5 is a
# retired feature and stays unused to keep git history readable.
const MODE_TELEOP := 0
const MODE_EGO_CAPTURE := 1
const MODE_LIVE_FEED := 2
const MODE_VR := 3
const SINK_SPATIALMP4 := 4
const SINK_LIVE_STREAM := 6
const SINK_UPLOAD := 7
const ROBOT_CONTROL := 8
const ROBOT_CONSTRAINT := 9
const DEBUG_METRICS := 10
const TEST_HARNESS := 11
const MODE_EXIT := 12
const MODE_POSE_INFERENCE := 13
const MODE_MEMWORLD := 14

const _ID_TO_STRING := {
	MODE_TELEOP: "mode_teleop",
	MODE_EGO_CAPTURE: "mode_ego_capture",
	MODE_LIVE_FEED: "mode_live_feed",
	MODE_VR: "mode_vr",
	MODE_EXIT: "mode_exit",
	MODE_POSE_INFERENCE: "mode_pose_inference",
	MODE_MEMWORLD: "mode_memworld",
	SINK_SPATIALMP4: "sink_spatialmp4",
	SINK_LIVE_STREAM: "sink_live_stream",
	SINK_UPLOAD: "sink_upload",
	ROBOT_CONTROL: "robot_control",
	ROBOT_CONSTRAINT: "robot_constraint",
	DEBUG_METRICS: "debug_metrics",
	TEST_HARNESS: "test_harness",
}


static func all_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in _ID_TO_STRING.keys():
		ids.append(int(id))
	ids.sort()
	return ids


static func id_to_string(id: int) -> String:
	return String(_ID_TO_STRING.get(id, ""))


static func from_string(name: String) -> int:
	var normalized := name.strip_edges()
	# Accept both the bare id ("mode_ego_capture") and the fully
	# prefixed option/tag name ("operator_feature_mode_ego_capture").
	if normalized.begins_with("operator_feature_"):
		normalized = normalized.substr("operator_feature_".length())
	for id in _ID_TO_STRING.keys():
		if String(_ID_TO_STRING[id]) == normalized:
			return int(id)
	return -1
