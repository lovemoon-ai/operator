extends RefCounted
## Unit coverage for converting Operator tracking snapshots to the legacy
## XRoboToolkit Tracking document consumed by HoloMotion.

const CASE_ID := "teleop.xrt_tracking_encoder"
const XrtTrackingEncoderScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_tracking_encoder.gd"
)
const TOP_TIMESTAMP_NS := 1_700_000_000_123_456_789
const PREDICTED_DISPLAY_TIME_NS := 12_345_678_900_000
const BODY_LEGACY_TIMESTAMP_NS := 1_700_000_000_120_000_000
const BODY_SOURCE_TIMESTAMP_NS := 8_000_000_000
const GODOT_HAND_BONE_ADJUSTMENT := Quaternion(
	0.0, -0.7071067811865476, 0.7071067811865476, 0.0
)

const CONTROLLER_FIELDS := [
	"axisX",
	"axisY",
	"axisClick",
	"grip",
	"trigger",
	"primaryButton",
	"secondaryButton",
	"menuButton",
	"pose",
]


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_head_and_controllers(t)
	_test_pico_right_system_button_maps_to_menu(t)
	_test_invalid_head_and_controller_inputs_are_safe(t)
	_test_near_zero_quaternions_are_rejected(t)
	_test_complete_pico_body(t)
	_test_body_legacy_wire_raw_coordinate_golden(t)
	_test_body_position_only_joint_uses_identity_rotation(t)
	_test_body_invalid_position_is_omitted(t)
	_test_body_timestamps_and_motion_values_are_safe(t)
	_test_incomplete_body_is_omitted(t)
	_test_hand_contract_and_invalid_omission(t)
	_test_hand_quaternion_removes_godot_bone_adjustment(t)
	_test_motion_vectors_are_finite(t)


func _test_head_and_controllers(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var encoded: Dictionary = encoder.encode(_base_snapshot(), false)

	t.eq(encoded.get("timeStampNs"), TOP_TIMESTAMP_NS,
		"Tracking preserves the Unix frame timestamp")
	t.almost_eq(float(encoded.get("predictTime")), float(PREDICTED_DISPLAY_TIME_NS) / 1000.0,
		0.000001, "predictTime uses predicted display nanoseconds converted to microseconds")
	t.contains(encoded, "Head", "Tracking includes Head")
	_assert_csv(t, encoded.get("Head", {}).get("pose", ""),
		[1.25, -2.5, 3.75, 0.1, 0.2, 0.3, 0.9],
		"Head pose uses x,y,z,qx,qy,qz,qw order")

	var controllers: Dictionary = encoded.get("Controller", {})
	t.contains(controllers, "left", "Tracking includes the left controller")
	t.contains(controllers, "right", "Tracking includes the right controller")
	var left: Dictionary = controllers.get("left", {})
	var right: Dictionary = controllers.get("right", {})
	for field in CONTROLLER_FIELDS:
		t.contains(left, field, "left controller includes %s" % field)
		t.contains(right, field, "right controller includes neutral %s" % field)

	t.eq(left.get("axisX"), 0.25, "primary_x maps to axisX")
	t.eq(left.get("axisY"), -0.5, "primary_y maps to axisY")
	t.eq(left.get("axisClick"), true, "primary_click maps to axisClick")
	t.eq(left.get("trigger"), 0.75, "trigger is preserved")
	t.eq(left.get("grip"), 0.5, "grip is preserved")
	t.eq(left.get("primaryButton"), true, "ax_button maps to primaryButton")
	t.eq(left.get("secondaryButton"), false, "by_button maps to secondaryButton")
	t.eq(left.get("menuButton"), true, "menu_button maps to menuButton")
	_assert_csv(t, left.get("pose", ""),
		[4.0, 5.0, 6.0, -0.1, -0.2, -0.3, 0.9],
		"controller pose uses x,y,z,qx,qy,qz,qw order")

	t.eq(right.get("axisX"), 0.0, "missing controller axisX is neutral")
	t.eq(right.get("axisY"), 0.0, "missing controller axisY is neutral")
	t.eq(right.get("axisClick"), false, "missing controller axisClick is neutral")
	t.eq(right.get("trigger"), 0.0, "missing controller trigger is neutral")
	t.eq(right.get("grip"), 0.0, "missing controller grip is neutral")
	t.eq(right.get("primaryButton"), false, "missing primary button is neutral")
	t.eq(right.get("secondaryButton"), false, "missing secondary button is neutral")
	t.eq(right.get("menuButton"), false, "missing menu button is neutral")
	_assert_csv(t, right.get("pose", ""), [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0],
		"missing controller pose is the neutral identity pose")


func _test_pico_right_system_button_maps_to_menu(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _base_snapshot()
	snapshot["controllers"]["left"]["input"]["values"] = {
		"menu_button": false,
		"select_button": true,
	}
	snapshot["controllers"]["right"] = {
		"pose": _pose([0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0], 12),
		"input": {"values": {"menu_button": false, "select_button": true}},
	}

	var encoded: Dictionary = encoder.encode(snapshot, false)
	var controllers: Dictionary = encoded.get("Controller", {})
	t.eq(controllers.get("left", {}).get("menuButton"), false,
		"left system/select does not impersonate the left Menu button")
	t.eq(controllers.get("right", {}).get("menuButton"), true,
		"PICO right system/select maps to the legacy right Menu button")

	snapshot["controllers"]["right"]["input"]["values"] = {
		"menu_button": true,
		"select_button": false,
	}
	encoded = encoder.encode(snapshot, false)
	t.eq(encoded.get("Controller", {}).get("right", {}).get("menuButton"), true,
		"an explicit right Menu binding remains supported")

	snapshot["controllers"]["right"]["input"]["values"] = {
		"menu_button": false,
		"select_button": false,
	}
	encoded = encoder.encode(snapshot, false)
	t.eq(encoded.get("Controller", {}).get("right", {}).get("menuButton"), false,
		"right Menu remains false when neither compatible input is pressed")


func _test_invalid_head_and_controller_inputs_are_safe(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _base_snapshot()
	snapshot["head"] = _pose([NAN, 1.0, 2.0], [0.0, 0.0, 0.0, 1.0], 10)
	snapshot["controllers"]["left"]["pose"] = _pose(
		[1.0, 2.0, 3.0], [0.0, 0.0, INF, 1.0], 11)
	snapshot["controllers"]["left"]["input"]["values"] = {
		"primary_x": 2.0,
		"primary_y": -2.0,
		"primary_click": INF,
		"grip": 2.0,
		"trigger": NAN,
		"ax_button": NAN,
		"by_button": true,
	}
	snapshot["controllers"]["right"] = {
		"pose": _pose([1.0, 2.0, 3.0], [0.0, 0.0, 0.0, 1.0], 12),
		"input": {"values": {"grip": -1.0, "trigger": -2.0}},
	}

	var encoded: Dictionary = encoder.encode(snapshot, false)
	t.eq(encoded.get("Head", {}).get("status"), 0, "invalid Head pose clears status")
	_assert_identity_pose(t, encoded.get("Head", {}).get("pose", ""),
		"invalid Head pose becomes identity")
	var left: Dictionary = encoded.get("Controller", {}).get("left", {})
	_assert_identity_pose(t, left.get("pose", ""), "invalid Controller pose becomes identity")
	t.eq(left.get("axisX"), 1.0, "controller axisX clamps to one")
	t.eq(left.get("axisY"), -1.0, "controller axisY clamps to minus one")
	t.eq(left.get("grip"), 1.0, "controller grip clamps to one")
	t.eq(left.get("trigger"), 0.0, "non-finite controller trigger becomes neutral")
	t.eq(left.get("axisClick"), false, "non-finite controller click becomes neutral")
	t.eq(left.get("primaryButton"), false, "non-finite controller button becomes neutral")
	t.eq(left.get("secondaryButton"), true, "valid controller button is preserved")
	var right: Dictionary = encoded.get("Controller", {}).get("right", {})
	t.eq(right.get("grip"), 0.0, "controller grip clamps to zero")
	t.eq(right.get("trigger"), 0.0, "controller trigger clamps to zero")


func _test_near_zero_quaternions_are_rejected(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _snapshot_with_complete_body()
	snapshot["head"] = _pose([1.0, 2.0, 3.0], [0.0, 0.0, 0.0, 0.0], 10)
	(snapshot["controllers"] as Dictionary)["left"] = {
		"pose": _pose([1.0, 2.0, 3.0], [0.00001, 0.0, 0.0, 0.0], 11),
	}
	var hand := _complete_hand()
	var hand_joints := hand["joints"] as Array
	(hand_joints[4] as Dictionary)["pose"] = _pose(
		[1.0, 2.0, 3.0], [0.0, 0.00001, 0.0, 0.0], 12)
	snapshot["hands"] = {"left": hand}
	var body := snapshot["body"] as Dictionary
	var body_joints := body["joints"] as Array
	(body_joints[6] as Dictionary)["pose"] = _pose(
		[1.0, 2.0, 3.0], [0.0, 0.0, 0.00001, 0.0], 13)
	snapshot["motion_trackers"] = [{
		"id": "near-zero",
		"pose": _pose([1.0, 2.0, 3.0], [0.0, 0.0, 0.0, 0.00001], 14),
	}]

	var encoded: Dictionary = encoder.encode(snapshot)
	t.eq(encoded.get("Head", {}).get("status"), 0,
		"zero-norm Head quaternion clears status")
	_assert_identity_pose(t, encoded.get("Head", {}).get("pose", ""),
		"zero-norm Head quaternion becomes identity")
	_assert_identity_pose(t, encoded.get("Controller", {}).get("left", {}).get("pose", ""),
		"near-zero Controller quaternion becomes identity")
	t.is_false(encoded.has("Hand"),
		"one near-zero joint quaternion omits the entire Hand")
	t.is_false(encoded.has("Body"),
		"one near-zero rotation-valid joint quaternion omits Body")
	t.is_false(encoded.has("Motion"),
		"Motion skips trackers with near-zero quaternions")


func _test_complete_pico_body(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _base_snapshot()
	var joints: Array = []
	for joint_index in range(23, -1, -1):
		joints.append(_body_joint(joint_index))
	snapshot["body"] = {
		"active": true,
		"joint_set": "pico_bd_24",
		"sample_timestamp_ns": BODY_SOURCE_TIMESTAMP_NS,
		"legacy_timestamp_ns": BODY_LEGACY_TIMESTAMP_NS,
		"joints": joints,
	}

	var encoded: Dictionary = encoder.encode(snapshot)
	t.contains(encoded, "Body", "a complete pico_bd_24 sample is emitted")
	var body: Dictionary = encoded.get("Body", {})
	t.eq(body.get("len"), 24, "Body declares exactly 24 joints")
	t.eq(body.get("timeStampNs"), BODY_LEGACY_TIMESTAMP_NS,
		"Body uses the legacy Unix timestamp")
	var encoded_joints: Array = body.get("joints", [])
	t.eq(encoded_joints.size(), 24, "Body contains exactly 24 encoded joints")
	if encoded_joints.size() != 24:
		return

	_assert_body_joint(t, encoded_joints[0], 0)
	_assert_body_joint(t, encoded_joints[7], 7)
	_assert_body_joint(t, encoded_joints[23], 23)

	(snapshot["body"] as Dictionary).erase("legacy_timestamp_ns")
	encoded = encoder.encode(snapshot)
	t.eq(encoded.get("Body", {}).get("timeStampNs"), TOP_TIMESTAMP_NS,
		"Body falls back to the top-level Unix timestamp")


func _test_body_position_only_joint_uses_identity_rotation(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _snapshot_with_complete_body()
	var body := snapshot["body"] as Dictionary
	var joints := body["joints"] as Array
	var position_only := joints[5] as Dictionary
	position_only["flags"] = 0x2
	position_only["tracked"] = false
	var pose := position_only["pose"] as Dictionary
	pose.erase("rotation")

	var encoded: Dictionary = encoder.encode(snapshot)
	t.contains(encoded, "Body", "position-only Body joints remain compatible")
	var encoded_joints: Array = encoded.get("Body", {}).get("joints", [])
	if encoded_joints.size() != 24:
		return
	_assert_csv(t, encoded_joints[5].get("p", ""), [
		5.25, 5.5, 5.75, 0.0, 0.0, 0.0, 1.0,
	], "position-only Body joint uses identity rotation")


func _test_body_legacy_wire_raw_coordinate_golden(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _snapshot_with_complete_body()
	var body := snapshot["body"] as Dictionary
	var joints := body["joints"] as Array
	var raw_joint := joints[4] as Dictionary
	raw_joint["pose"] = _pose([1.25, -2.5, -3.75], [0.1, -0.2, -0.3, 0.9], 30)

	var encoded: Dictionary = encoder.encode(snapshot)
	var encoded_joints: Array = encoded.get("Body", {}).get("joints", [])
	if encoded_joints.size() != 24:
		return
	# PXR_Plugin flips z/qz/qw into Unity coordinates and TrackingData flips them
	# back, so the legacy wire contract equals the raw PICO/OpenXR coordinates.
	_assert_csv(t, encoded_joints[4].get("p", ""), [
		1.25, -2.5, -3.75, 0.1, -0.2, -0.3, 0.9,
	], "Body legacy wire pose preserves raw coordinates without another flip")


func _test_body_invalid_position_is_omitted(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _snapshot_with_complete_body()
	var body := snapshot["body"] as Dictionary
	var joints := body["joints"] as Array
	var invalid_joint := joints[9] as Dictionary
	invalid_joint["flags"] = 0x1

	var encoded: Dictionary = encoder.encode(snapshot)
	t.is_false(encoded.has("Body"), "Body is omitted when a joint lacks position-valid")

	snapshot = _snapshot_with_complete_body()
	body = snapshot["body"] as Dictionary
	joints = body["joints"] as Array
	invalid_joint = joints[9] as Dictionary
	(invalid_joint["pose"] as Dictionary)["position"] = [0.0, NAN, 0.0]
	encoded = encoder.encode(snapshot)
	t.is_false(encoded.has("Body"), "Body is omitted when a joint position is non-finite")

	snapshot = _snapshot_with_complete_body()
	body = snapshot["body"] as Dictionary
	joints = body["joints"] as Array
	invalid_joint = joints[9] as Dictionary
	(invalid_joint["pose"] as Dictionary)["rotation"] = [0.0, 0.0, INF, 1.0]
	encoded = encoder.encode(snapshot)
	t.is_false(encoded.has("Body"),
		"Body is omitted when a rotation-valid joint has a non-finite rotation")


func _test_body_timestamps_and_motion_values_are_safe(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _snapshot_with_complete_body()
	var body := snapshot["body"] as Dictionary
	var joints := body["joints"] as Array
	var source_joint := joints[0] as Dictionary
	source_joint["source_timestamp_ns"] = BODY_SOURCE_TIMESTAMP_NS + 500
	source_joint["timestamp_ns"] = BODY_SOURCE_TIMESTAMP_NS + 600
	var fallback_joint := joints[1] as Dictionary
	fallback_joint["source_timestamp_ns"] = 0
	fallback_joint["timestamp_ns"] = -1
	fallback_joint["sample_timestamp_ns"] = 0
	(fallback_joint["pose"] as Dictionary)["sample_timestamp_ns"] = 0
	var unsafe_joint := joints[2] as Dictionary
	unsafe_joint["linear_velocity"] = [NAN, 2.0, INF]
	unsafe_joint["linear_acceleration"] = [4.0, -INF, 6.0]
	unsafe_joint["angular_velocity"] = [7.0, NAN, 9.0]
	unsafe_joint["angular_acceleration"] = [INF, 11.0, 12.0]

	var encoded: Dictionary = encoder.encode(snapshot)
	var encoded_joints: Array = encoded.get("Body", {}).get("joints", [])
	if encoded_joints.size() != 24:
		return
	t.eq(encoded_joints[0].get("t"), BODY_SOURCE_TIMESTAMP_NS + 500,
		"positive Body source joint timestamp has highest priority")
	t.eq(encoded_joints[1].get("t"), BODY_SOURCE_TIMESTAMP_NS,
		"invalid Body joint timestamps fall back to the Body source timestamp")
	_assert_csv(t, encoded_joints[2].get("va", ""), [0.0, 2.0, 0.0, 4.0, 0.0, 6.0],
		"Body linear motion components neutralize NaN and Inf")
	_assert_csv(t, encoded_joints[2].get("wva", ""), [7.0, 0.0, 9.0, 0.0, 11.0, 12.0],
		"Body angular motion components neutralize NaN and Inf")


func _test_incomplete_body_is_omitted(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _base_snapshot()
	var joints: Array = []
	for joint_index in range(23):
		joints.append(_body_joint(joint_index))
	snapshot["body"] = {
		"active": true,
		"joint_set": "pico_bd_24",
		"sample_timestamp_ns": 8_000_000_000,
		"joints": joints,
	}

	var encoded: Dictionary = encoder.encode(snapshot)
	t.is_false(encoded.has("Body"), "an incomplete 23-joint body is omitted")

	snapshot["body"]["joints"] = _complete_body_joints()
	snapshot["body"]["joint_set"] = "godot_xr_body_tracker_v1"
	encoded = encoder.encode(snapshot)
	t.is_false(encoded.has("Body"), "non-Pico body layouts are omitted")

	encoded = encoder.encode(_snapshot_with_complete_body(), false)
	t.is_false(encoded.has("Body"), "include_body=false suppresses a valid body sample")


func _test_hand_contract_and_invalid_omission(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _base_snapshot()
	snapshot["hands"] = {"left": _complete_hand()}

	var encoded: Dictionary = encoder.encode(snapshot, false)
	var left: Dictionary = encoded.get("Hand", {}).get("leftHand", {})
	t.eq(left.get("count"), 26, "Hand declares exactly 26 joints")
	t.eq(left.get("scale"), 0.95, "finite Hand scale is preserved")
	var encoded_joints: Array = left.get("HandJointLocations", [])
	t.eq(encoded_joints.size(), 26, "Hand emits exactly 26 joint locations")
	if encoded_joints.size() == 26:
		_assert_csv(t, encoded_joints[25].get("p", ""), [
			25.1, 25.2, 25.3, 0.0, 0.0, 0.0, 1.0,
		], "Hand joint pose is encoded in legacy order")
		t.eq(encoded_joints[25].get("r"), 0.025, "finite Hand radius is preserved")

	var invalid_hand := _complete_hand()
	var invalid_joints := invalid_hand["joints"] as Array
	((invalid_joints[3] as Dictionary)["pose"] as Dictionary)["position"] = [NAN, 0.0, 0.0]
	snapshot["hands"] = {"left": invalid_hand}
	encoded = encoder.encode(snapshot, false)
	t.is_false(encoded.has("Hand"), "one invalid joint omits the entire Hand")

	invalid_hand = _complete_hand()
	invalid_joints = invalid_hand["joints"] as Array
	invalid_joints.pop_back()
	snapshot["hands"] = {"left": invalid_hand}
	encoded = encoder.encode(snapshot, false)
	t.is_false(encoded.has("Hand"), "a 25-joint Hand is omitted")

	invalid_hand = _complete_hand()
	invalid_joints = invalid_hand["joints"] as Array
	((invalid_joints[2] as Dictionary)["pose"] as Dictionary)["valid"] = false
	snapshot["hands"] = {"left": invalid_hand}
	encoded = encoder.encode(snapshot, false)
	t.is_false(encoded.has("Hand"), "an explicitly invalid joint omits the entire Hand")

	invalid_hand = _complete_hand()
	invalid_hand["scale"] = INF
	snapshot["hands"] = {"left": invalid_hand}
	encoded = encoder.encode(snapshot, false)
	t.is_false(encoded.has("Hand"), "non-finite Hand scale omits the entire Hand")

	invalid_hand = _complete_hand()
	invalid_joints = invalid_hand["joints"] as Array
	(invalid_joints[4] as Dictionary)["radius_m"] = NAN
	snapshot["hands"] = {"left": invalid_hand}
	encoded = encoder.encode(snapshot, false)
	t.is_false(encoded.has("Hand"), "non-finite Hand radius omits the entire Hand")


func _test_hand_quaternion_removes_godot_bone_adjustment(
		t: OperatorTestAssertions,
	) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _base_snapshot()
	var hand := _complete_hand()
	var joints := hand["joints"] as Array
	var legacy_rotation := Quaternion(
		0.18257418583505536,
		-0.3651483716701107,
		0.5477225575051661,
		0.7302967433402214,
	)
	(joints[7] as Dictionary)["pose"] = _pose(
		[1.25, -2.5, 3.75],
		[
			0.12909944487358055,
			-0.6454972243679028,
			0.3872983346207417,
			-0.6454972243679028,
		],
		9_000_000_007,
	)
	snapshot["hands"] = {"left": hand}

	var encoded: Dictionary = encoder.encode(snapshot, false)
	var encoded_joints: Array = encoded.get("Hand", {}).get(
		"leftHand", {}).get("HandJointLocations", [])
	t.eq(encoded_joints.size(), 26, "Hand adjustment fixture emits every joint")
	if encoded_joints.size() != 26:
		return
	_assert_csv(t, encoded_joints[7].get("p", ""), [
		1.25,
		-2.5,
		3.75,
		legacy_rotation.x,
		legacy_rotation.y,
		legacy_rotation.z,
		legacy_rotation.w,
	], "Hand pose preserves position and restores legacy raw quaternion")


func _test_motion_vectors_are_finite(t: OperatorTestAssertions) -> void:
	var encoder = XrtTrackingEncoderScript.new()
	var snapshot := _base_snapshot()
	snapshot["motion_trackers"] = [{
		"id": "tracker-raw",
		"pose": _pose([1.0, 2.0, 3.0], [0.0, 0.0, 0.0, 1.0], 20),
		"linear_velocity": [NAN, 2.0, INF],
		"angular_velocity": [4.0, -INF, 6.0],
		"linear_acceleration": [7.0, NAN, 9.0],
		"angular_acceleration": [INF, 11.0, 12.0],
	}, {
		"id": "invalid-pose",
		"pose": _pose([NAN, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0], 21),
	}]

	var encoded: Dictionary = encoder.encode(snapshot, false)
	var motion: Dictionary = encoded.get("Motion", {})
	t.eq(motion.get("len"), 1, "Motion skips trackers with invalid poses")
	var joints: Array = motion.get("joints", [])
	if joints.size() != 1:
		return
	_assert_csv(t, joints[0].get("va", ""), [0.0, 2.0, 0.0, 4.0, 0.0, 6.0],
		"Motion velocity components neutralize NaN and Inf")
	_assert_csv(t, joints[0].get("wva", ""), [7.0, 0.0, 9.0, 0.0, 11.0, 12.0],
		"Motion acceleration components neutralize NaN and Inf")


func _base_snapshot() -> Dictionary:
	var left_values := {
		"primary_x": 0.25,
		"primary_y": -0.5,
		"primary_click": true,
		"trigger": 0.75,
		"grip": 0.5,
		"ax_button": true,
		"by_button": false,
		"menu_button": true,
	}
	return {
		"timestamp_ns": TOP_TIMESTAMP_NS,
		"predicted_display_time_ns": PREDICTED_DISPLAY_TIME_NS,
		"head": _pose([1.25, -2.5, 3.75], [0.1, 0.2, 0.3, 0.9], 9_876_543_200),
		"controllers": {
			"left": {
				"pose": _pose([4.0, 5.0, 6.0], [-0.1, -0.2, -0.3, 0.9], 9_876_543_201),
				"input": {
					"sample_timestamp_ns": 9_876_543_202,
					"values": left_values.duplicate(true),
					"primary_x": left_values["primary_x"],
					"primary_y": left_values["primary_y"],
					"primary_click": left_values["primary_click"],
					"trigger": left_values["trigger"],
					"grip": left_values["grip"],
					"ax_button": left_values["ax_button"],
					"by_button": left_values["by_button"],
					"menu_button": left_values["menu_button"],
				},
			},
		},
		"hands": {},
		"body": null,
		"motion_trackers": [],
	}


func _snapshot_with_complete_body() -> Dictionary:
	var snapshot := _base_snapshot()
	snapshot["body"] = {
		"active": true,
		"joint_set": "pico_bd_24",
		"sample_timestamp_ns": BODY_SOURCE_TIMESTAMP_NS,
		"legacy_timestamp_ns": BODY_LEGACY_TIMESTAMP_NS,
		"joints": _complete_body_joints(),
	}
	return snapshot


func _complete_body_joints() -> Array:
	var joints: Array = []
	for joint_index in range(24):
		joints.append(_body_joint(joint_index))
	return joints


func _body_joint(joint_index: int) -> Dictionary:
	var timestamp_ns := BODY_SOURCE_TIMESTAMP_NS + 100 + joint_index
	var position := [joint_index + 0.25, joint_index + 0.5, joint_index + 0.75]
	var rotation := [0.1, 0.2, 0.3, 0.9]
	return {
		"joint": joint_index,
		"flags": 15,
		"tracked": true,
		"timestamp_ns": timestamp_ns,
		"sample_timestamp_ns": timestamp_ns,
		"position": position,
		"rotation": rotation,
		"pose": _pose(position, rotation, timestamp_ns),
		"linear_velocity": [joint_index + 1.0, joint_index + 2.0, joint_index + 3.0],
		"linear_acceleration": [joint_index + 4.0, joint_index + 5.0, joint_index + 6.0],
		"angular_velocity": [joint_index + 7.0, joint_index + 8.0, joint_index + 9.0],
		"angular_acceleration": [joint_index + 10.0, joint_index + 11.0, joint_index + 12.0],
	}


func _complete_hand() -> Dictionary:
	var joints: Array = []
	for joint_index in range(26):
		joints.append({
			"joint": joint_index,
			"flags": 3,
			"tracked": true,
			"radius_m": float(joint_index) / 1000.0,
			"pose": _pose([
				joint_index + 0.1,
				joint_index + 0.2,
				joint_index + 0.3,
			], [
				GODOT_HAND_BONE_ADJUSTMENT.x,
				GODOT_HAND_BONE_ADJUSTMENT.y,
				GODOT_HAND_BONE_ADJUSTMENT.z,
				GODOT_HAND_BONE_ADJUSTMENT.w,
			], 9_000_000_000 + joint_index),
		})
	return {
		"active": true,
		"scale": 0.95,
		"joints": joints,
	}


func _pose(position: Array, rotation: Array, timestamp_ns: int) -> Dictionary:
	return {
		"valid": true,
		"sample_timestamp_ns": timestamp_ns,
		"position": position,
		"rotation": rotation,
	}


func _assert_body_joint(
		t: OperatorTestAssertions,
		joint_value: Variant,
		expected_index: int,
	) -> void:
	t.is_true(joint_value is Dictionary, "Body joint %d is an object" % expected_index)
	if not (joint_value is Dictionary):
		return
	var joint := joint_value as Dictionary
	t.eq(joint.get("t"), BODY_SOURCE_TIMESTAMP_NS + 100 + expected_index,
		"Body joint %d preserves its source timestamp" % expected_index)
	_assert_csv(t, joint.get("p", ""), [
		expected_index + 0.25,
		expected_index + 0.5,
		expected_index + 0.75,
		0.1,
		0.2,
		0.3,
		0.9,
	], "Body joint %d preserves legacy raw coordinates" % expected_index)
	_assert_csv(t, joint.get("va", ""), [
		expected_index + 1.0,
		expected_index + 2.0,
		expected_index + 3.0,
		expected_index + 4.0,
		expected_index + 5.0,
		expected_index + 6.0,
	], "Body joint %d linear velocity and acceleration are encoded" % expected_index)
	_assert_csv(t, joint.get("wva", ""), [
		expected_index + 7.0,
		expected_index + 8.0,
		expected_index + 9.0,
		expected_index + 10.0,
		expected_index + 11.0,
		expected_index + 12.0,
	], "Body joint %d angular velocity and acceleration are encoded" % expected_index)


func _assert_identity_pose(t: OperatorTestAssertions, actual: Variant, message: String) -> void:
	_assert_csv(t, actual, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], message)


func _assert_csv(
		t: OperatorTestAssertions,
		actual: Variant,
		expected: Array,
		message: String,
	) -> void:
	t.eq(typeof(actual), TYPE_STRING, "%s is a comma-separated string" % message)
	if typeof(actual) != TYPE_STRING:
		return
	var fields := str(actual).split(",")
	t.eq(fields.size(), expected.size(), "%s has the expected field count" % message)
	if fields.size() != expected.size():
		return
	for field_index in range(expected.size()):
		t.almost_eq(float(fields[field_index]), float(expected[field_index]), 0.000001,
			"%s at field %d" % [message, field_index])
