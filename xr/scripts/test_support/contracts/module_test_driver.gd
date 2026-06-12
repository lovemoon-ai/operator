class_name ModuleTestDriver
extends RefCounted
## v2 test harness (WP7): base automation surface every testable module
## exposes (shape per claw/architecture-v2/xr-module-test-harness.md).
## Tests drive modules through commands/snapshots — never through private
## scene internals.


func module_id() -> String:
	return ""


func supported_cases() -> Array:
	return []


## Prepare the module under test from a deterministic fixture.
## Returns {ok: bool, error?: String, ...}.
func setup(_fixture: Dictionary) -> Dictionary:
	return {"ok": true}


## Automation equivalent of user/system intent (start_capture,
## inject_pose_frame, ...). Returns a structured result dictionary.
func command(_name: String, _args: Dictionary = {}) -> Dictionary:
	return {"ok": false, "error": "unknown command"}


## Deterministic stepping (advances the injected TestClock and any
## frame emission the driver owns).
func step(_delta_s: float, _ticks: int = 1) -> Dictionary:
	return {}


## Structured observable state.
func snapshot() -> Dictionary:
	return {}


## Module invariants checked after commands / at teardown.
## Returns Array[OperatorTestFailure] (empty when healthy).
func assert_invariants() -> Array:
	return []


func teardown() -> void:
	pass
