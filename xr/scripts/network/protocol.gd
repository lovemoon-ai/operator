class_name XRoboProtocol
extends RefCounted
## Frame protocol encoder/decoder.
## Binary-compatible with existing C# NetworkDataProtocolSerializer.
##
## Command frame format:
##   [4 bytes cmd_len, little-endian int32]
##   [cmd_len bytes, UTF-8 command string]
##   [4 bytes data_len, little-endian int32]
##   [data_len bytes, payload]
##
## Video frame format:
##   [4 bytes length, big-endian uint32]
##   [length bytes, H.264 NAL payload]
##
## Timed video packet format:
##   [8 bytes frame_id, big-endian uint64]
##   [4 bytes nal_index, big-endian uint32]
##   [4 bytes nal_count, big-endian uint32]
##   [4 bytes pipeline_mode, big-endian uint32]
##   [8 bytes capture_start_ns, big-endian uint64]
##   [8 bytes capture_end_ns, big-endian uint64]
##   [8 bytes encode_start_ns, big-endian uint64]
##   [8 bytes encode_end_ns, big-endian uint64]
##   [8 bytes read_wait_ns, big-endian uint64]
##   [8 bytes parse_ns, big-endian uint64]
##   [8 bytes send_ns, big-endian uint64]
##   [4 bytes length, big-endian uint32]
##   [length bytes, H.264 NAL payload]

const PIPELINE_MODE_V4L2_HW := 0
const PIPELINE_MODE_FFMPEG := 1

## [issue 005 / item 3] UDP fragment header constants. Mirror the
## robot side `pipeline.rs` UDP_FRAGMENT_* constants. A fragmented
## datagram looks like:
##   [4B "NLFR"][1B version][1B flags]
##   [2B fragment_index BE][2B fragment_count BE][8B frame_id BE]
##   [80B TimedVideoFrame header — same layout as TCP path, nal_len = TOTAL]
##   [N bytes — this fragment's slice of the NAL]
const UDP_FRAGMENT_HEADER_SIZE := 4 + 1 + 1 + 2 + 2 + 8
# Magic bytes spelled "NLFR" — kept as individual constants because
# GDScript const evaluation rejects non-trivial PackedByteArray
# initializers.
const UDP_FRAGMENT_MAGIC_0 := 0x4E  # 'N'
const UDP_FRAGMENT_MAGIC_1 := 0x4C  # 'L'
const UDP_FRAGMENT_MAGIC_2 := 0x46  # 'F'
const UDP_FRAGMENT_MAGIC_3 := 0x52  # 'R'
const UDP_FRAGMENT_VERSION := 1
const UDP_FRAGMENT_FLAG_LAST := 0x01
const UDP_FRAGMENT_FLAG_FIRST := 0x02

const TIMED_VIDEO_HEADER_SIZE := 8 + 4 + 4 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 4  # 80 bytes


## Encode a command frame (command string + data payload) into a PackedByteArray.
static func encode_command(command: String, data: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var cmd_bytes := command.to_utf8_buffer()
	var total_size := 4 + cmd_bytes.size() + 4 + data.size()
	var buf := PackedByteArray()
	buf.resize(total_size)

	# Command length (little-endian int32)
	buf.encode_s32(0, cmd_bytes.size())

	# Command string bytes
	var offset := 4
	for i in cmd_bytes.size():
		buf[offset + i] = cmd_bytes[i]
	offset += cmd_bytes.size()

	# Data length (little-endian int32)
	buf.encode_s32(offset, data.size())
	offset += 4

	# Data bytes
	for i in data.size():
		buf[offset + i] = data[i]

	return buf


## Decode a command frame from a PackedByteArray.
## Returns: { "command": String, "data": PackedByteArray, "bytes_consumed": int }
## Returns empty dict on failure (not enough data).
static func decode_command(buf: PackedByteArray, start: int = 0) -> Dictionary:
	var available := buf.size() - start

	# Need at least 4 bytes for cmd_len
	if available < 4:
		return {}

	var cmd_len := buf.decode_s32(start)
	if cmd_len < 0 or cmd_len > 1048576:  # Sanity check: max 1MB command string
		return {"error": "invalid cmd_len: %d" % cmd_len}

	# Need cmd_len + 4 more bytes (for data_len header)
	if available < 4 + cmd_len + 4:
		return {}

	var cmd := buf.slice(start + 4, start + 4 + cmd_len).get_string_from_utf8()

	var data_len_offset := start + 4 + cmd_len
	var data_len := buf.decode_s32(data_len_offset)
	if data_len < 0 or data_len > 104857600:  # Sanity check: max 100MB data
		return {"error": "invalid data_len: %d" % data_len}

	var data_offset := data_len_offset + 4
	var total_needed := 4 + cmd_len + 4 + data_len

	if available < total_needed:
		return {}

	var data := buf.slice(data_offset, data_offset + data_len)

	return {
		"command": cmd,
		"data": data,
		"bytes_consumed": total_needed
	}


## Encode a video frame (H.264 NAL data) with big-endian length prefix.
static func encode_video_frame(nal_data: PackedByteArray) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(4 + nal_data.size())

	# Length in big-endian (network byte order)
	var length := nal_data.size()
	buf[0] = (length >> 24) & 0xFF
	buf[1] = (length >> 16) & 0xFF
	buf[2] = (length >> 8) & 0xFF
	buf[3] = length & 0xFF

	# NAL payload
	for i in nal_data.size():
		buf[4 + i] = nal_data[i]

	return buf


## Encode a timed video packet using the robot-side header layout.
static func encode_timed_video_frame(
		frame_id: int,
		nal_index: int,
		nal_count: int,
		pipeline_mode: int,
		capture_start_ns: int,
		capture_end_ns: int,
		encode_start_ns: int,
		encode_end_ns: int,
		read_wait_ns: int,
		parse_ns: int,
		send_ns: int,
		nal_data: PackedByteArray
	) -> PackedByteArray:
	var header_size := 8 + 4 + 4 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 4
	var buf := PackedByteArray()
	buf.resize(header_size + nal_data.size())

	_write_u64_be(buf, 0, frame_id)
	_write_u32_be(buf, 8, nal_index)
	_write_u32_be(buf, 12, nal_count)
	_write_u32_be(buf, 16, pipeline_mode)
	_write_u64_be(buf, 20, capture_start_ns)
	_write_u64_be(buf, 28, capture_end_ns)
	_write_u64_be(buf, 36, encode_start_ns)
	_write_u64_be(buf, 44, encode_end_ns)
	_write_u64_be(buf, 52, read_wait_ns)
	_write_u64_be(buf, 60, parse_ns)
	_write_u64_be(buf, 68, send_ns)
	_write_u32_be(buf, 76, nal_data.size())

	for i in nal_data.size():
		buf[header_size + i] = nal_data[i]

	return buf


## Decode a timed video packet.
## Returns a dictionary containing the packet fields and bytes_consumed.
static func decode_timed_video_frame(buf: PackedByteArray, start: int = 0) -> Dictionary:
	var header_size := 8 + 4 + 4 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 4
	var available := buf.size() - start
	if available < header_size:
		return {}

	var frame_id := _read_u64_be(buf, start + 0)
	var nal_index := _read_u32_be(buf, start + 8)
	var nal_count := _read_u32_be(buf, start + 12)
	var pipeline_mode := _read_u32_be(buf, start + 16)
	var capture_start_ns := _read_u64_be(buf, start + 20)
	var capture_end_ns := _read_u64_be(buf, start + 28)
	var encode_start_ns := _read_u64_be(buf, start + 36)
	var encode_end_ns := _read_u64_be(buf, start + 44)
	var read_wait_ns := _read_u64_be(buf, start + 52)
	var parse_ns := _read_u64_be(buf, start + 60)
	var send_ns := _read_u64_be(buf, start + 68)
	var nal_len := _read_u32_be(buf, start + 76)

	if nal_len < 0 or nal_len > 10_000_000:
		return {"error": "invalid video nal length: %d" % nal_len}

	var total_needed := header_size + nal_len
	if available < total_needed:
		return {}

	var nal_data := buf.slice(start + header_size, start + header_size + nal_len)
	return {
		"frame_id": frame_id,
		"nal_index": nal_index,
		"nal_count": nal_count,
		"pipeline_mode": pipeline_mode,
		"capture_start_ns": capture_start_ns,
		"capture_end_ns": capture_end_ns,
		"encode_start_ns": encode_start_ns,
		"encode_end_ns": encode_end_ns,
		"read_wait_ns": read_wait_ns,
		"parse_ns": parse_ns,
		"send_ns": send_ns,
		"nal_data": nal_data,
		"bytes_consumed": total_needed,
	}


## Decode a video frame length prefix (big-endian).
## Returns: { "length": int, "bytes_consumed": 4 } or empty dict if not enough data.
static func decode_video_frame_header(buf: PackedByteArray, start: int = 0) -> Dictionary:
	if buf.size() - start < 4:
		return {}

	var length := (buf[start] << 24) | (buf[start + 1] << 16) | (buf[start + 2] << 8) | buf[start + 3]

	if length < 0 or length > 104857600:  # max 100MB
		return {"error": "invalid video frame length: %d" % length}

	return {
		"length": length,
		"bytes_consumed": 4
	}


## [issue 005 / item 3] Parse a single UDP fragment datagram.
## Returns a Dictionary describing the fragment and its embedded
## TimedVideoFrame header, plus the raw NAL slice for THIS fragment.
##
## On success:
##   {
##     "is_fragment": true,
##     "fragment_index": int,
##     "fragment_count": int,
##     "is_first": bool,
##     "is_last": bool,
##     "frame_id": int,                     # from fragment header (mirrors timed)
##     "timed_header": PackedByteArray,     # 80 raw bytes for caching
##     "nal_total_len": int,                # full reassembled NAL byte count
##     "fragment_payload": PackedByteArray, # this fragment's slice
##     # plus all the timing fields decoded for free:
##     "nal_index": int, "nal_count": int, "pipeline_mode": int,
##     "capture_start_ns": int, "capture_end_ns": int,
##     "encode_start_ns": int, "encode_end_ns": int,
##     "read_wait_ns": int, "parse_ns": int, "send_ns": int,
##   }
##
## On failure / not-a-fragment / wrong magic, returns an empty dict
## (caller should treat as a legacy unfragmented datagram and try
## decode_timed_video_frame on the raw bytes).
static func decode_udp_fragment(buf: PackedByteArray) -> Dictionary:
	if buf.size() < UDP_FRAGMENT_HEADER_SIZE + TIMED_VIDEO_HEADER_SIZE:
		return {}
	# Magic check — silently bail if this is not a fragmented datagram.
	if buf[0] != UDP_FRAGMENT_MAGIC_0 or buf[1] != UDP_FRAGMENT_MAGIC_1 \
			or buf[2] != UDP_FRAGMENT_MAGIC_2 or buf[3] != UDP_FRAGMENT_MAGIC_3:
		return {}
	var version: int = buf[4]
	if version != UDP_FRAGMENT_VERSION:
		return {"error": "unsupported UDP fragment version: %d" % version}

	var flags: int = buf[5]
	var frag_idx: int = (buf[6] << 8) | buf[7]
	var frag_count: int = (buf[8] << 8) | buf[9]
	var frame_id := _read_u64_be(buf, 10)

	if frag_count == 0 or frag_idx >= frag_count:
		return {"error": "invalid fragment idx/count: %d/%d" % [frag_idx, frag_count]}

	# Embedded timed-video header (same layout as TCP path).
	var ts_off := UDP_FRAGMENT_HEADER_SIZE
	var nal_total_len := _read_u32_be(buf, ts_off + 76)
	if nal_total_len < 0 or nal_total_len > 10_000_000:
		return {"error": "invalid total NAL length in fragment: %d" % nal_total_len}

	var timed_header := buf.slice(ts_off, ts_off + TIMED_VIDEO_HEADER_SIZE)
	var fragment_payload := buf.slice(ts_off + TIMED_VIDEO_HEADER_SIZE, buf.size())

	return {
		"is_fragment": true,
		"fragment_index": frag_idx,
		"fragment_count": frag_count,
		"is_first": (flags & UDP_FRAGMENT_FLAG_FIRST) != 0,
		"is_last": (flags & UDP_FRAGMENT_FLAG_LAST) != 0,
		"frame_id": frame_id,
		"timed_header": timed_header,
		"nal_total_len": nal_total_len,
		"fragment_payload": fragment_payload,
		# Pre-decoded timing fields so callers don't have to re-parse the header.
		"nal_index": _read_u32_be(buf, ts_off + 8),
		"nal_count": _read_u32_be(buf, ts_off + 12),
		"pipeline_mode": _read_u32_be(buf, ts_off + 16),
		"capture_start_ns": _read_u64_be(buf, ts_off + 20),
		"capture_end_ns": _read_u64_be(buf, ts_off + 28),
		"encode_start_ns": _read_u64_be(buf, ts_off + 36),
		"encode_end_ns": _read_u64_be(buf, ts_off + 44),
		"read_wait_ns": _read_u64_be(buf, ts_off + 52),
		"parse_ns": _read_u64_be(buf, ts_off + 60),
		"send_ns": _read_u64_be(buf, ts_off + 68),
	}


static func _write_u32_be(buf: PackedByteArray, offset: int, value: int) -> void:
	buf[offset] = (value >> 24) & 0xFF
	buf[offset + 1] = (value >> 16) & 0xFF
	buf[offset + 2] = (value >> 8) & 0xFF
	buf[offset + 3] = value & 0xFF


static func _write_u64_be(buf: PackedByteArray, offset: int, value: int) -> void:
	buf[offset] = (value >> 56) & 0xFF
	buf[offset + 1] = (value >> 48) & 0xFF
	buf[offset + 2] = (value >> 40) & 0xFF
	buf[offset + 3] = (value >> 32) & 0xFF
	buf[offset + 4] = (value >> 24) & 0xFF
	buf[offset + 5] = (value >> 16) & 0xFF
	buf[offset + 6] = (value >> 8) & 0xFF
	buf[offset + 7] = value & 0xFF


static func _read_u32_be(buf: PackedByteArray, offset: int) -> int:
	return (buf[offset] << 24) | (buf[offset + 1] << 16) | (buf[offset + 2] << 8) | buf[offset + 3]


static func _read_u64_be(buf: PackedByteArray, offset: int) -> int:
	var value := 0
	for i in range(8):
		value = (value << 8) | buf[offset + i]
	return value
