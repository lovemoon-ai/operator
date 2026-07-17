extends RefCounted
## Semantic and wire-compatibility checks for BODY v1 normalization.

const CASE_ID := "isaac_teleop.body_mapper"

const EXPECTED_GODOT87_TO_PICO24: Array[int] = [
	1, 14, 18, 2, 15, 19, 3, 16, 20, 4, 17, 21,
	5, 8, 11, 6, 9, 12, 10, 13, 24, 51, 23, 50,
]


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	t.eq(IsaacTeleopBodyMapper.GODOT87_TO_PICO24, EXPECTED_GODOT87_TO_PICO24,
		"Meta/Godot projection uses the reviewed BD topology")
	_test_full_meta_mapping(t)
	_test_sparse_meta_validity(t)
	_test_pico_passthrough(t)
	_test_source_classification(t)


func _test_full_meta_mapping(t: OperatorTestAssertions) -> void:
	var source_joints: Array = []
	for source_index in EXPECTED_GODOT87_TO_PICO24:
		source_joints.push_front(_joint(source_index, 5, float(source_index)))
	# Duplicate ids use the codec's existing last-record-wins policy.
	source_joints.append(_joint(1, 5, 1001.0))
	var source_snapshot := source_joints.duplicate(true)

	var result := IsaacTeleopBodyMapper.to_pico24(
		source_joints, "godot_xr_body_tracker", true)
	t.is_true(bool(result.get("ok", false)), "Meta/Godot body frames are accepted")
	t.eq(String(result.get("mapping", "")), "godot87_to_pico24",
		"Meta/Godot frames report the semantic projection")
	t.eq(int(result.get("mapped_joint_count", -1)), 24,
		"all 24 BD targets are found in a full Meta frame")
	t.eq(int(result.get("valid_joint_count", -1)), 24,
		"flags=5 supplies both required pose components")

	var mapped: Array = result.get("joints", [])
	t.eq(mapped.size(), 24, "Meta/Godot projection always emits exactly 24 slots")
	for target_index in range(mapped.size()):
		var record := mapped[target_index] as Dictionary
		var expected_source := EXPECTED_GODOT87_TO_PICO24[target_index]
		t.eq(int(record.get("joint", -1)), target_index,
			"mapped record keeps BD target index %d" % target_index)
		t.eq(int(record.get("source_joint", -1)), expected_source,
			"BD target %d comes from the reviewed Godot joint" % target_index)
		var expected_x := 1001.0 if target_index == 0 else float(expected_source)
		var position := record.get("position", {}) as Dictionary
		t.almost_eq(float(position.get("x", -1.0)), expected_x, 0.0001,
			"BD target %d preserves its source pose" % target_index)
		t.is_true(bool(record.get("valid", false)),
			"BD target %d is valid when both pose flags are valid" % target_index)

	t.eq(source_joints, source_snapshot, "mapping does not mutate source body records")
	var payload := IsaacTeleopPacketCodec.encode_joints(mapped, 24, true)
	t.eq(payload.decode_u16(0), 24, "mapped BODY packet retains the v1 24-joint ABI")
	t.eq(payload.size(), 2 + 24 * IsaacTeleopPacketCodec.JOINT_SIZE,
		"mapped BODY packet cannot accidentally grow back to 87 joints")


func _test_sparse_meta_validity(t: OperatorTestAssertions) -> void:
	var source_joints: Array = [
		_joint(8, 0, 8.0),
		_joint(9, 1, 9.0),
		_joint(10, 4, 10.0),
		_joint(13, 5, 13.0),
		_joint(24, 15, 24.0),
		_joint(51, 5, NAN),
	]
	var result := IsaacTeleopBodyMapper.to_pico24(
		source_joints, "godot_xr_body_tracker", true)
	var mapped: Array = result.get("joints", [])
	t.eq(mapped.size(), 24, "sparse Meta input still produces 24 BD slots")
	t.is_false(bool((mapped[13] as Dictionary).get("valid", true)),
		"flags=0 is invalid")
	t.is_false(bool((mapped[16] as Dictionary).get("valid", true)),
		"orientation-only flags are invalid")
	t.is_false(bool((mapped[18] as Dictionary).get("valid", true)),
		"position-only flags are invalid")
	t.is_true(bool((mapped[19] as Dictionary).get("valid", false)),
		"flags=5 carries valid orientation and position")
	t.is_true(bool((mapped[20] as Dictionary).get("valid", false)),
		"flags=15 carries a fully tracked pose")
	t.is_false(bool((mapped[0] as Dictionary).get("valid", true)),
		"a missing target joint remains explicitly invalid")

	var payload := IsaacTeleopPacketCodec.encode_joints(mapped, 24, true)
	var right_wrist_offset := 2 + 21 * IsaacTeleopPacketCodec.JOINT_SIZE
	t.eq(int(payload[right_wrist_offset]), 0,
		"non-finite Meta poses are sanitized by the shared packet codec")

	var invalid_frame := IsaacTeleopBodyMapper.to_pico24(
		source_joints, "godot_xr_body_tracker", false)
	t.eq(int(invalid_frame.get("valid_joint_count", -1)), 0,
		"an invalid source frame cannot produce valid target joints")


func _test_pico_passthrough(t: OperatorTestAssertions) -> void:
	var pico_joints: Array = []
	for joint_index in range(24):
		pico_joints.push_front(_joint(joint_index, 15, float(joint_index)))
	var original_payload := IsaacTeleopPacketCodec.encode_joints(pico_joints, 24, true)
	var result := IsaacTeleopBodyMapper.to_pico24(pico_joints, "pico_bd", true)
	t.is_true(bool(result.get("ok", false)), "Pico BODY frames remain accepted")
	t.eq(String(result.get("mapping", "")), "pico24_identity",
		"Pico frames use identity normalization")
	var normalized_payload := IsaacTeleopPacketCodec.encode_joints(
		result.get("joints", []), 24, true)
	t.eq(normalized_payload, original_payload,
		"normalizing a Pico frame is byte-compatible with the previous BODY path")


func _test_source_classification(t: OperatorTestAssertions) -> void:
	var anonymous_pico: Array = []
	for joint_index in range(24):
		anonymous_pico.append(_joint(joint_index, 15, float(joint_index)))
	var pico_result := IsaacTeleopBodyMapper.to_pico24(anonymous_pico)
	t.is_true(bool(pico_result.get("ok", false)),
		"legacy anonymous 24-joint Pico frames remain accepted")

	var inferred_meta := IsaacTeleopBodyMapper.to_pico24([_joint(51, 5, 1.0)])
	t.eq(String(inferred_meta.get("mapping", "")), "godot87_to_pico24",
		"a high sparse joint id identifies an anonymous Godot frame")

	var ambiguous := IsaacTeleopBodyMapper.to_pico24([_joint(1, 5, 1.0)])
	t.is_false(bool(ambiguous.get("ok", true)),
		"ambiguous sparse frames require a runtime instead of guessing")

	var bad_pico := IsaacTeleopBodyMapper.to_pico24(
		[_joint(24, 15, 1.0)], "pico_bd")
	t.is_false(bool(bad_pico.get("ok", true)),
		"a Pico runtime cannot smuggle a 25th joint into BODY v1")


func _joint(joint_index: int, flags: int, x: float) -> Dictionary:
	return {
		"joint": joint_index,
		"flags": flags,
		"position": {"x": x, "y": 0.0, "z": 0.0},
		"rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
		"radius_m": 0.01,
	}
