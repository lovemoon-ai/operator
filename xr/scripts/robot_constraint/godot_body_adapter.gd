class_name GodotBodyAdapter
extends RefCounted
## Adapter: Godot ``XRBodyTracker`` -> canonical Godot Humanoid joints.
##
## Designed to run live in XR. Call ``sample(body_tracker, timestamp_ns)``
## once per frame. Returns ``{}`` when the tracker has no data; otherwise
## returns an ``operator.godot_humanoid_joints.v1`` dict.

const CanonicalJointsCls = preload("res://scripts/robot_constraint/canonical_joints.gd")

const SOURCE_ID := "godot_xrbodytracker"

const FLAG_ROT_VALID := 1
const FLAG_ROT_TRACKED := 2
const FLAG_POS_VALID := 4
const FLAG_POS_TRACKED := 8

# Godot 4.5 ``XRBodyTracker.Joint`` enum index -> canonical joint name.
# Keep this explicit instead of relying on CanonicalJoints.JOINT_NAMES index
# semantics; the canonical vocabulary is the saved data format, while this
# table is the live Godot runtime ABI boundary.
const GODOT_JOINT_TO_CANONICAL: Array[String] = [
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


func sample(body_tracker: XRBodyTracker, timestamp_ns: int, space: String = "operator_xr_world") -> Dictionary:
	if body_tracker == null or not body_tracker.has_tracking_data:
		return {}
	var joints: Dictionary = {}
	var joint_max := GODOT_JOINT_TO_CANONICAL.size()
	for j in range(joint_max):
		var flags := int(body_tracker.get_joint_flags(j))
		var canonical_name := GODOT_JOINT_TO_CANONICAL[j]
		if canonical_name.is_empty():
			continue
		if flags == 0:
			# Joint not exposed by this runtime — skip so the resolver
			# can choose a different source.
			continue
		var pos_tracked := (flags & FLAG_POS_TRACKED) != 0
		var rot_tracked := (flags & FLAG_ROT_TRACKED) != 0
		var pos_valid := pos_tracked or (flags & FLAG_POS_VALID) != 0
		var rot_valid := rot_tracked or (flags & FLAG_ROT_VALID) != 0
		# Meta Quest 3 body tracking exposes spine + head with flags=15
		# (full pos+rot) but arms / hands / legs only get flags=5 (position
		# tracked + valid, rotation neither). Keep joints with valid
		# positions so body-pose debug overlays still have useful signal;
		# substitute identity for rotation and drop confidence to advertise
		# the partial quality.
		if not pos_valid:
			joints[canonical_name] = CanonicalJointsCls.empty_joint_record()
			continue
		var t := body_tracker.get_joint_transform(j)
		var p := t.origin
		var q := t.basis.get_rotation_quaternion() if rot_valid else Quaternion.IDENTITY
		var confidence: float
		if pos_tracked and rot_tracked:
			confidence = 1.0
		elif rot_valid:
			confidence = 0.5
		else:
			# Position-only — typical for Meta arm / hand joints. The
			# downstream solver treats this as a position task (weight_rot=0)
			# so it still contributes; we just shouldn't claim full quality.
			confidence = 0.4
		joints[canonical_name] = CanonicalJointsCls.make_joint_record(
			p, q, SOURCE_ID, j, pos_tracked and rot_tracked, false, confidence
		)
	if joints.is_empty():
		return {}
	return CanonicalJointsCls.make_frame(timestamp_ns, joints, space)
