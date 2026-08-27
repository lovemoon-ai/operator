extends RefCounted
## Unit coverage for XRoboToolkit camera commands and FPV framing.

const CASE_ID := "teleop.xrt_camera_protocol"
const XrtCameraProtocolScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_camera_protocol.gd"
)


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_open_camera_exact_bytes(t)
	_test_close_camera_exact_bytes(t)
	_test_command_decoder_rejects_bad_lengths(t)
	_test_video_access_unit_parser(t)


func _test_open_camera_exact_bytes(t: OperatorTestAssertions) -> void:
	var frame: PackedByteArray = XrtCameraProtocolScript.encode_open_camera({
		"width": 1280,
		"height": 720,
		"fps": 30,
		"bitrate": 6_000_000,
		"enable_mv_hevc": 0,
		"render_mode": 2,
		"listen_port": 12346,
		"camera_name": "UNITREE_HEAD",
		"pico_ip": "192.168.1.42",
	})
	var expected := PackedByteArray([
		0x00, 0x00, 0x00, 0x4C,
		0x0B, 0x00, 0x00, 0x00,
		0x4F, 0x50, 0x45, 0x4E, 0x5F, 0x43, 0x41, 0x4D, 0x45, 0x52, 0x41,
		0x39, 0x00, 0x00, 0x00,
		0xCA, 0xFE, 0x01,
		0x00, 0x05, 0x00, 0x00,
		0xD0, 0x02, 0x00, 0x00,
		0x1E, 0x00, 0x00, 0x00,
		0x80, 0x8D, 0x5B, 0x00,
		0x00, 0x00, 0x00, 0x00,
		0x02, 0x00, 0x00, 0x00,
		0x3A, 0x30, 0x00, 0x00,
		0x0C,
		0x55, 0x4E, 0x49, 0x54, 0x52, 0x45, 0x45, 0x5F, 0x48, 0x45, 0x41, 0x44,
		0x0C,
		0x31, 0x39, 0x32, 0x2E, 0x31, 0x36, 0x38, 0x2E, 0x31, 0x2E, 0x34, 0x32,
	])
	t.eq(frame, expected, "OPEN_CAMERA bytes match XRoboToolkit exactly")

	var decoded: Dictionary = XrtCameraProtocolScript.decode_command_frame(frame)
	t.eq(decoded.get("command"), XrtCameraProtocolScript.COMMAND_OPEN_CAMERA,
		"OPEN_CAMERA command decodes")
	t.eq(decoded.get("bytes_consumed"), frame.size(), "OPEN_CAMERA consumes one frame")
	var payload: Dictionary = XrtCameraProtocolScript.decode_open_camera_payload(
		decoded.get("payload", PackedByteArray())
	)
	t.eq(payload.get("width"), 1280, "OPEN_CAMERA width is little-endian")
	t.eq(payload.get("height"), 720, "OPEN_CAMERA height is little-endian")
	t.eq(payload.get("fps"), 30, "OPEN_CAMERA fps is little-endian")
	t.eq(payload.get("bitrate"), 6_000_000, "OPEN_CAMERA bitrate is little-endian")
	t.eq(payload.get("enable_mv_hevc"), 0, "OPEN_CAMERA MV/HEVC flag decodes")
	t.eq(payload.get("render_mode"), 2, "OPEN_CAMERA render mode decodes")
	t.eq(payload.get("listen_port"), 12346, "OPEN_CAMERA listen port decodes")
	t.eq(payload.get("camera_name"), "UNITREE_HEAD", "OPEN_CAMERA camera name decodes")
	t.eq(payload.get("pico_ip"), "192.168.1.42", "OPEN_CAMERA PICO IP decodes")


func _test_close_camera_exact_bytes(t: OperatorTestAssertions) -> void:
	var frame: PackedByteArray = XrtCameraProtocolScript.encode_close_camera()
	var expected := PackedByteArray([
		0x00, 0x00, 0x00, 0x14,
		0x0C, 0x00, 0x00, 0x00,
		0x43, 0x4C, 0x4F, 0x53, 0x45, 0x5F, 0x43, 0x41, 0x4D, 0x45, 0x52, 0x41,
		0x00, 0x00, 0x00, 0x00,
	])
	t.eq(frame, expected, "CLOSE_CAMERA bytes match XRoboToolkit exactly")
	var decoded: Dictionary = XrtCameraProtocolScript.decode_command_frame(frame)
	t.eq(decoded.get("command"), XrtCameraProtocolScript.COMMAND_CLOSE_CAMERA,
		"CLOSE_CAMERA command decodes")
	t.eq(decoded.get("payload"), PackedByteArray(), "CLOSE_CAMERA payload is empty")


func _test_command_decoder_rejects_bad_lengths(t: OperatorTestAssertions) -> void:
	var valid := XrtCameraProtocolScript.encode_close_camera()
	t.is_true(
		XrtCameraProtocolScript.decode_command_frame(valid.slice(0, 3)).is_empty(),
		"partial outer command length remains buffered",
	)
	t.is_true(
		XrtCameraProtocolScript.decode_command_frame(valid.slice(0, valid.size() - 1)).is_empty(),
		"partial command body remains buffered",
	)

	var oversized := PackedByteArray([0x00, 0x02, 0x00, 0x01])
	var rejected: Dictionary = XrtCameraProtocolScript.decode_command_frame(oversized)
	t.contains(rejected, "error", "oversized command body is rejected before buffering")

	var mismatched := valid.duplicate()
	mismatched[3] = 0x13
	rejected = XrtCameraProtocolScript.decode_command_frame(mismatched)
	t.contains(rejected, "error", "mismatched command body length is rejected")


func _test_video_access_unit_parser(t: OperatorTestAssertions) -> void:
	var first_au := PackedByteArray([0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
	var second_au := PackedByteArray([0x00, 0x00, 0x01, 0x65, 0x88, 0x84])
	var first_frame: PackedByteArray = XrtCameraProtocolScript.encode_video_access_unit(first_au)
	var second_frame: PackedByteArray = XrtCameraProtocolScript.encode_video_access_unit(second_au)

	t.is_true(
		XrtCameraProtocolScript.decode_video_access_unit(first_frame.slice(0, 5)).is_empty(),
		"partial video access unit remains buffered",
	)
	var combined := first_frame.duplicate()
	combined.append_array(second_frame)
	var decoded: Dictionary = XrtCameraProtocolScript.decode_video_access_unit(combined)
	t.eq(decoded.get("access_unit"), first_au, "video parser returns the first Annex-B AU")
	t.eq(decoded.get("bytes_consumed"), first_frame.size(),
		"video parser leaves coalesced frames for the next pass")
	decoded = XrtCameraProtocolScript.decode_video_access_unit(
		combined, int(decoded.get("bytes_consumed", 0))
	)
	t.eq(decoded.get("access_unit"), second_au, "video parser supports three-byte start codes")

	var oversized := PackedByteArray([0x01, 0x00, 0x00, 0x01])
	var rejected: Dictionary = XrtCameraProtocolScript.decode_video_access_unit(oversized)
	t.contains(rejected, "error", "oversized video AU is rejected from its header")

	var malformed := XrtCameraProtocolScript.encode_video_access_unit(
		PackedByteArray([0x11, 0x22, 0x33, 0x44])
	)
	rejected = XrtCameraProtocolScript.decode_video_access_unit(malformed)
	t.contains(rejected, "error", "non-Annex-B video payload is rejected")
