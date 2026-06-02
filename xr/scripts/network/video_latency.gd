class_name VideoLatencyTracker
extends RefCounted
## Shared helpers for video latency timestamps and formatting.

const PIPELINE_MODE_V4L2_HW := 0
const PIPELINE_MODE_FFMPEG := 1

static var _epoch_offset_ns: int = 0
static var _initialized: bool = false


static func now_ns() -> int:
	if not _initialized:
		var unix_ns := int(Time.get_unix_time_from_system() * 1_000_000_000.0)
		var ticks_ns := Time.get_ticks_usec() * 1000
		_epoch_offset_ns = unix_ns - ticks_ns
		_initialized = true

	return Time.get_ticks_usec() * 1000 + _epoch_offset_ns


static func ns_to_ms(ns: int) -> float:
	return float(ns) / 1_000_000.0


static func duration_ms(ns: int) -> String:
	if ns <= 0:
		return "--"
	return "%.2f ms" % ns_to_ms(ns)


static func stage_ms(start_ns: int, end_ns: int) -> String:
	if start_ns <= 0 or end_ns <= 0 or end_ns < start_ns:
		return "--"
	return "%.2f ms" % ns_to_ms(end_ns - start_ns)


static func format_packet(packet: Dictionary) -> String:
	var frame_id: int = int(packet.get("frame_id", -1))
	var nal_index: int = int(packet.get("nal_index", 0)) + 1
	var nal_count: int = int(packet.get("nal_count", 1))
	var pipeline_mode: int = int(packet.get("pipeline_mode", 0))
	var capture_start_ns: int = int(packet.get("capture_start_ns", 0))
	var capture_end_ns: int = int(packet.get("capture_end_ns", 0))
	var encode_start_ns: int = int(packet.get("encode_start_ns", 0))
	var encode_end_ns: int = int(packet.get("encode_end_ns", 0))
	var read_wait_ns: int = int(packet.get("read_wait_ns", 0))
	var parse_ns: int = int(packet.get("parse_ns", 0))
	var send_ns: int = int(packet.get("send_ns", 0))
	var receive_ns: int = int(packet.get("receive_ns", 0))
	var decoded_ns: int = int(packet.get("decoded_ns", 0))
	var present_ns: int = int(packet.get("present_ns", 0))

	# [opt 5] Apply the robot->XR clock offset learned by RobotClockSync
	# so `tx=` is meaningful. offset_ns = robot_clock - xr_clock, so we
	# subtract it from any robot-stamped timestamp to bring it into the
	# XR clock domain. send_ns is robot-stamped; receive_ns is XR.
	var clock_offset_ns: int = 0
	if RobotClockSync.samples > 0:
		clock_offset_ns = RobotClockSync.offset_ns
	var send_ns_xr: int = send_ns - clock_offset_ns if send_ns > 0 else 0

	var parts: Array[String] = []
	parts.append("frame %d NAL %d/%d" % [frame_id, nal_index, nal_count])
	if pipeline_mode == PIPELINE_MODE_FFMPEG:
		parts.append("wait=%s" % duration_ms(read_wait_ns))
		parts.append("parse=%s" % duration_ms(parse_ns))
	else:
		parts.append("capture=%s" % stage_ms(capture_start_ns, capture_end_ns))
		parts.append("encode=%s" % stage_ms(encode_start_ns, encode_end_ns))
	if send_ns_xr > 0 and receive_ns > 0:
		parts.append("tx=%s" % stage_ms(send_ns_xr, receive_ns))
	if decoded_ns > 0 and receive_ns > 0:
		parts.append("decode=%s" % stage_ms(receive_ns, decoded_ns))
	if present_ns > 0 and decoded_ns > 0:
		parts.append("present=%s" % stage_ms(decoded_ns, present_ns))

	if pipeline_mode == PIPELINE_MODE_FFMPEG:
		var total_ns := read_wait_ns + parse_ns
		if send_ns_xr > 0 and receive_ns > 0 and receive_ns >= send_ns_xr:
			total_ns += receive_ns - send_ns_xr
		if decoded_ns > 0 and receive_ns > 0 and decoded_ns >= receive_ns:
			total_ns += decoded_ns - receive_ns
		if present_ns > 0 and decoded_ns > 0 and present_ns >= decoded_ns:
			total_ns += present_ns - decoded_ns
		if total_ns > 0:
			parts.append("total=%s" % duration_ms(total_ns))
	else:
		var total_start_ns: int = capture_start_ns if capture_start_ns > 0 else send_ns
		var total_end_ns: int = present_ns if present_ns > 0 else (decoded_ns if decoded_ns > 0 else receive_ns)
		if total_start_ns > 0 and total_end_ns > 0 and total_end_ns >= total_start_ns:
			parts.append("total=%s" % stage_ms(total_start_ns, total_end_ns))

	return " ".join(parts)
