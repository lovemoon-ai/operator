class_name IsaacTeleopPacketCodec
extends RefCounted
## Operator -> IsaacTeleop UDP wire codec.
##
## All integers and floats are little-endian.  The fixed header is shared
## with xr-bridge's extension gateway:
##   timestamp:u64, sequence:u64, session_token:u32,
##   descriptor_version:u16, payload_len:u16, payload_crc16:u16,
##   flags:u8, reserved:u8, kind:[u8;4].
##
## CRC is CRC-16/CCITT-FALSE over the payload only.  Keeping the codec in
## GDScript makes the first integration usable without an Android native
## plugin; a future FlatBuffers GDExtension can replace only this class.

const HEADER_SIZE := 32
const POSE_SIZE := 29 # <B7f>
const CONTROLLER_INPUT_SIZE := 20 # <BBBBffff>
const JOINT_SIZE := POSE_SIZE + 4

const FLAG_NONE := 0

const KIND_HEAD := "HEAD"
const KIND_LEFT_CONTROLLER := "LCTL"
const KIND_RIGHT_CONTROLLER := "RCTL"
const KIND_LEFT_HAND := "LHND"
const KIND_RIGHT_HAND := "RHND"
const KIND_BODY := "BODY"
const KIND_CONTROL := "CTRL"
const KIND_ANCHOR := "ANCH"


static func encode_packet(
	kind: String,
	timestamp_ns: int,
	sequence: int,
	session_token: int,
	descriptor_version: int,
	payload: PackedByteArray,
	flags: int = FLAG_NONE
) -> PackedByteArray:
	var kind_bytes := kind.to_ascii_buffer()
	if kind_bytes.size() != 4 or payload.size() > 0xffff:
		return PackedByteArray()

	var packet := PackedByteArray()
	packet.resize(HEADER_SIZE + payload.size())
	packet.encode_u64(0, timestamp_ns)
	packet.encode_u64(8, sequence)
	packet.encode_u32(16, session_token)
	packet.encode_u16(20, descriptor_version)
	packet.encode_u16(22, payload.size())
	packet.encode_u16(24, crc16_ccitt(payload))
	packet[26] = flags & 0xff
	packet[27] = 0
	for i in range(4):
		packet[28 + i] = kind_bytes[i]
	for i in range(payload.size()):
		packet[HEADER_SIZE + i] = payload[i]
	return packet


## CRC-16/CCITT-FALSE: polynomial 0x1021, initial value 0xffff, no reflection.
static func crc16_ccitt(bytes: PackedByteArray) -> int:
	var crc := 0xffff
	for byte in bytes:
		crc ^= int(byte) << 8
		for _bit in range(8):
			if (crc & 0x8000) != 0:
				crc = ((crc << 1) ^ 0x1021) & 0xffff
			else:
				crc = (crc << 1) & 0xffff
	return crc


## Canonical pose payload: valid byte, position xyz, quaternion xyzw.
static func encode_pose(transform: Transform3D, valid: bool) -> PackedByteArray:
	var payload := PackedByteArray()
	payload.resize(POSE_SIZE)
	var position := transform.origin
	var rotation := Quaternion.IDENTITY
	var clean_valid := valid and _transform_finite(transform)
	if clean_valid:
		rotation = transform.basis.get_rotation_quaternion()
		clean_valid = _quaternion_finite(rotation) and rotation.length_squared() > 0.000001
	if not clean_valid:
		# Invalid records must not leak NaN/Inf, nor look like a usable identity
		# pose to a consumer that is inspecting fields before the validity byte.
		return payload
	rotation = rotation.normalized()
	payload[0] = 1
	payload.encode_float(1, position.x)
	payload.encode_float(5, position.y)
	payload.encode_float(9, position.z)
	payload.encode_float(13, rotation.x)
	payload.encode_float(17, rotation.y)
	payload.encode_float(21, rotation.z)
	payload.encode_float(25, rotation.w)
	return payload


## Canonical controller snapshot: grip pose, aim pose, then
## primary/secondary/thumb-click/menu and thumbstick x/y/squeeze/trigger.
static func encode_controller(
	grip_transform: Transform3D,
	grip_valid: bool,
	aim_transform: Transform3D,
	aim_valid: bool,
	input: Dictionary
) -> PackedByteArray:
	var payload := encode_pose(grip_transform, grip_valid)
	payload.append_array(encode_pose(aim_transform, aim_valid))
	var input_offset := payload.size()
	payload.resize(input_offset + CONTROLLER_INPUT_SIZE)
	payload[input_offset] = 1 if bool(input.get("primary_pressed", false)) else 0
	payload[input_offset + 1] = 1 if bool(input.get("secondary_pressed", false)) else 0
	payload[input_offset + 2] = 1 if bool(input.get("thumb_click", false)) else 0
	payload[input_offset + 3] = 1 if bool(input.get("menu_pressed", false)) else 0
	var thumbstick := input.get("thumbstick", Vector2.ZERO) as Vector2
	payload.encode_float(input_offset + 4, clampf(_finite_float(thumbstick.x), -1.0, 1.0))
	payload.encode_float(input_offset + 8, clampf(_finite_float(thumbstick.y), -1.0, 1.0))
	payload.encode_float(input_offset + 12,
		clampf(_finite_float(float(input.get("grip", 0.0))), 0.0, 1.0))
	payload.encode_float(input_offset + 16,
		clampf(_finite_float(float(input.get("trigger", 0.0))), 0.0, 1.0))
	return payload


## Canonical hand/body payload.  `count_hint` makes sparse joint arrays retain
## their semantic indices (26 for OpenXR hands, 24 for Pico body, 87 for Meta).
## Each input joint may use Vector3/Quaternion, dictionary xyz/xyzw, a
## Transform3D, and either `radius` or `radius_m`.
static func encode_joints(
	joints: Array,
	count_hint: int = 0,
	frame_valid: bool = true
) -> PackedByteArray:
	var count := maxi(count_hint, joints.size())
	for joint_v in joints:
		if joint_v is Dictionary:
			count = maxi(count, int((joint_v as Dictionary).get("joint", -1)) + 1)
	count = clampi(count, 0, 0xffff)

	var indexed: Dictionary = {}
	for array_index in range(joints.size()):
		var joint_v: Variant = joints[array_index]
		if not (joint_v is Dictionary):
			continue
		var joint := joint_v as Dictionary
		var joint_index := int(joint.get("joint", array_index))
		if joint_index >= 0 and joint_index < count:
			indexed[joint_index] = joint

	var payload := PackedByteArray()
	payload.resize(2)
	payload.encode_u16(0, count)
	for index in range(count):
		var joint: Dictionary = indexed.get(index, {})
		var valid := frame_valid and _joint_valid(joint)
		payload.append_array(encode_pose(_joint_transform(joint), valid))
		var radius_offset := payload.size()
		payload.resize(radius_offset + 4)
		var radius := _finite_float(float(joint.get("radius_m", joint.get("radius", 0.0))))
		payload.encode_float(radius_offset, maxf(0.0, radius) if valid else 0.0)
	return payload


## CTRL fields: kill, run-toggle pulse, reset pulse, deadman held.
static func encode_control(
	kill: bool,
	run_toggle: bool,
	reset: bool,
	deadman: bool
) -> PackedByteArray:
	return PackedByteArray([
		1 if kill else 0,
		1 if run_toggle else 0,
		1 if reset else 0,
		1 if deadman else 0,
	])


static func _joint_valid(joint: Dictionary) -> bool:
	if joint.is_empty():
		return false
	var tracked := joint.has("transform") or joint.has("position")
	if joint.has("valid"):
		tracked = bool(joint["valid"])
	elif joint.has("tracked"):
		tracked = bool(joint["tracked"])
	elif joint.has("flags"):
		tracked = int(joint["flags"]) != 0
	if not tracked:
		return false
	var transform_v: Variant = joint.get("transform", null)
	if transform_v is Transform3D:
		return _transform_finite(transform_v as Transform3D)
	var position := _vector3(joint.get("position", Vector3.ZERO))
	var rotation := _quaternion(joint.get("rotation", Quaternion.IDENTITY))
	return _vector3_finite(position) and _quaternion_finite(rotation) \
		and rotation.length_squared() > 0.000001


static func _joint_transform(joint: Dictionary) -> Transform3D:
	var transform_v: Variant = joint.get("transform", null)
	if transform_v is Transform3D:
		return transform_v as Transform3D
	var position := _vector3(joint.get("position", Vector3.ZERO))
	var rotation := _quaternion(joint.get("rotation", Quaternion.IDENTITY))
	return Transform3D(Basis(rotation), position)


static func _vector3(value: Variant) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3(float(dict.get("x", 0.0)), float(dict.get("y", 0.0)), float(dict.get("z", 0.0)))
	if value is Array and (value as Array).size() >= 3:
		var array := value as Array
		return Vector3(float(array[0]), float(array[1]), float(array[2]))
	return Vector3.ZERO


static func _quaternion(value: Variant) -> Quaternion:
	if value is Quaternion:
		return value as Quaternion
	if value is Dictionary:
		var dict := value as Dictionary
		return Quaternion(
			float(dict.get("x", 0.0)), float(dict.get("y", 0.0)),
			float(dict.get("z", 0.0)), float(dict.get("w", 1.0)))
	if value is Array and (value as Array).size() >= 4:
		var array := value as Array
		return Quaternion(
			float(array[0]), float(array[1]), float(array[2]), float(array[3]))
	return Quaternion.IDENTITY


static func _transform_finite(value: Transform3D) -> bool:
	return _vector3_finite(value.origin) \
		and _vector3_finite(value.basis.x) \
		and _vector3_finite(value.basis.y) \
		and _vector3_finite(value.basis.z)


static func _vector3_finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _quaternion_finite(value: Quaternion) -> bool:
	return is_finite(value.x) and is_finite(value.y) \
		and is_finite(value.z) and is_finite(value.w)


static func _finite_float(value: float) -> float:
	return value if is_finite(value) else 0.0
