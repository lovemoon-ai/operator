## Capture session lifecycle states + legal-transition table (v2 architecture,
## WP3). Pure data contract: no engine, platform, or vendor references so the
## table can be unit-tested off-device (WP7) and reused by fakes.
class_name CaptureState
extends RefCounted

const IDLE := 0
const REQUESTING_PERMISSION := 1
const READY := 2
const STARTING := 3
const RUNNING := 4
const STOPPING := 5
const STOPPED := 6
const ERROR := 7
const RECOVERING := 8

const _NAMES := {
	IDLE: "idle",
	REQUESTING_PERMISSION: "requesting_permission",
	READY: "ready",
	STARTING: "starting",
	RUNNING: "running",
	STOPPING: "stopping",
	STOPPED: "stopped",
	ERROR: "error",
	RECOVERING: "recovering",
}

# Transition table per claw/architecture-v2. Anything not listed is illegal;
# callers must treat an illegal request as an error result, never a crash.
const _LEGAL := {
	IDLE: [REQUESTING_PERMISSION, READY],
	REQUESTING_PERMISSION: [READY, ERROR],
	READY: [STARTING],
	STARTING: [RUNNING, ERROR],
	RUNNING: [STOPPING, ERROR, RECOVERING],
	RECOVERING: [RUNNING, ERROR],
	STOPPING: [STOPPED, ERROR],
	STOPPED: [IDLE],
	ERROR: [IDLE],
}


static func legal(from: int, to: int) -> bool:
	var allowed: Variant = _LEGAL.get(from)
	if typeof(allowed) != TYPE_ARRAY:
		return false
	return (allowed as Array).has(to)


static func state_name(state: int) -> String:
	return str(_NAMES.get(state, "unknown(%d)" % state))
