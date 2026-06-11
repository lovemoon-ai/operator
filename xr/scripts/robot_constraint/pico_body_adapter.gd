class_name PicoBodyAdapter
extends RefCounted
## Adapter: Pico ``XR_BD_body_tracking`` -> canonical Godot Humanoid joints.
##
## Consumes the dict returned by ``PicoOpenXRExtension.sample_body_joints()``
## (see ``xr/native/pico_openxr/src/pico_openxr_extension.cpp``). Each
## joint record there carries ``joint`` (int enum), ``flags`` (OpenXR
## location flags), ``position``/``rotation``, and optional Pico-specific
## ``posture`` / ``linear_velocity`` / etc.

const CanonicalJointsCls = preload("res://scripts/robot_constraint/canonical_joints.gd")

const SOURCE_ID := "pico_bd_body_tracking"

const FLAG_ORIENTATION_VALID := 0x1
const FLAG_POSITION_VALID := 0x2
const FLAG_ORIENTATION_TRACKED := 0x4
const FLAG_POSITION_TRACKED := 0x8

# Pico BD enum index -> canonical joint name. Matches the Python adapter so
# both sides agree on the mapping. Indexes correspond to ``XrBodyJointBD``
# from ``pico_openxr_defs.h``.
const PICO_TO_CANONICAL: Array[String] = [
	"hips",            # 0 PELVIS
	"left_upper_leg",  # 1 LEFT_HIP
	"right_upper_leg", # 2 RIGHT_HIP
	"spine",           # 3 SPINE1
	"left_lower_leg",  # 4 LEFT_KNEE
	"right_lower_leg", # 5 RIGHT_KNEE
	"chest",           # 6 SPINE2
	"left_foot",       # 7 LEFT_ANKLE
	"right_foot",      # 8 RIGHT_ANKLE
	"upper_chest",     # 9 SPINE3
	"left_toes",       # 10 LEFT_FOOT
	"right_toes",      # 11 RIGHT_FOOT
	"neck",            # 12 NECK
	"left_scapula",    # 13 LEFT_COLLAR
	"right_scapula",   # 14 RIGHT_COLLAR
	"head",            # 15 HEAD
	"left_shoulder",   # 16 LEFT_SHOULDER
	"right_shoulder",  # 17 RIGHT_SHOULDER
	"left_lower_arm",  # 18 LEFT_ELBOW
	"right_lower_arm", # 19 RIGHT_ELBOW
	"left_wrist",      # 20 LEFT_WRIST
	"right_wrist",     # 21 RIGHT_WRIST
	"left_hand",       # 22 LEFT_HAND
	"right_hand",      # 23 RIGHT_HAND
]


func sample(body_dict: Dictionary, timestamp_ns: int, space: String = "openxr_local_floor") -> Dictionary:
	if body_dict == null or body_dict.is_empty():
		return {}
	var joints_in: Array = body_dict.get("joints", [])
	if joints_in.is_empty():
		return {}
	var all_tracked := bool(body_dict.get("all_tracked", false))
	var joints_out: Dictionary = {}
	for entry in joints_in:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var idx_v: Variant = entry.get("joint", entry.get("source_joint", -1))
		var idx: int = -1
		if typeof(idx_v) == TYPE_INT:
			idx = idx_v
		elif typeof(idx_v) == TYPE_FLOAT:
			idx = int(idx_v)
		if idx < 0 or idx >= PICO_TO_CANONICAL.size():
			continue
		var canonical_name := PICO_TO_CANONICAL[idx]
		var flags := int(entry.get("flags", 0))
		var pos_dict: Dictionary = entry.get("position", {})
		var rot_dict: Dictionary = entry.get("rotation", {})
		var pos_valid := (flags & FLAG_POSITION_VALID) != 0
		var rot_valid := (flags & FLAG_ORIENTATION_VALID) != 0
		var pos_tracked := all_tracked or (flags & FLAG_POSITION_TRACKED) != 0
		var rot_tracked := all_tracked or (flags & FLAG_ORIENTATION_TRACKED) != 0
		if not pos_valid or not rot_valid or pos_dict.is_empty() or rot_dict.is_empty():
			joints_out[canonical_name] = CanonicalJointsCls.empty_joint_record()
			continue
		var p := Vector3(float(pos_dict.get("x", 0.0)), float(pos_dict.get("y", 0.0)), float(pos_dict.get("z", 0.0)))
		var q := Quaternion(
			float(rot_dict.get("x", 0.0)),
			float(rot_dict.get("y", 0.0)),
			float(rot_dict.get("z", 0.0)),
			float(rot_dict.get("w", 1.0))
		)
		var confidence := 1.0 if (pos_tracked and rot_tracked) else 0.5
		joints_out[canonical_name] = CanonicalJointsCls.make_joint_record(
			p, q, SOURCE_ID, idx, pos_tracked and rot_tracked, false, confidence
		)
	if joints_out.is_empty():
		return {}
	return CanonicalJointsCls.make_frame(timestamp_ns, joints_out, space)
