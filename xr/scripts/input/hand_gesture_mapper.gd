class_name HandGestureMapper
extends RefCounted
## Maps an OpenXR 26-joint hand skeleton to the six active Revo2 channels.
## Output order matches the SDK/ROS driver: thumb proximal flex, thumb
## metacarpal abduction/opposition, index, middle, ring, pinky.

const THUMB_FLEX_MAX := 0.50
const THUMB_ABDUCT_MAX := 0.85
const THUMB_FLEX_OPEN_RAD := 0.10
const THUMB_FLEX_CLOSED_RAD := 1.75
const THUMB_ABDUCT_OPEN_RAD := 0.35
const THUMB_ABDUCT_CLOSED_RAD := 1.65

const CHANNEL_NAMES := [
	"thumb_flex",
	"thumb_aux",
	"index_flex",
	"middle_flex",
	"ring_flex",
	"pinky_flex",
]

const HAND_LEFT := 0
const HAND_RIGHT := 1
const JOINT_PALM := 0
const JOINT_WRIST := 1
const JOINT_THUMB_METACARPAL := 2
const JOINT_THUMB_PROXIMAL := 3
const JOINT_THUMB_DISTAL := 4
const JOINT_THUMB_TIP := 5
const JOINT_INDEX_METACARPAL := 6
const JOINT_INDEX_PROXIMAL := 7
const JOINT_INDEX_INTERMEDIATE := 8
const JOINT_INDEX_DISTAL := 9
const JOINT_INDEX_TIP := 10
const JOINT_MIDDLE_METACARPAL := 11
const JOINT_MIDDLE_PROXIMAL := 12
const JOINT_MIDDLE_INTERMEDIATE := 13
const JOINT_MIDDLE_DISTAL := 14
const JOINT_MIDDLE_TIP := 15
const JOINT_RING_METACARPAL := 16
const JOINT_RING_PROXIMAL := 17
const JOINT_RING_INTERMEDIATE := 18
const JOINT_RING_DISTAL := 19
const JOINT_RING_TIP := 20
const JOINT_PINKY_METACARPAL := 21
const JOINT_PINKY_PROXIMAL := 22
const JOINT_PINKY_INTERMEDIATE := 23
const JOINT_PINKY_DISTAL := 24
const JOINT_PINKY_TIP := 25
const PALM_MENU_FOREARM_OFFSET_M := 0.055
const PALM_MENU_HEAD_OFFSET_M := 0.018

const _SOURCE_TO_CHANNEL := {
	"left_hand_thumb_flex": [0, 0],
	"left_hand_thumb_aux": [0, 1],
	"left_hand_index_flex": [0, 2],
	"left_hand_middle_flex": [0, 3],
	"left_hand_ring_flex": [0, 4],
	"left_hand_pinky_flex": [0, 5],
	"right_hand_thumb_flex": [1, 0],
	"right_hand_thumb_aux": [1, 1],
	"right_hand_index_flex": [1, 2],
	"right_hand_middle_flex": [1, 3],
	"right_hand_ring_flex": [1, 4],
	"right_hand_pinky_flex": [1, 5],
}


static func source_binding(source: String) -> Array:
	return _SOURCE_TO_CHANNEL.get(source, [])


static func targets_from_tracking(joints: Array, controller_input: Dictionary = {}) -> PackedFloat64Array:
	if _has_required_joints(joints):
		return _targets_from_joints(joints)
	return _targets_from_controller(controller_input)


static func has_required_joints(joints: Array) -> bool:
	return _has_required_joints(joints)


static func wrist_position(joints: Array) -> Variant:
	return _joint_position(joints, JOINT_WRIST)


static func index_tip_position(joints: Array) -> Variant:
	return _joint_position(joints, JOINT_INDEX_TIP)


static func palm_menu_state(
	joints: Array,
	head_position: Variant,
	hand: int = HAND_LEFT,
) -> Dictionary:
	if not _has_required_joints(joints) or not head_position is Vector3:
		return {"tracked": false}
	var palm_v: Variant = _joint_position(joints, JOINT_PALM)
	var wrist_v: Variant = _joint_position(joints, JOINT_WRIST)
	var index_v: Variant = _joint_position(joints, JOINT_INDEX_METACARPAL)
	var middle_v: Variant = _joint_position(joints, JOINT_MIDDLE_PROXIMAL)
	var pinky_v: Variant = _joint_position(joints, JOINT_PINKY_METACARPAL)
	if not palm_v is Vector3 or not wrist_v is Vector3 or not index_v is Vector3 \
			or not middle_v is Vector3 or not pinky_v is Vector3:
		return {"tracked": false}

	var palm := palm_v as Vector3
	var wrist := wrist_v as Vector3
	var finger_axis := (middle_v as Vector3) - wrist
	var thumbward_axis := (index_v as Vector3) - (pinky_v as Vector3)
	var toward_head := (head_position as Vector3) - palm
	var toward_forearm := wrist - palm
	if finger_axis.length_squared() <= 0.000001 \
			or thumbward_axis.length_squared() <= 0.000001 \
			or toward_head.length_squared() <= 0.000001 \
			or toward_forearm.length_squared() <= 0.000001:
		return {"tracked": false}

	var palm_normal := thumbward_axis.cross(finger_axis)
	if hand == HAND_RIGHT:
		palm_normal = -palm_normal
	if palm_normal.length_squared() <= 0.000001:
		return {"tracked": false}
	palm_normal = palm_normal.normalized()
	toward_head = toward_head.normalized()
	var anchor := (
		wrist
		+ toward_forearm.normalized() * PALM_MENU_FOREARM_OFFSET_M
		+ toward_head * PALM_MENU_HEAD_OFFSET_M
	)
	return {
		"tracked": true,
		"anchor_position": anchor,
		"facing": palm_normal.dot(toward_head),
		"openness": hand_openness(joints),
	}


static func hand_openness(joints: Array) -> float:
	if not _has_required_joints(joints):
		return 0.0
	var maximum_curl := maxf(_thumb_flexion(joints), _thumb_abduction(joints))
	for indices in [
		[
			JOINT_INDEX_METACARPAL,
			JOINT_INDEX_PROXIMAL,
			JOINT_INDEX_INTERMEDIATE,
			JOINT_INDEX_DISTAL,
			JOINT_INDEX_TIP,
		],
		[
			JOINT_MIDDLE_METACARPAL,
			JOINT_MIDDLE_PROXIMAL,
			JOINT_MIDDLE_INTERMEDIATE,
			JOINT_MIDDLE_DISTAL,
			JOINT_MIDDLE_TIP,
		],
		[
			JOINT_RING_METACARPAL,
			JOINT_RING_PROXIMAL,
			JOINT_RING_INTERMEDIATE,
			JOINT_RING_DISTAL,
			JOINT_RING_TIP,
		],
		[
			JOINT_PINKY_METACARPAL,
			JOINT_PINKY_PROXIMAL,
			JOINT_PINKY_INTERMEDIATE,
			JOINT_PINKY_DISTAL,
			JOINT_PINKY_TIP,
		],
	]:
		maximum_curl = maxf(maximum_curl, _chain_curl(joints, indices))
	return 1.0 - clampf(maximum_curl, 0.0, 1.0)


static func _targets_from_joints(joints: Array) -> PackedFloat64Array:
	var thumb_flex := _thumb_flexion(joints) * THUMB_FLEX_MAX
	var thumb_aux := _thumb_abduction(joints) * THUMB_ABDUCT_MAX
	var index_flex := _chain_curl(joints, [
		JOINT_INDEX_METACARPAL,
		JOINT_INDEX_PROXIMAL,
		JOINT_INDEX_INTERMEDIATE,
		JOINT_INDEX_DISTAL,
		JOINT_INDEX_TIP,
	])
	var middle_flex := _chain_curl(joints, [
		JOINT_MIDDLE_METACARPAL,
		JOINT_MIDDLE_PROXIMAL,
		JOINT_MIDDLE_INTERMEDIATE,
		JOINT_MIDDLE_DISTAL,
		JOINT_MIDDLE_TIP,
	])
	var ring_flex := _chain_curl(joints, [
		JOINT_RING_METACARPAL,
		JOINT_RING_PROXIMAL,
		JOINT_RING_INTERMEDIATE,
		JOINT_RING_DISTAL,
		JOINT_RING_TIP,
	])
	var pinky_flex := _chain_curl(joints, [
		JOINT_PINKY_METACARPAL,
		JOINT_PINKY_PROXIMAL,
		JOINT_PINKY_INTERMEDIATE,
		JOINT_PINKY_DISTAL,
		JOINT_PINKY_TIP,
	])
	return PackedFloat64Array([
		thumb_flex,
		thumb_aux,
		index_flex,
		middle_flex,
		ring_flex,
		pinky_flex,
	])


static func _targets_from_controller(input: Dictionary) -> PackedFloat64Array:
	var trigger := clampf(float(input.get("trigger", 0.0)), 0.0, 1.0)
	var grip := clampf(
		maxf(
			float(input.get("grip", 0.0)),
			maxf(float(input.get("grip_click", 0.0)), float(input.get("grip_force", 0.0)))
		),
		0.0,
		1.0
	)
	return PackedFloat64Array([
		trigger * THUMB_FLEX_MAX,
		trigger * 0.50,
		trigger,
		grip,
		grip,
		grip,
	])


static func _thumb_flexion(joints: Array) -> float:
	var metacarpal_v: Variant = _joint_position(joints, JOINT_THUMB_METACARPAL)
	var proximal_v: Variant = _joint_position(joints, JOINT_THUMB_PROXIMAL)
	var distal_v: Variant = _joint_position(joints, JOINT_THUMB_DISTAL)
	var tip_v: Variant = _joint_position(joints, JOINT_THUMB_TIP)
	if not metacarpal_v is Vector3 or not proximal_v is Vector3 \
			or not distal_v is Vector3 or not tip_v is Vector3:
		return 0.0
	var proximal_axis := (distal_v as Vector3) - (proximal_v as Vector3)
	var bend := _segment_angle(
		(proximal_v as Vector3) - (metacarpal_v as Vector3),
		proximal_axis
	)
	bend += _segment_angle(
		proximal_axis,
		(tip_v as Vector3) - (distal_v as Vector3)
	)
	return clampf(
		(bend - THUMB_FLEX_OPEN_RAD) / (THUMB_FLEX_CLOSED_RAD - THUMB_FLEX_OPEN_RAD),
		0.0,
		1.0
	)


static func _thumb_abduction(joints: Array) -> float:
	var wrist_v: Variant = _joint_position(joints, JOINT_WRIST)
	var thumb_metacarpal_v: Variant = _joint_position(joints, JOINT_THUMB_METACARPAL)
	var thumb_proximal_v: Variant = _joint_position(joints, JOINT_THUMB_PROXIMAL)
	var index_v: Variant = _joint_position(joints, JOINT_INDEX_METACARPAL)
	var middle_v: Variant = _joint_position(joints, JOINT_MIDDLE_METACARPAL)
	var pinky_v: Variant = _joint_position(joints, JOINT_PINKY_METACARPAL)
	if not wrist_v is Vector3 or not thumb_metacarpal_v is Vector3 \
			or not thumb_proximal_v is Vector3 or not index_v is Vector3 \
			or not middle_v is Vector3 or not pinky_v is Vector3:
		return 0.0

	# `index - pinky` always points toward the thumb side, so this local palm
	# basis works for both hands without a left/right sign branch. The OpenXR
	# metacarpal-to-proximal segment ends at the thumb MCP; distal thumb flexion
	# therefore cannot contaminate this CMC abduction/opposition measurement.
	var thumbward := (index_v as Vector3) - (pinky_v as Vector3)
	if thumbward.length_squared() <= 0.000001:
		return 0.0
	thumbward = thumbward.normalized()
	var forward := (middle_v as Vector3) - (wrist_v as Vector3)
	forward -= thumbward * forward.dot(thumbward)
	if forward.length_squared() <= 0.000001:
		return 0.0
	forward = forward.normalized()

	var thumb_axis := (thumb_proximal_v as Vector3) - (thumb_metacarpal_v as Vector3)
	var lateral_component := thumb_axis.dot(thumbward)
	var forward_component := thumb_axis.dot(forward)
	if absf(lateral_component) + absf(forward_component) <= 0.000001:
		return 0.0
	var angle := atan2(forward_component, lateral_component)
	return clampf(
		(angle - THUMB_ABDUCT_OPEN_RAD) / (THUMB_ABDUCT_CLOSED_RAD - THUMB_ABDUCT_OPEN_RAD),
		0.0,
		1.0
	)


static func _segment_angle(first: Vector3, second: Vector3) -> float:
	if first.length_squared() <= 0.000001 or second.length_squared() <= 0.000001:
		return 0.0
	return acos(clampf(first.normalized().dot(second.normalized()), -1.0, 1.0))


static func _has_required_joints(joints: Array) -> bool:
	if joints.size() < 26:
		return false
	for joint_index in [
		JOINT_PALM,
		JOINT_WRIST,
		JOINT_THUMB_METACARPAL,
		JOINT_THUMB_PROXIMAL,
		JOINT_THUMB_DISTAL,
		JOINT_THUMB_TIP,
		JOINT_INDEX_METACARPAL,
		JOINT_INDEX_PROXIMAL,
		JOINT_INDEX_INTERMEDIATE,
		JOINT_INDEX_DISTAL,
		JOINT_INDEX_TIP,
		JOINT_MIDDLE_METACARPAL,
		JOINT_MIDDLE_PROXIMAL,
		JOINT_MIDDLE_INTERMEDIATE,
		JOINT_MIDDLE_DISTAL,
		JOINT_MIDDLE_TIP,
		JOINT_RING_METACARPAL,
		JOINT_RING_PROXIMAL,
		JOINT_RING_INTERMEDIATE,
		JOINT_RING_DISTAL,
		JOINT_RING_TIP,
		JOINT_PINKY_METACARPAL,
		JOINT_PINKY_PROXIMAL,
		JOINT_PINKY_INTERMEDIATE,
		JOINT_PINKY_DISTAL,
		JOINT_PINKY_TIP,
	]:
		if not _joint_position(joints, int(joint_index)) is Vector3:
			return false
	return true


static func _chain_curl(joints: Array, indices: Array) -> float:
	var points: Array[Vector3] = []
	for index_v in indices:
		var position_v: Variant = _joint_position(joints, int(index_v))
		if not position_v is Vector3:
			return 0.0
		points.append(position_v as Vector3)
	var path_length := 0.0
	for i in range(1, points.size()):
		path_length += points[i - 1].distance_to(points[i])
	if path_length <= 0.000001:
		return 0.0
	var reach_ratio := points[0].distance_to(points[-1]) / path_length
	return clampf((0.94 - reach_ratio) / 0.52, 0.0, 1.0)


static func _joint_position(joints: Array, index: int) -> Variant:
	if index < 0 or index >= joints.size():
		return null
	var joint_v: Variant = joints[index]
	if not joint_v is Dictionary:
		return null
	var joint := joint_v as Dictionary
	if not bool(joint.get("tracked", false)):
		return null
	var position_v: Variant = joint.get("position", null)
	if not position_v is Vector3:
		return null
	var position := position_v as Vector3
	if not is_finite(position.x) or not is_finite(position.y) or not is_finite(position.z):
		return null
	return position
