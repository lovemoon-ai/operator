class_name FakeRobotPeer
extends RefCounted
## v2 test harness (WP7): in-process robot peer for the teleop descriptor
## handshake. Serves a DeviceDescriptor fixture through the same contract
## path session.gd uses (DeviceDescriptorContract.parse) — no sockets.

var _descriptor: Dictionary = {}
var handshakes := 0


func _init(descriptor: Dictionary = {}) -> void:
	_descriptor = descriptor


static func from_fixture(fixture: Dictionary) -> FakeRobotPeer:
	# Fixtures may wrap the descriptor ({"descriptor": {...}}) or be the
	# descriptor document itself.
	var descriptor_v: Variant = fixture.get("descriptor", fixture)
	var descriptor: Dictionary = descriptor_v if typeof(descriptor_v) == TYPE_DICTIONARY else {}
	return FakeRobotPeer.new(descriptor)


func descriptor() -> Dictionary:
	return _descriptor


## In-process handshake: validates the descriptor through the production
## contract and returns {"descriptor": Dictionary, "errors": Array[String]}
## exactly like session.gd's diagnostics path.
func handshake() -> Dictionary:
	handshakes += 1
	return DeviceDescriptorContract.parse(_descriptor)


## Payload shape the app emits on device_connected (the descriptor dict is
## passed through unmodified, matching session.gd behavior).
func device_connected_payload() -> Dictionary:
	return _descriptor
