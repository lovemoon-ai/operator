class_name FallbackBodyAdapter
extends RefCounted
## Adapter: HMD + controller wrist -> minimal canonical upper-body frame.
##
## Used when no real body tracker is available so the overlay/control
## pipeline still has tracked head + wrist poses and inferred torso
## hints. Everything outside ``head`` / ``*_wrist`` is marked
## ``inferred = true``.

const CanonicalJointsCls = preload("res://scripts/robot_constraint/canonical_joints.gd")

const SOURCE_ID := "operator_fallback"

var chest_drop_below_head_m: float = 0.25
var hips_drop_below_head_m: float = 0.65


func sample(
	head_pose: Dictionary,
	left_wrist_pose: Dictionary,
	right_wrist_pose: Dictionary,
	timestamp_ns: int,
	space: String = "operator_xr_world",
) -> Dictionary:
	var joints: Dictionary = {}
	if not head_pose.is_empty():
		var hp: Vector3 = head_pose.get("position", Vector3.ZERO)
		var hq: Quaternion = head_pose.get("rotation", Quaternion.IDENTITY)
		joints["head"] = CanonicalJointsCls.make_joint_record(hp, hq, SOURCE_ID, "head", true, false, 1.0)
		var chest_p := hp + Vector3(0.0, -chest_drop_below_head_m, 0.0)
		var hips_p := hp + Vector3(0.0, -hips_drop_below_head_m, 0.0)
		joints["upper_chest"] = CanonicalJointsCls.make_joint_record(
			chest_p, Quaternion.IDENTITY, SOURCE_ID, "head_inferred_chest", false, true, 0.3
		)
		joints["hips"] = CanonicalJointsCls.make_joint_record(
			hips_p, Quaternion.IDENTITY, SOURCE_ID, "head_inferred_hips", false, true, 0.25
		)
	for side in [["left", left_wrist_pose], ["right", right_wrist_pose]]:
		var label: String = side[0]
		var wrist: Dictionary = side[1]
		if wrist.is_empty():
			continue
		var p: Vector3 = wrist.get("position", Vector3.ZERO)
		var q: Quaternion = wrist.get("rotation", Quaternion.IDENTITY)
		var canonical_wrist := "%s_wrist" % label
		var canonical_hand := "%s_hand" % label
		joints[canonical_wrist] = CanonicalJointsCls.make_joint_record(
			p, q, SOURCE_ID, "%s_controller" % label, true, false, 0.9
		)
		joints[canonical_hand] = CanonicalJointsCls.make_joint_record(
			p, q, SOURCE_ID, "%s_controller" % label, false, true, 0.5
		)
	if joints.is_empty():
		return {}
	return CanonicalJointsCls.make_frame(timestamp_ns, joints, space)
