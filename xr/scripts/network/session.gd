class_name Session
extends Node
## Handles the v2 handshake protocol.
## On connection, sends a Hello command and waits for a DeviceDescriptor response.
## If no descriptor arrives within HANDSHAKE_TIMEOUT, falls back to legacy (v1) mode
## so PoseSender can take over.

signal device_connected(descriptor: Dictionary)
signal device_disconnected()
signal legacy_mode_activated()
signal telemetry_received(data: Dictionary)

var tcp_handler: TcpHandler
var _handshake_done: bool = false
var _is_legacy: bool = false
var _descriptor: Dictionary = {}
var _handshake_timer: float = 0.0
const HANDSHAKE_TIMEOUT: float = 3.0


func start_handshake() -> void:
	_handshake_done = false
	_is_legacy = false
	_handshake_timer = 0.0
	# Send Hello
	var hello = {"version": "2.0", "client": "godot", "capabilities": ["xr_state_v1", "hand_tracking", "body_tracking", "motion_trackers", "controller"]}
	var json_bytes = JSON.stringify(hello).to_utf8_buffer()
	tcp_handler.send_command("Hello", json_bytes)
	print("[Session] Hello sent, waiting for DeviceDescriptor...")


func handle_command(command: String, data: PackedByteArray) -> bool:
	# Returns true if this command was handled by session
	match command:
		"DeviceDescriptor":
			var json_str = data.get_string_from_utf8()
			var parsed = JSON.parse_string(json_str)
			if parsed and parsed is Dictionary:
				# WP2: validate against the v2 descriptor contract. The emitted
				# payload stays the raw parsed dictionary (wire-compatible);
				# contract violations are diagnostics only.
				var contract: Dictionary = DeviceDescriptorContract.parse(parsed)
				var contract_errors: Array = contract.get("errors", [])
				if not contract_errors.is_empty():
					print("[Session] DeviceDescriptor contract warnings: %s" % str(contract_errors))
				_descriptor = parsed
				_handshake_done = true
				# device.name here is robot identity metadata for logs/UI
				# only — never used for capability or vendor branching
				# (WP6 device-name sweep: keep).
				var device_name = _descriptor.get("device", {}).get("name", "Unknown")
				print("[Session] DeviceDescriptor received: %s" % device_name)
				device_connected.emit(_descriptor)
				return true
		"Telemetry":
			var json_str = data.get_string_from_utf8()
			var parsed = JSON.parse_string(json_str)
			if parsed and parsed is Dictionary:
				telemetry_received.emit(parsed)
				return true
	return false


func _process(delta: float) -> void:
	if not _handshake_done and not _is_legacy and _handshake_timer > 0:
		_handshake_timer += delta
		if _handshake_timer > HANDSHAKE_TIMEOUT:
			_is_legacy = true
			print("[Session] Handshake timeout, falling back to legacy mode")
			legacy_mode_activated.emit()


func on_connected() -> void:
	_handshake_timer = 0.001  # Start counting
	start_handshake()


func on_disconnected() -> void:
	_handshake_done = false
	_is_legacy = false
	_descriptor = {}
	_handshake_timer = 0.0
	device_disconnected.emit()


func is_v2() -> bool:
	return _handshake_done and not _is_legacy


func is_legacy() -> bool:
	return _is_legacy


func get_descriptor() -> Dictionary:
	return _descriptor
