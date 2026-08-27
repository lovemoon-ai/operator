class_name XrtCameraProtocol
extends RefCounted
## XRoboToolkit camera-command and FPV video framing.
##
## Command frame:
##   [u32 body length, big-endian]
##   [i32 command length, little-endian]
##   [UTF-8 command]
##   [i32 payload length, little-endian]
##   [payload]
##
## Video frame:
##   [u32 access-unit length, big-endian]
##   [Annex-B H.264 access unit]

const COMMAND_OPEN_CAMERA := "OPEN_CAMERA"
const COMMAND_CLOSE_CAMERA := "CLOSE_CAMERA"

const CAMERA_MAGIC_0 := 0xCA
const CAMERA_MAGIC_1 := 0xFE
const CAMERA_PAYLOAD_VERSION := 1

const MAX_COMMAND_NAME_SIZE := 256
const MAX_COMMAND_PAYLOAD_SIZE := 64 * 1024
const MAX_COMMAND_BODY_SIZE := 4 + MAX_COMMAND_NAME_SIZE + 4 + MAX_COMMAND_PAYLOAD_SIZE
const MAX_VIDEO_ACCESS_UNIT_SIZE := 16 * 1024 * 1024


static func encode_command(
		command: String,
		payload: PackedByteArray = PackedByteArray()
	) -> PackedByteArray:
	var command_bytes := command.to_utf8_buffer()
	if command_bytes.is_empty() or command_bytes.size() > MAX_COMMAND_NAME_SIZE:
		push_error("XRoboToolkit camera command length is invalid: %d" % command_bytes.size())
		return PackedByteArray()
	if payload.size() > MAX_COMMAND_PAYLOAD_SIZE:
		push_error("XRoboToolkit camera payload is too large: %d" % payload.size())
		return PackedByteArray()

	var body_size := 4 + command_bytes.size() + 4 + payload.size()
	var frame := PackedByteArray()
	frame.resize(8)
	_write_u32_be(frame, 0, body_size)
	frame.encode_s32(4, command_bytes.size())
	frame.append_array(command_bytes)

	var payload_size_field := PackedByteArray()
	payload_size_field.resize(4)
	payload_size_field.encode_s32(0, payload.size())
	frame.append_array(payload_size_field)
	frame.append_array(payload)
	return frame


static func encode_open_camera(options: Dictionary) -> PackedByteArray:
	var payload := encode_open_camera_payload(options)
	if payload.is_empty():
		return PackedByteArray()
	return encode_command(COMMAND_OPEN_CAMERA, payload)


static func encode_close_camera() -> PackedByteArray:
	return encode_command(COMMAND_CLOSE_CAMERA)


static func encode_open_camera_payload(options: Dictionary) -> PackedByteArray:
	var camera_name := str(options.get("camera_name", "UNITREE_HEAD"))
	var pico_ip := str(options.get("pico_ip", "")).strip_edges()
	var camera_name_bytes := camera_name.to_utf8_buffer()
	var pico_ip_bytes := pico_ip.to_utf8_buffer()
	if camera_name_bytes.is_empty() or camera_name_bytes.size() > 0xFF:
		push_error("XRoboToolkit camera name must contain 1..255 UTF-8 bytes")
		return PackedByteArray()
	if pico_ip_bytes.is_empty() or pico_ip_bytes.size() > 0xFF:
		push_error("XRoboToolkit PICO IP must contain 1..255 UTF-8 bytes")
		return PackedByteArray()

	var payload := PackedByteArray()
	payload.resize(3 + 7 * 4)
	payload[0] = CAMERA_MAGIC_0
	payload[1] = CAMERA_MAGIC_1
	payload[2] = CAMERA_PAYLOAD_VERSION

	var offset := 3
	var values := [
		int(options.get("width", 1280)),
		int(options.get("height", 720)),
		int(options.get("fps", 30)),
		int(options.get("bitrate", 6_000_000)),
		int(options.get("enable_mv_hevc", 0)),
		int(options.get("render_mode", 2)),
		int(options.get("listen_port", 0)),
	]
	for value in values:
		payload.encode_s32(offset, value)
		offset += 4

	payload.append(camera_name_bytes.size())
	payload.append_array(camera_name_bytes)
	payload.append(pico_ip_bytes.size())
	payload.append_array(pico_ip_bytes)
	return payload


## Returns an empty dictionary when more bytes are needed, or an `error` key
## for malformed input. A successful result includes `bytes_consumed`.
static func decode_command_frame(buffer: PackedByteArray, start: int = 0) -> Dictionary:
	if start < 0 or start > buffer.size():
		return {"error": "invalid command frame offset"}
	var available := buffer.size() - start
	if available < 4:
		return {}

	var body_size := _read_u32_be(buffer, start)
	if body_size < 8 or body_size > MAX_COMMAND_BODY_SIZE:
		return {"error": "invalid camera command body length: %d" % body_size}
	if available < 4 + body_size:
		return {}

	var body_start := start + 4
	var command_size := buffer.decode_s32(body_start)
	if command_size <= 0 or command_size > MAX_COMMAND_NAME_SIZE:
		return {"error": "invalid camera command length: %d" % command_size}
	var payload_size_offset := body_start + 4 + command_size
	if payload_size_offset + 4 > start + 4 + body_size:
		return {"error": "camera command length exceeds body"}

	var payload_size := buffer.decode_s32(payload_size_offset)
	if payload_size < 0 or payload_size > MAX_COMMAND_PAYLOAD_SIZE:
		return {"error": "invalid camera payload length: %d" % payload_size}
	var expected_body_size := 4 + command_size + 4 + payload_size
	if expected_body_size != body_size:
		return {"error": "camera command body length mismatch"}

	var command_start := body_start + 4
	var payload_start := payload_size_offset + 4
	return {
		"command": buffer.slice(command_start, command_start + command_size).get_string_from_utf8(),
		"payload": buffer.slice(payload_start, payload_start + payload_size),
		"bytes_consumed": 4 + body_size,
	}


static func decode_open_camera_payload(payload: PackedByteArray) -> Dictionary:
	const FIXED_SIZE := 3 + 7 * 4
	if payload.size() < FIXED_SIZE + 2:
		return {"error": "OPEN_CAMERA payload is truncated"}
	if payload[0] != CAMERA_MAGIC_0 or payload[1] != CAMERA_MAGIC_1:
		return {"error": "OPEN_CAMERA payload has invalid magic"}
	if payload[2] != CAMERA_PAYLOAD_VERSION:
		return {"error": "unsupported OPEN_CAMERA version: %d" % payload[2]}

	var offset := 3
	var result := {
		"version": int(payload[2]),
		"width": payload.decode_s32(offset),
		"height": payload.decode_s32(offset + 4),
		"fps": payload.decode_s32(offset + 8),
		"bitrate": payload.decode_s32(offset + 12),
		"enable_mv_hevc": payload.decode_s32(offset + 16),
		"render_mode": payload.decode_s32(offset + 20),
		"listen_port": payload.decode_s32(offset + 24),
	}
	offset += 7 * 4

	var camera_name_size := int(payload[offset])
	offset += 1
	if camera_name_size <= 0 or offset + camera_name_size + 1 > payload.size():
		return {"error": "OPEN_CAMERA camera name is truncated"}
	result["camera_name"] = payload.slice(offset, offset + camera_name_size).get_string_from_utf8()
	offset += camera_name_size

	var pico_ip_size := int(payload[offset])
	offset += 1
	if pico_ip_size <= 0 or offset + pico_ip_size != payload.size():
		return {"error": "OPEN_CAMERA PICO IP is truncated or has trailing bytes"}
	result["pico_ip"] = payload.slice(offset, offset + pico_ip_size).get_string_from_utf8()
	return result


static func encode_video_access_unit(access_unit: PackedByteArray) -> PackedByteArray:
	if access_unit.is_empty() or access_unit.size() > MAX_VIDEO_ACCESS_UNIT_SIZE:
		push_error("XRoboToolkit video access unit length is invalid: %d" % access_unit.size())
		return PackedByteArray()
	var frame := PackedByteArray()
	frame.resize(4)
	_write_u32_be(frame, 0, access_unit.size())
	frame.append_array(access_unit)
	return frame


## Returns an empty dictionary when more bytes are needed, or an `error` key
## for invalid length/content. A successful result includes `bytes_consumed`.
static func decode_video_access_unit(buffer: PackedByteArray, start: int = 0) -> Dictionary:
	if start < 0 or start > buffer.size():
		return {"error": "invalid video frame offset"}
	var available := buffer.size() - start
	if available < 4:
		return {}
	var access_unit_size := _read_u32_be(buffer, start)
	if access_unit_size <= 0 or access_unit_size > MAX_VIDEO_ACCESS_UNIT_SIZE:
		return {"error": "invalid video access unit length: %d" % access_unit_size}
	if available < 4 + access_unit_size:
		return {}

	var access_unit := buffer.slice(start + 4, start + 4 + access_unit_size)
	if not is_annex_b_access_unit(access_unit):
		return {"error": "video access unit is not Annex-B H.264"}
	return {
		"access_unit": access_unit,
		"bytes_consumed": 4 + access_unit_size,
	}


static func is_annex_b_access_unit(access_unit: PackedByteArray) -> bool:
	if access_unit.size() < 4 or access_unit[0] != 0 or access_unit[1] != 0:
		return false
	return access_unit[2] == 1 or (
		access_unit.size() >= 5 and access_unit[2] == 0 and access_unit[3] == 1
	)


static func _write_u32_be(buffer: PackedByteArray, offset: int, value: int) -> void:
	buffer[offset] = (value >> 24) & 0xFF
	buffer[offset + 1] = (value >> 16) & 0xFF
	buffer[offset + 2] = (value >> 8) & 0xFF
	buffer[offset + 3] = value & 0xFF


static func _read_u32_be(buffer: PackedByteArray, offset: int) -> int:
	return (
		(int(buffer[offset]) << 24)
		| (int(buffer[offset + 1]) << 16)
		| (int(buffer[offset + 2]) << 8)
		| int(buffer[offset + 3])
	)
