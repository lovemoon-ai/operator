class_name CanonicalJoints
extends RefCounted
## Godot Humanoid canonical joint vocabulary used by the VR body-pose
## debug pipeline.
##
## Names are lower-snake-case derived from Godot 4.5 ``XRBodyTracker.Joint``.
## Keep this list in sync with the Python ``operator_retargeting`` module —
## both halves must agree on the 87 keys.

const SCHEMA := "operator.godot_humanoid_joints.v1"
const CANONICAL_NAME := "godot_xrbodytracker_87"

## All 87 canonical joint names in Godot 4.5 ``XRBodyTracker.Joint`` order.
const JOINT_NAMES: Array[String] = [
	"root",
	"hips",
	"spine",
	"chest",
	"upper_chest",
	"neck",
	"head",
	"head_tip",
	"left_shoulder",
	"left_upper_arm",
	"left_lower_arm",
	"right_shoulder",
	"right_upper_arm",
	"right_lower_arm",
	"left_upper_leg",
	"left_lower_leg",
	"left_foot",
	"left_toes",
	"right_upper_leg",
	"right_lower_leg",
	"right_foot",
	"right_toes",
	"left_hand",
	"left_palm",
	"left_wrist",
	"left_thumb_metacarpal",
	"left_thumb_phalanx_proximal",
	"left_thumb_phalanx_distal",
	"left_thumb_tip",
	"left_index_finger_metacarpal",
	"left_index_finger_phalanx_proximal",
	"left_index_finger_phalanx_intermediate",
	"left_index_finger_phalanx_distal",
	"left_index_finger_tip",
	"left_middle_finger_metacarpal",
	"left_middle_finger_phalanx_proximal",
	"left_middle_finger_phalanx_intermediate",
	"left_middle_finger_phalanx_distal",
	"left_middle_finger_tip",
	"left_ring_finger_metacarpal",
	"left_ring_finger_phalanx_proximal",
	"left_ring_finger_phalanx_intermediate",
	"left_ring_finger_phalanx_distal",
	"left_ring_finger_tip",
	"left_pinky_finger_metacarpal",
	"left_pinky_finger_phalanx_proximal",
	"left_pinky_finger_phalanx_intermediate",
	"left_pinky_finger_phalanx_distal",
	"left_pinky_finger_tip",
	"right_hand",
	"right_palm",
	"right_wrist",
	"right_thumb_metacarpal",
	"right_thumb_phalanx_proximal",
	"right_thumb_phalanx_distal",
	"right_thumb_tip",
	"right_index_finger_metacarpal",
	"right_index_finger_phalanx_proximal",
	"right_index_finger_phalanx_intermediate",
	"right_index_finger_phalanx_distal",
	"right_index_finger_tip",
	"right_middle_finger_metacarpal",
	"right_middle_finger_phalanx_proximal",
	"right_middle_finger_phalanx_intermediate",
	"right_middle_finger_phalanx_distal",
	"right_middle_finger_tip",
	"right_ring_finger_metacarpal",
	"right_ring_finger_phalanx_proximal",
	"right_ring_finger_phalanx_intermediate",
	"right_ring_finger_phalanx_distal",
	"right_ring_finger_tip",
	"right_pinky_finger_metacarpal",
	"right_pinky_finger_phalanx_proximal",
	"right_pinky_finger_phalanx_intermediate",
	"right_pinky_finger_phalanx_distal",
	"right_pinky_finger_tip",
	"lower_chest",
	"left_scapula",
	"left_wrist_twist",
	"right_scapula",
	"right_wrist_twist",
	"left_foot_twist",
	"left_heel",
	"left_middle_foot",
	"right_foot_twist",
	"right_heel",
	"right_middle_foot",
]

## Upper-body subset used by the H2 MVP and the live wire stream.
## Kept short so the per-frame payload is small (one frame = ~22 joints).
const UPPER_BODY_JOINT_NAMES: Array[String] = [
	"root",
	"hips",
	"spine",
	"lower_chest",
	"chest",
	"upper_chest",
	"neck",
	"head",
	"left_scapula",
	"left_shoulder",
	"left_upper_arm",
	"left_lower_arm",
	"left_wrist",
	"left_hand",
	"right_scapula",
	"right_shoulder",
	"right_upper_arm",
	"right_lower_arm",
	"right_wrist",
	"right_hand",
]


static func canonical_name_for_index(index: int) -> String:
	if index < 0 or index >= JOINT_NAMES.size():
		return ""
	return JOINT_NAMES[index]


static func is_canonical_name(name: String) -> bool:
	return JOINT_NAMES.has(name)


## Return a fresh canonical joint record matching the schema's empty
## ("invalid") shape.
static func empty_joint_record() -> Dictionary:
	return {
		"pose": null,
		"valid": false,
		"tracked": false,
		"inferred": false,
		"confidence": 0.0,
		"source": null,
		"source_joint": null,
	}


## Build a populated joint record. ``p`` is a Vector3, ``q`` is a Quaternion.
## ``source`` and ``source_joint`` mark provenance.
static func make_joint_record(
	p: Vector3,
	q: Quaternion,
	source: String,
	source_joint: Variant,
	tracked: bool,
	inferred: bool = false,
	confidence: float = 1.0,
) -> Dictionary:
	return {
		"pose": {
			"p": [float(p.x), float(p.y), float(p.z)],
			"q": [float(q.x), float(q.y), float(q.z), float(q.w)],
		},
		"valid": true,
		"tracked": tracked,
		"inferred": inferred,
		"confidence": clampf(confidence, 0.0, 1.0),
		"source": source,
		"source_joint": source_joint,
	}


## Construct an ``operator.godot_humanoid_joints.v1`` frame envelope.
static func make_frame(
	timestamp_ns: int,
	joints: Dictionary,
	space: String = "operator_xr_world",
) -> Dictionary:
	return {
		"schema": SCHEMA,
		"timestamp_ns": timestamp_ns,
		"canonical": CANONICAL_NAME,
		"space": space,
		"joints": joints,
	}
