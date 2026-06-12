class_name CapabilityInfo
extends RefCounted
## v2 contracts: description of one capability as reported by a platform
## adapter through PlatformRegistry.

var capability_id: int = -1
var provider_id: String = ""
var state: int = CapabilityState.UNAVAILABLE
var reason: String = ""
var payload_format: String = ""
var coordinate_space: String = ""
var timestamp_source: String = ""
var rate_hz: float = 0.0


static func create(
	p_capability_id: int,
	p_provider_id: String,
	p_state: int,
	p_reason: String = "",
	p_payload_format: String = "",
	p_coordinate_space: String = "",
	p_timestamp_source: String = "",
	p_rate_hz: float = 0.0
) -> CapabilityInfo:
	var info := CapabilityInfo.new()
	info.capability_id = p_capability_id
	info.provider_id = p_provider_id
	info.state = p_state
	info.reason = p_reason
	info.payload_format = p_payload_format
	info.coordinate_space = p_coordinate_space
	info.timestamp_source = p_timestamp_source
	info.rate_hz = p_rate_hz
	return info


func available() -> bool:
	return state == CapabilityState.AVAILABLE


func to_dict() -> Dictionary:
	return {
		"capability": SensorCapability.id_to_string(capability_id),
		"provider_id": provider_id,
		"state": CapabilityState.id_to_string(state),
		"reason": reason,
		"payload_format": payload_format,
		"coordinate_space": coordinate_space,
		"timestamp_source": timestamp_source,
		"rate_hz": rate_hz,
	}
