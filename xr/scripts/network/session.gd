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
signal blueprint_received(blueprint: Dictionary)
signal blueprint_cleared()
signal blueprint_state_received(state: Dictionary)
## A host StreamsControl (capture_streams_v1), already shape-validated.
signal streams_control_received(control: Dictionary)

var tcp_handler: TcpHandler
## Capabilities this build adds to Hello beyond the fixed set (e.g.
## capture_streams_v1 and stream.<name> when a capture stack is present).
var extra_capabilities: Array = []
var _handshake_done: bool = false
var _is_legacy: bool = false
var _blueprint_enabled: bool = false
var _descriptor: Dictionary = {}
var _handshake_timer: float = 0.0
const HANDSHAKE_TIMEOUT: float = 3.0
const DEDICATED_TELEMETRY_CAPABILITY := "dedicated_telemetry_v1"


func start_handshake() -> void:
	_handshake_done = false
	_is_legacy = false
	_handshake_timer = 0.0
	# Send Hello
	var hello := hello_payload(extra_capabilities)
	var json_bytes = JSON.stringify(hello).to_utf8_buffer()
	tcp_handler.send_command("Hello", json_bytes)
	print("[Session] Hello sent, waiting for DeviceDescriptor...")


static func hello_payload(extra: Array = []) -> Dictionary:
	var capabilities: Array = [
		"xr_state_v1",
		DEDICATED_TELEMETRY_CAPABILITY,
		BlueprintPrimitiveSpec.CAPABILITY,
		BlueprintPrimitiveSpec.SPEC_CAPABILITY,
		"hand_tracking",
		"body_tracking",
		"motion_trackers",
		"controller",
	]
	for capability_v in extra:
		var capability := str(capability_v)
		if not capability.is_empty() and not capabilities.has(capability):
			capabilities.append(capability)
	return {
		"version": "2.0",
		"client": "godot",
		"capabilities": capabilities,
	}


func handle_command(command: String, data: PackedByteArray) -> bool:
	# Returns true if this command was handled by session
	match command:
		"DeviceDescriptor":
			var json_str = data.get_string_from_utf8()
			var parsed = JSON.parse_string(json_str)
			if parsed and parsed is Dictionary:
				_normalize_json_wire_integers(parsed as Dictionary, ["descriptor_version"])
				# WP2: validate against the v2 descriptor contract. The emitted
				# payload stays the raw parsed dictionary (wire-compatible);
				# contract violations are diagnostics only.
				var contract: Dictionary = DeviceDescriptorContract.parse(parsed)
				var contract_errors: Array = contract.get("errors", [])
				if not contract_errors.is_empty():
					print("[Session] DeviceDescriptor contract warnings: %s" % str(contract_errors))
				_descriptor = parsed
				_blueprint_enabled = descriptor_supports_blueprint(_descriptor)
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
		BlueprintPrimitiveSpec.BLUEPRINT_COMMAND:
			if not _blueprint_enabled:
				push_warning(
					"[Session] Ignoring Blueprint without an exact descriptor spec match"
				)
				return true
			var blueprint_json := data.get_string_from_utf8()
			if blueprint_json.strip_edges() == "null":
				print("[Session] Blueprint cleared")
				blueprint_cleared.emit()
				return true
			var parsed_blueprint: Variant = JSON.parse_string(blueprint_json)
			if parsed_blueprint is Dictionary:
				_normalize_json_wire_integers(parsed_blueprint as Dictionary, ["revision"])
				var blueprint_result := BlueprintContract.parse_blueprint(
					parsed_blueprint as Dictionary
				)
				var blueprint_errors: Array = blueprint_result.get("errors", [])
				if blueprint_errors.is_empty():
					print(
						"[Session] Blueprint received id=%s revision=%d components=%d"
						% [
							str((parsed_blueprint as Dictionary).get("blueprint_id", "")),
							int((parsed_blueprint as Dictionary).get("revision", 0)),
							((parsed_blueprint as Dictionary).get("components", []) as Array).size(),
						]
					)
					blueprint_received.emit(parsed_blueprint)
				else:
					push_warning("[Session] Invalid Blueprint: %s" % str(blueprint_errors))
				return true
			push_warning("[Session] Blueprint payload must be an object or null")
			return true
		BlueprintPrimitiveSpec.STATE_COMMAND:
			if not _blueprint_enabled:
				push_warning(
					"[Session] Ignoring BlueprintState without an exact descriptor spec match"
				)
				return true
			var parsed_state: Variant = JSON.parse_string(data.get_string_from_utf8())
			if parsed_state is Dictionary:
				_normalize_json_wire_integers(
					parsed_state as Dictionary,
					["blueprint_revision", "sequence", "timestamp_ns"],
				)
				var state_result := BlueprintContract.parse_state(parsed_state as Dictionary)
				var state_errors: Array = state_result.get("errors", [])
				if state_errors.is_empty():
					if int((parsed_state as Dictionary).get("sequence", 0)) == 1:
						print(
							"[Session] Initial BlueprintState received id=%s revision=%d values=%d"
							% [
								str((parsed_state as Dictionary).get("blueprint_id", "")),
								int((parsed_state as Dictionary).get("blueprint_revision", 0)),
								((parsed_state as Dictionary).get("values", {}) as Dictionary).size(),
							]
						)
					blueprint_state_received.emit(parsed_state)
				else:
					push_warning(
						"[Session] Invalid BlueprintState: %s" % str(state_errors)
					)
				return true
			push_warning("[Session] BlueprintState payload must be an object")
			return true
		StreamsContract.CONTROL_COMMAND:
			if not extra_capabilities.has(StreamsContract.CAPABILITY):
				push_warning("[Session] Ignoring StreamsControl: capture streams were not advertised")
				return true
			var control_result := StreamsContract.parse_control(JSON.parse_string(data.get_string_from_utf8()))
			var control_errors: Array = control_result.get("errors", [])
			if control_errors.is_empty():
				streams_control_received.emit(control_result.get("control", {}) as Dictionary)
			else:
				push_warning("[Session] Invalid StreamsControl: %s" % str(control_errors))
			return true
	return false


static func _normalize_json_wire_integers(value: Dictionary, fields: Array) -> void:
	for field_v in fields:
		var field := str(field_v)
		var candidate: Variant = value.get(field)
		if not candidate is float:
			continue
		var number := float(candidate)
		if (
			is_finite(number)
			and number >= 0.0
			and number <= float(BlueprintPrimitiveSpec.MAX_WIRE_INTEGER)
			and number == floorf(number)
		):
			value[field] = int(number)


func send_blueprint_event(event: Dictionary) -> Error:
	if tcp_handler == null or not tcp_handler.is_connected_to_robot():
		return ERR_CONNECTION_ERROR
	if not _blueprint_enabled:
		return ERR_UNAVAILABLE
	var parsed := BlueprintContract.parse_event(event)
	var errors: Array = parsed.get("errors", [])
	if not errors.is_empty():
		push_warning("[Session] Invalid BlueprintEvent: %s" % str(errors))
		return ERR_INVALID_DATA
	return tcp_handler.send_command(
		BlueprintPrimitiveSpec.EVENT_COMMAND, JSON.stringify(event).to_utf8_buffer()
	)


## Reports the effective capture-stream composition to the host
## (operator.streams_status.v1). Only sent when capture streams were advertised.
func send_streams_status(status: Dictionary) -> Error:
	if tcp_handler == null or not tcp_handler.is_connected_to_robot():
		return ERR_CONNECTION_ERROR
	if not extra_capabilities.has(StreamsContract.CAPABILITY):
		return ERR_UNAVAILABLE
	return tcp_handler.send_command(
		StreamsContract.STATUS_COMMAND, JSON.stringify(status).to_utf8_buffer()
	)


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
	_blueprint_enabled = false
	_descriptor = {}
	_handshake_timer = 0.0
	device_disconnected.emit()


func is_v2() -> bool:
	return _handshake_done and not _is_legacy


func is_legacy() -> bool:
	return _is_legacy


func get_descriptor() -> Dictionary:
	return _descriptor


static func descriptor_supports_blueprint(descriptor: Dictionary) -> bool:
	var capabilities_v: Variant = descriptor.get("capabilities", {})
	if not capabilities_v is Dictionary:
		return false
	var capabilities := capabilities_v as Dictionary
	return (
		capabilities.get(BlueprintPrimitiveSpec.CAPABILITY) == true
		and str(capabilities.get(BlueprintPrimitiveSpec.SPEC_HASH_CAPABILITY, ""))
			== BlueprintPrimitiveSpec.SPEC_SHA256
	)
