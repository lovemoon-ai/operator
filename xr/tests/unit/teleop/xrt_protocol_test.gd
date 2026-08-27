extends RefCounted
## Unit coverage for the legacy XRoboToolkit packet and Tracking envelope.

const CASE_ID := "teleop.xrt_protocol"
const XrtProtocolScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_protocol.gd"
)


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_command_constants(t)
	_test_exact_binary_frame(t)
	_test_server_frame_unpacking(t)
	_test_desync_resynchronizes_in_one_step(t)
	_test_text_packets(t)
	_test_tracking_envelope(t)


func _test_command_constants(t: OperatorTestAssertions) -> void:
	t.eq(XrtProtocolScript.CMD_CONNECT, 0x19, "connect command matches XRoboToolkit")
	t.eq(XrtProtocolScript.CMD_HEARTBEAT, 0x23, "heartbeat command matches XRoboToolkit")
	t.eq(XrtProtocolScript.CMD_SERVER_FUNCTION, 0x5F,
		"server function command matches XRoboToolkit")
	t.eq(XrtProtocolScript.CMD_VERSION, 0x6C, "version command matches XRoboToolkit")
	t.eq(XrtProtocolScript.CMD_TRACKING, 0x6D, "tracking command matches XRoboToolkit")


func _test_exact_binary_frame(t: OperatorTestAssertions) -> void:
	var payload := PackedByteArray([0x41, 0x00, 0xFF])
	var timestamp_ms := 0x0102030405060708
	var packet: PackedByteArray = XrtProtocolScript.pack(
		XrtProtocolScript.CMD_TRACKING,
		payload,
		timestamp_ms,
	)
	var expected := PackedByteArray([
		0x3F, 0x6D,
		0x03, 0x00, 0x00, 0x00,
		0x41, 0x00, 0xFF,
		0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
		0xA5,
	])

	t.eq(packet, expected, "packet bytes match the legacy little-endian frame")
	t.eq(packet.size(), payload.size() + 15, "packet length includes the 15-byte overhead")
	t.eq(packet[0], 0x3F, "packet starts with the XRoboToolkit send header")
	t.eq(packet[1], XrtProtocolScript.CMD_TRACKING, "packet carries the command byte")
	t.eq(packet.decode_s32(2), payload.size(), "packet carries the payload length")
	t.eq(packet.slice(6, 6 + payload.size()), payload, "packet carries the payload bytes")
	t.eq(packet.decode_s64(6 + payload.size()), timestamp_ms,
		"packet carries the Unix millisecond timestamp")
	t.eq(packet[packet.size() - 1], 0xA5, "packet ends with the XRoboToolkit tail")


func _test_server_frame_unpacking(t: OperatorTestAssertions) -> void:
	var payload := "{\"functionName\":\"timeTest\"}".to_utf8_buffer()
	var packet := PackedByteArray()
	packet.resize(XrtProtocolScript.FRAME_OVERHEAD_SIZE + payload.size())
	packet[0] = XrtProtocolScript.RECEIVE_PACKET_HEAD
	packet[1] = XrtProtocolScript.CMD_SERVER_FUNCTION
	packet.encode_s32(2, payload.size())
	for index in payload.size():
		packet[6 + index] = payload[index]
	packet.encode_s64(6 + payload.size(), 1_700_000_000_321)
	packet[packet.size() - 1] = XrtProtocolScript.PACKET_TAIL

	var incomplete: Dictionary = XrtProtocolScript.unpack_server_frame(packet.slice(0, 8))
	t.eq(incomplete.get("status"), XrtProtocolScript.UNPACK_INCOMPLETE,
		"partial server frames remain buffered")
	t.eq(incomplete.get("consumed"), 0, "partial server frames consume no bytes")

	var decoded: Dictionary = XrtProtocolScript.unpack_server_frame(packet)
	t.eq(decoded.get("status"), XrtProtocolScript.UNPACK_OK,
		"complete server frame decodes")
	t.eq(decoded.get("consumed"), packet.size(), "decoder consumes exactly one frame")
	t.eq(decoded.get("command"), XrtProtocolScript.CMD_SERVER_FUNCTION,
		"decoder preserves the server command")
	t.eq(decoded.get("payload"), payload, "decoder preserves server payload bytes")
	t.eq(decoded.get("timestamp_ms"), 1_700_000_000_321,
		"decoder preserves the server timestamp")
	t.is_true(
		XrtProtocolScript.is_time_test_request(
			int(decoded.get("command", -1)), decoded.get("payload", PackedByteArray())
		),
		"legacy timeTest requests are recognized",
	)

	var prefixed := PackedByteArray([0x00, 0x01])
	prefixed.append_array(packet)
	var discard: Dictionary = XrtProtocolScript.unpack_server_frame(prefixed)
	t.eq(discard.get("status"), XrtProtocolScript.UNPACK_DISCARD,
		"decoder resynchronizes after unrelated bytes")
	t.eq(discard.get("consumed"), 2, "decoder discards only bytes before the next header")

	var malformed := packet.duplicate()
	malformed[malformed.size() - 1] = 0x00
	var rejected: Dictionary = XrtProtocolScript.unpack_server_frame(malformed)
	t.eq(rejected.get("status"), XrtProtocolScript.UNPACK_DISCARD,
		"decoder rejects frames with an invalid tail")


## A desynced stream used to resynchronize one byte at a time. XrtClient re-slices
## its entire receive buffer per discard, so per-byte advancement is a full copy
## for every byte of garbage and freezes the render thread.
func _test_desync_resynchronizes_in_one_step(t: OperatorTestAssertions) -> void:
	var good := _clean_server_frame(XrtProtocolScript.CMD_SERVER_FUNCTION, "ok")
	t.eq(XrtProtocolScript.next_head_offset(good, 1), good.size(),
		"the fixture frame carries no header byte after its own")

	var bad_tail := good.duplicate()
	bad_tail[bad_tail.size() - 1] = 0x00
	var alone: Dictionary = XrtProtocolScript.unpack_server_frame(bad_tail)
	t.eq(alone.get("status"), XrtProtocolScript.UNPACK_DISCARD,
		"decoder rejects an invalid tail")
	t.eq(alone.get("consumed"), bad_tail.size(),
		"a malformed frame with no later header is dropped whole, not byte by byte")

	var stream := bad_tail.duplicate()
	stream.append_array(good)
	var resynced: Dictionary = XrtProtocolScript.unpack_server_frame(stream)
	t.eq(resynced.get("consumed"), bad_tail.size(),
		"a malformed frame skips straight to the next header in one slice")
	var recovered: Dictionary = XrtProtocolScript.unpack_server_frame(
		stream.slice(int(resynced.get("consumed", 0)))
	)
	t.eq(recovered.get("status"), XrtProtocolScript.UNPACK_OK,
		"a single resync slice recovers the following frame")

	var oversized := good.duplicate()
	oversized.encode_s32(2, XrtProtocolScript.MAX_PAYLOAD_SIZE + 1)
	var rejected: Dictionary = XrtProtocolScript.unpack_server_frame(oversized)
	t.eq(rejected.get("status"), XrtProtocolScript.UNPACK_DISCARD,
		"decoder rejects an out-of-range payload length")
	t.eq(rejected.get("consumed"), oversized.size(),
		"an out-of-range payload length also resynchronizes in one step")

	t.eq(XrtProtocolScript.next_head_offset(stream, 1), bad_tail.size(),
		"next_head_offset reports the first header at or after the search start")


## A server frame whose payload and timestamp bytes cannot be mistaken for the
## receive header, so resync offsets in this test are unambiguous.
func _clean_server_frame(command: int, payload_text: String) -> PackedByteArray:
	var payload := payload_text.to_utf8_buffer()
	var frame := PackedByteArray()
	frame.resize(XrtProtocolScript.FRAME_OVERHEAD_SIZE + payload.size())
	frame[0] = XrtProtocolScript.RECEIVE_PACKET_HEAD
	frame[1] = command
	frame.encode_s32(2, payload.size())
	for index in payload.size():
		frame[6 + index] = payload[index]
	frame.encode_s64(6 + payload.size(), 0)
	frame[frame.size() - 1] = XrtProtocolScript.PACKET_TAIL
	return frame


func _test_text_packets(t: OperatorTestAssertions) -> void:
	var timestamp_ms := 1_700_000_000_123
	var cases := [
		[XrtProtocolScript.CMD_CONNECT, "operator-device|-1"],
		[XrtProtocolScript.CMD_HEARTBEAT, "operator-device"],
		[XrtProtocolScript.CMD_VERSION, "operator-device|1.0|operator/test"],
		[XrtProtocolScript.CMD_TRACKING, "{}"],
	]

	for packet_case in cases:
		var command: int = packet_case[0]
		var text: String = packet_case[1]
		var payload := text.to_utf8_buffer()
		var packet: PackedByteArray = XrtProtocolScript.pack_text(command, text, timestamp_ms)
		t.eq(packet[1], command, "pack_text preserves command 0x%02X" % command)
		t.eq(packet.decode_s32(2), payload.size(), "pack_text writes UTF-8 byte length")
		t.eq(packet.slice(6, 6 + payload.size()), payload, "pack_text writes UTF-8 payload")
		t.eq(packet.decode_s64(6 + payload.size()), timestamp_ms,
			"pack_text preserves the explicit timestamp")


func _test_tracking_envelope(t: OperatorTestAssertions) -> void:
	var tracking := {
		"timeStampNs": 123_456_789,
		"Controller": {
			"left": {
				"axisX": 0.25,
				"axisY": -0.5,
				"axisClick": true,
				"grip": 0.75,
				"trigger": 0.5,
				"primaryButton": true,
				"secondaryButton": false,
				"menuButton": false,
				"pose": "1,2,3,0,0,0,1",
			},
		},
		"Body": {
			"len": 1,
			"timeStampNs": 123_456_700,
			"joints": [{
				"p": "0,1,2,0,0,0,1",
				"t": 123_456_701,
				"va": "1,2,3,4,5,6",
				"wva": "7,8,9,10,11,12",
			}],
		},
	}
	var payload: PackedByteArray = XrtProtocolScript.encode_tracking_envelope(tracking)
	var envelope_text := payload.get_string_from_utf8()
	var envelope_value: Variant = JSON.parse_string(envelope_text)

	t.eq(typeof(envelope_value), TYPE_DICTIONARY, "Tracking envelope is a JSON object")
	if typeof(envelope_value) != TYPE_DICTIONARY:
		return
	var envelope := envelope_value as Dictionary
	t.eq(envelope.get("functionName"), "Tracking", "Tracking envelope names the function")
	t.eq(typeof(envelope.get("value")), TYPE_STRING,
		"Tracking envelope stores the inner document as a JSON string")
	t.is_true(envelope_text.contains("\\\"Controller\\\""),
		"outer JSON escapes the nested Controller document")
	t.is_true(envelope_text.contains("\\\"Body\\\""),
		"outer JSON escapes the nested Body document")

	var tracking_value: Variant = JSON.parse_string(str(envelope.get("value", "")))
	t.eq(typeof(tracking_value), TYPE_DICTIONARY, "Tracking value contains valid inner JSON")
	if typeof(tracking_value) != TYPE_DICTIONARY:
		return
	var decoded_tracking := tracking_value as Dictionary
	t.eq(decoded_tracking.get("timeStampNs"), 123_456_789,
		"inner Tracking JSON preserves its timestamp")
	t.contains(decoded_tracking, "Controller", "inner Tracking JSON preserves Controller")
	t.contains(decoded_tracking, "Body", "inner Tracking JSON preserves Body")
	t.eq(
		decoded_tracking.get("Controller", {}).get("left", {}).get("primaryButton"),
		true,
		"Controller fields survive double JSON encoding",
	)
	t.eq(
		decoded_tracking.get("Body", {}).get("joints", [])[0].get("wva"),
		"7,8,9,10,11,12",
		"Body joint fields survive double JSON encoding",
	)

	var packet: PackedByteArray = XrtProtocolScript.pack(
		XrtProtocolScript.CMD_TRACKING,
		payload,
		1_700_000_000_456,
	)
	t.eq(packet.decode_s32(2), payload.size(),
		"Tracking frame length measures the UTF-8 envelope bytes")
	t.eq(packet.slice(6, 6 + payload.size()), payload,
		"Tracking frame embeds the double JSON payload unchanged")
