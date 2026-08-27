class_name XrtProtocol
extends RefCounted
## XRoboToolkit-compatible packet framing and Tracking payload encoding.
##
## Binary frame format:
##   [1 byte 0x3F client head / 0xCF server head]
##   [1 byte command]
##   [4 bytes payload length, little-endian int32]
##   [payload bytes]
##   [8 bytes Unix timestamp in milliseconds, little-endian int64]
##   [1 byte 0xA5 tail]

const PACKET_HEAD := 0x3F
const RECEIVE_PACKET_HEAD := 0xCF
const PACKET_TAIL := 0xA5
const FRAME_OVERHEAD_SIZE := 15
const MAX_PAYLOAD_SIZE := 16 * 1024 * 1024

const CMD_CONNECT := 0x19
const CMD_HEARTBEAT := 0x23
const CMD_SERVER_FUNCTION := 0x5F
const CMD_VERSION := 0x6C
const CMD_TRACKING := 0x6D

const UNPACK_INCOMPLETE := 0
const UNPACK_OK := 1
const UNPACK_DISCARD := 2


static func pack(
		command: int,
		payload: PackedByteArray,
		timestamp_ms: int = -1
	) -> PackedByteArray:
	if command < 0 or command > 0xFF:
		push_error("XRoboToolkit command must fit in one byte: %d" % command)
		return PackedByteArray()

	var packet := PackedByteArray()
	packet.resize(6)
	packet[0] = PACKET_HEAD
	packet[1] = command
	packet.encode_s32(2, payload.size())
	packet.append_array(payload)

	var resolved_timestamp_ms := timestamp_ms
	if resolved_timestamp_ms < 0:
		resolved_timestamp_ms = int(Time.get_unix_time_from_system() * 1000.0)
	var tail := PackedByteArray()
	tail.resize(9)
	tail.encode_s64(0, resolved_timestamp_ms)
	tail[8] = PACKET_TAIL
	packet.append_array(tail)
	return packet


static func pack_text(
		command: int,
		payload: String,
		timestamp_ms: int = -1
	) -> PackedByteArray:
	return pack(command, payload.to_utf8_buffer(), timestamp_ms)


static func encode_tracking_envelope(tracking: Dictionary) -> PackedByteArray:
	var tracking_json := JSON.stringify(tracking)
	return JSON.stringify({
		"functionName": "Tracking",
		"value": tracking_json,
	}).to_utf8_buffer()


static func unpack_server_frame(buffer: PackedByteArray) -> Dictionary:
	if buffer.is_empty():
		return {"status": UNPACK_INCOMPLETE, "consumed": 0}
	if buffer[0] != RECEIVE_PACKET_HEAD:
		return {"status": UNPACK_DISCARD, "consumed": next_head_offset(buffer, 1)}
	if buffer.size() < FRAME_OVERHEAD_SIZE:
		return {"status": UNPACK_INCOMPLETE, "consumed": 0}

	# A malformed frame resynchronizes on the next header rather than one byte at
	# a time: the caller re-slices its receive buffer per discard, so per-byte
	# advancement is a full O(n) copy for every byte of a desynced stream.
	var payload_size := buffer.decode_s32(2)
	if payload_size < 0 or payload_size > MAX_PAYLOAD_SIZE:
		return {"status": UNPACK_DISCARD, "consumed": next_head_offset(buffer, 1)}
	var frame_size := FRAME_OVERHEAD_SIZE + payload_size
	if buffer.size() < frame_size:
		return {"status": UNPACK_INCOMPLETE, "consumed": 0}
	if buffer[frame_size - 1] != PACKET_TAIL:
		return {"status": UNPACK_DISCARD, "consumed": next_head_offset(buffer, 1)}

	return {
		"status": UNPACK_OK,
		"consumed": frame_size,
		"command": int(buffer[1]),
		"payload": buffer.slice(6, 6 + payload_size),
		"timestamp_ms": buffer.decode_s64(6 + payload_size),
	}


## Index of the next plausible server frame start at or after `from`, or the
## buffer size when the remainder holds no header byte.
static func next_head_offset(buffer: PackedByteArray, from: int) -> int:
	for index in range(maxi(from, 0), buffer.size()):
		if buffer[index] == RECEIVE_PACKET_HEAD:
			return index
	return buffer.size()


static func is_time_test_request(command: int, payload: PackedByteArray) -> bool:
	return command == CMD_SERVER_FUNCTION and payload.get_string_from_utf8().contains("timeTest")
