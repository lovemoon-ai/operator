class_name CanonicalResolver
extends RefCounted
## Multi-source canonical-frame fusion per RFC-003 §"Fusion and Quality".
##
## Higher index in ``DEFAULT_SOURCE_PRIORITY`` wins. Tracked beats inferred
## within the same source. The default rule is a numeric ``score`` so we can
## keep the policy compact and easy to reason about.

const CanonicalJointsCls = preload("res://scripts/robot_constraint/canonical_joints.gd")

const DEFAULT_SOURCE_PRIORITY: Array[String] = [
	"operator_fallback",
	"godot_xrbodytracker",
	"pico_bd_body_tracking",
	"meta_fb_body_tracking",
	"meta_meta_body_tracking_full_body",
	"openxr_hand_tracking_left",
	"openxr_hand_tracking_right",
	"external_tracker_chest",
	"external_tracker_left_wrist",
	"external_tracker_right_wrist",
]


static func _priority_map() -> Dictionary:
	var m: Dictionary = {}
	for i in range(DEFAULT_SOURCE_PRIORITY.size()):
		m[DEFAULT_SOURCE_PRIORITY[i]] = i + 1
	return m


static func _score(record: Dictionary, priority: Dictionary) -> float:
	if not bool(record.get("valid", false)):
		return -1.0
	var source_id: String = String(record.get("source", ""))
	var base := float(priority.get(source_id, 0))
	var confidence: float = float(record.get("confidence", 0.0))
	var tracked_bonus := 10.0 if bool(record.get("tracked", false)) else 0.0
	var inferred_penalty := -0.5 if bool(record.get("inferred", false)) else 0.0
	return base * 100.0 + tracked_bonus + confidence + inferred_penalty


## Merge an array of partial canonical frames (dicts produced by
## adapters). Empty frames are ignored.
static func resolve(partial_frames: Array, timestamp_ns: int = -1, space: String = "operator_xr_world") -> Dictionary:
	var priority := _priority_map()
	var merged: Dictionary = {}
	var best_score: Dictionary = {}
	var seen_ts := 0
	for frame in partial_frames:
		if typeof(frame) != TYPE_DICTIONARY or frame.is_empty():
			continue
		var ts := int(frame.get("timestamp_ns", 0))
		if ts > seen_ts:
			seen_ts = ts
		var joints: Dictionary = frame.get("joints", {})
		for name in joints.keys():
			var record: Dictionary = joints[name]
			var s := _score(record, priority)
			var prev: float = best_score.get(name, -INF)
			if s > prev:
				merged[name] = record
				best_score[name] = s
			elif not merged.has(name):
				merged[name] = CanonicalJointsCls.empty_joint_record()
				best_score[name] = prev
	var ts_out := timestamp_ns if timestamp_ns >= 0 else seen_ts
	return CanonicalJointsCls.make_frame(ts_out, merged, space)
