extends RefCounted
## Unit coverage for the XRoboToolkit robot beacon parser.
##
## Socket-free by construction: `parse_beacon` / `build_beacon` are static, so
## the wire format is pinned here and the on-device suite only has to prove the
## listener binds.

const CASE_ID := "teleop.xrt_discovery"
const XrtDiscoveryScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_discovery.gd"
)


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_exact_binary_beacon(t)
	_test_round_trip(t)
	_test_rejects_malformed_beacons(t)
	_test_ports(t)


func _test_exact_binary_beacon(t: OperatorTestAssertions) -> void:
	# Byte-for-byte, so a refactor cannot quietly change the format the robot
	# actually broadcasts.
	var packet := PackedByteArray([
		0xCF, 0x7E,
		0x0B, 0x00, 0x00, 0x00,
		0x31, 0x39, 0x32, 0x2E, 0x31, 0x36, 0x38, 0x2E, 0x31, 0x2E, 0x37,
		0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x00,
		0xA5,
	])
	var beacon: Dictionary = XrtDiscoveryScript.parse_beacon(packet)
	t.eq(beacon.get("ip"), "192.168.1.7", "beacon carries the robot's ASCII address")
	t.eq(beacon.get("timestamp_ms"), 0x0002030405060708,
		"beacon carries a little-endian Unix millisecond clock")
	t.eq(packet.size(), 11 + XrtDiscoveryScript.OVERHEAD_SIZE,
		"beacon length is the address plus fixed overhead")


func _test_round_trip(t: OperatorTestAssertions) -> void:
	var built: PackedByteArray = XrtDiscoveryScript.build_beacon("10.0.0.42", 1717171717171)
	var beacon: Dictionary = XrtDiscoveryScript.parse_beacon(built)
	t.eq(beacon.get("ip"), "10.0.0.42", "a built beacon parses back to its address")
	t.eq(beacon.get("timestamp_ms"), 1717171717171,
		"a built beacon parses back to its timestamp")
	t.eq(built[0], XrtDiscoveryScript.MAGIC_0, "built beacon opens with the first magic byte")
	t.eq(built[1], XrtDiscoveryScript.MAGIC_1, "built beacon opens with the second magic byte")
	t.eq(built[built.size() - 1], XrtDiscoveryScript.TRAILER,
		"built beacon closes with the trailer byte")


## Port 29888 is a broadcast domain shared with whatever else is on the LAN.
## Every one of these must yield no peer rather than a half-parsed address.
func _test_rejects_malformed_beacons(t: OperatorTestAssertions) -> void:
	var valid: PackedByteArray = XrtDiscoveryScript.build_beacon("192.168.1.7", 1)

	var wrong_magic := valid.duplicate()
	wrong_magic[0] = 0x3F
	t.is_true(XrtDiscoveryScript.parse_beacon(wrong_magic).is_empty(),
		"a foreign header byte is rejected")

	var wrong_trailer := valid.duplicate()
	wrong_trailer[wrong_trailer.size() - 1] = 0x00
	t.is_true(XrtDiscoveryScript.parse_beacon(wrong_trailer).is_empty(),
		"a missing trailer byte is rejected")

	var overlong_length := valid.duplicate()
	overlong_length.encode_s32(2, valid.size())
	t.is_true(XrtDiscoveryScript.parse_beacon(overlong_length).is_empty(),
		"a length field longer than the datagram is rejected")

	var short_length := valid.duplicate()
	short_length.encode_s32(2, 4)
	t.is_true(XrtDiscoveryScript.parse_beacon(short_length).is_empty(),
		"a length field shorter than the datagram is rejected")

	var negative_length := valid.duplicate()
	negative_length.encode_s32(2, -1)
	t.is_true(XrtDiscoveryScript.parse_beacon(negative_length).is_empty(),
		"a negative length field is rejected")

	var truncated: PackedByteArray = valid.slice(0, valid.size() - 1)
	t.is_true(XrtDiscoveryScript.parse_beacon(truncated).is_empty(),
		"a truncated datagram is rejected")

	t.is_true(XrtDiscoveryScript.parse_beacon(PackedByteArray()).is_empty(),
		"an empty datagram is rejected")

	# The address field is free-form ASCII on the wire, so it is the one place a
	# malformed sender can put something that reaches the connect path.
	var not_an_address: PackedByteArray = XrtDiscoveryScript.build_beacon("not-an-ip", 1)
	t.is_true(XrtDiscoveryScript.parse_beacon(not_an_address).is_empty(),
		"an address field that is not an IP is rejected")


func _test_ports(t: OperatorTestAssertions) -> void:
	t.eq(XrtDiscoveryScript.DISCOVERY_PORT, 29888,
		"the listener binds the XRoboToolkit beacon port")
	t.eq(XrtDiscoveryScript.SERVICE_PORT, 63901,
		"a discovered host is reported on the XRoboToolkit service port")
