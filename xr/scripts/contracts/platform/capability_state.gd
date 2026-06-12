class_name CapabilityState
extends RefCounted
## v2 contracts: availability state of a SensorCapability on this device.

const UNAVAILABLE := 0
const AVAILABLE := 1
const REQUIRES_PERMISSION := 2
const PERMISSION_DENIED := 3
const REQUIRES_RUNTIME_EXTENSION := 4
const REQUIRES_BUILD_FEATURE := 5
const TEMPORARILY_UNAVAILABLE := 6
const ERROR := 7

const _NAMES := {
	UNAVAILABLE: "unavailable",
	AVAILABLE: "available",
	REQUIRES_PERMISSION: "requires_permission",
	PERMISSION_DENIED: "permission_denied",
	REQUIRES_RUNTIME_EXTENSION: "requires_runtime_extension",
	REQUIRES_BUILD_FEATURE: "requires_build_feature",
	TEMPORARILY_UNAVAILABLE: "temporarily_unavailable",
	ERROR: "error",
}


static func id_to_string(state: int) -> String:
	return str(_NAMES.get(state, "unknown"))
