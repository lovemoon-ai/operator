extends RefCounted
## Golden-layout checks for the Operator -> IsaacTeleop UDP codec.

const CASE_ID := "isaac_teleop.packet_codec"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	# Published CRC-16/CCITT-FALSE check vector.
	var check_bytes := "123456789".to_ascii_buffer()
	t.eq(IsaacTeleopPacketCodec.crc16_ccitt(check_bytes), 0x29b1,
		"CRC-16/CCITT-FALSE check vector must match")

	var transform := Transform3D(Basis(Quaternion.IDENTITY), Vector3(1.0, 2.0, 3.0))
	var pose := IsaacTeleopPacketCodec.encode_pose(transform, true)
	t.eq(pose.size(), 29, "canonical pose is <B7f>")
	t.eq(int(pose[0]), 1, "valid pose carries valid=1")
	t.almost_eq(pose.decode_float(1), 1.0, 0.0001, "pose x is little-endian float")
	t.almost_eq(pose.decode_float(25), 1.0, 0.0001, "identity quaternion w is encoded")
	var bad_transform := Transform3D.IDENTITY
	bad_transform.origin = Vector3(NAN, 0.0, 0.0)
	var sanitized := IsaacTeleopPacketCodec.encode_pose(bad_transform, true)
	t.eq(int(sanitized[0]), 0, "non-finite pose is downgraded to invalid")
	t.almost_eq(sanitized.decode_float(1), 0.0, 0.0, "invalid pose fields are zeroed")

	var input := {
		"primary_pressed": true,
		"secondary_pressed": false,
		"thumb_click": true,
		"menu_pressed": true,
		"thumbstick": Vector2(0.25, -0.5),
		"grip": 0.75,
		"trigger": 1.0,
	}
	var controller := IsaacTeleopPacketCodec.encode_controller(
		transform, true, Transform3D.IDENTITY, false, input)
	t.eq(controller.size(), 78, "controller is two poses plus <BBBBffff>")
	t.eq(int(controller[29]), 0, "missing aim pose stays explicitly invalid")
	t.eq(int(controller[58]), 1, "primary button is encoded first")
	t.eq(int(controller[60]), 1, "thumb click is encoded third")
	t.almost_eq(controller.decode_float(62), 0.25, 0.0001, "thumbstick x follows buttons")
	t.almost_eq(controller.decode_float(74), 1.0, 0.0001, "trigger is final controller float")

	var packet := IsaacTeleopPacketCodec.encode_packet(
		IsaacTeleopPacketCodec.KIND_HEAD, 1000, 7, 23, 1, pose)
	t.eq(packet.size(), 32 + pose.size(), "packet uses fixed 32-byte header")
	t.eq(packet.decode_u64(0), 1000, "header timestamp offset")
	t.eq(packet.decode_u64(8), 7, "header sequence offset")
	t.eq(packet.decode_u32(16), 23, "header token offset")
	t.eq(packet.decode_u16(20), 1, "header descriptor version offset")
	t.eq(packet.decode_u16(22), pose.size(), "header payload length offset")
	t.eq(packet.decode_u16(24), IsaacTeleopPacketCodec.crc16_ccitt(pose),
		"header CRC covers payload only")
	t.eq(packet.slice(28, 32).get_string_from_ascii(), "HEAD", "kind occupies final four header bytes")

	var joints := [{
		"joint": 1,
		"flags": 1,
		"position": {"x": 0.1, "y": 0.2, "z": 0.3},
		"rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
		"radius_m": 0.01,
	}]
	var hand := IsaacTeleopPacketCodec.encode_joints(joints, 2, true)
	t.eq(hand.decode_u16(0), 2, "sparse joints retain canonical count")
	t.eq(int(hand[2]), 0, "missing joint index is serialized invalid")
	t.eq(int(hand[2 + IsaacTeleopPacketCodec.JOINT_SIZE]), 1,
		"tracked joint keeps its semantic index")
	var canonical_hand := IsaacTeleopPacketCodec.encode_joints([], 26, true)
	t.eq(canonical_hand.decode_u16(0), 26, "hand wire payload always has 26 joints")
	t.eq(canonical_hand.size(), 2 + 26 * IsaacTeleopPacketCodec.JOINT_SIZE,
		"26-joint hand length matches Python decoder contract")
	var canonical_body := IsaacTeleopPacketCodec.encode_joints([], 24, true)
	t.eq(canonical_body.decode_u16(0), 24, "body wire payload always has 24 joints")

	var policy := IsaacTeleopControlPolicy.new()
	policy.configure(true, 0.5)
	var control := policy.sample({"grip": 0.8, "ax_button": 1.0})
	t.is_true(bool(control["deadman"]), "grip holds the default deadman")
	t.is_true(bool(control["run_toggle"]), "primary rising edge pulses run toggle")
	control = policy.sample({"grip": 0.8, "ax_button": 1.0})
	t.is_false(bool(control["run_toggle"]), "held primary does not repeat run toggle")
	control = policy.sample({"grip": 0.8, "by_button": 1.0})
	t.is_true(bool(control["reset"]), "secondary rising edge pulses reset")
	control = policy.sample({})
	t.is_false(bool(control["deadman"]), "missing grip releases the safe default deadman")
	t.is_true(bool(policy.kill_sample()["kill"]), "disconnect sample asserts kill")
