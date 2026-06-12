class_name OperatorTestResult
extends RefCounted
## v2 test harness (WP7): shared result schema produced by every runner so
## host tests, Godot module tests, and device tests are comparable in CI.

const STATUS_PASS := "pass"
const STATUS_FAIL := "fail"
const STATUS_SKIP := "skipped"
const STATUS_ERROR := "error"

var suite_id := ""
var case_id := ""
var module_id := ""
var feature_ids: Array = []
var level := ""
var status := STATUS_SKIP
var duration_ms := 0
var device_kind := ""
var preset_name := ""
var capabilities: Array = []
var fixture_id := ""
var failures: Array = []  # Array[OperatorTestFailure]
var artifacts: Array = []  # Array[String] (paths)
var logs: Array = []  # Array[String]


func to_dict() -> Dictionary:
	var failure_dicts: Array = []
	for failure in failures:
		if failure is OperatorTestFailure:
			failure_dicts.append((failure as OperatorTestFailure).to_dict())
		else:
			failure_dicts.append({"code": "failure", "message": str(failure), "details": {}})
	return {
		"suite_id": suite_id,
		"case_id": case_id,
		"module_id": module_id,
		"feature_ids": feature_ids,
		"level": level,
		"status": status,
		"duration_ms": duration_ms,
		"device_kind": device_kind,
		"preset_name": preset_name,
		"capabilities": capabilities,
		"fixture_id": fixture_id,
		"failures": failure_dicts,
		"artifacts": artifacts,
		"logs": logs,
	}
