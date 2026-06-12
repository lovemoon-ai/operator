class_name OperatorTestReporter
extends RefCounted
## v2 test harness (WP7): logcat markers + machine-readable JSON results.
##
## Marker strings are part of the harness contract (consumed by
## tests/xr_module_harness.sh):
##   OPERATOR_TEST_START suite=<s> case=<c>
##   OPERATOR_TEST_PASS suite=<s> case=<c>
##   OPERATOR_TEST_FAIL suite=<s> case=<c> reason=<...>
##
## JSON results go to user://test_results/<suite>.json and, when the
## Android external files dir is reachable, are mirrored there so adb can
## pull them without run-as.

const RESULTS_DIR := "user://test_results"

var _results: Array = []  # Array[OperatorTestResult]


func on_case_start(suite_id: String, case_id: String) -> void:
	print("OPERATOR_TEST_START suite=%s case=%s" % [suite_id, case_id])


func on_case_finished(result: OperatorTestResult) -> void:
	_results.append(result)
	match result.status:
		OperatorTestResult.STATUS_PASS:
			print("OPERATOR_TEST_PASS suite=%s case=%s" % [result.suite_id, result.case_id])
		OperatorTestResult.STATUS_SKIP:
			print("OPERATOR_TEST_SKIP suite=%s case=%s" % [result.suite_id, result.case_id])
		_:
			print("OPERATOR_TEST_FAIL suite=%s case=%s reason=%s" % [
				result.suite_id, result.case_id, _first_reason(result)])


func results() -> Array:
	return _results


func pass_count() -> int:
	return _count(OperatorTestResult.STATUS_PASS)


func fail_count() -> int:
	var failed := 0
	for result in _results:
		if (result as OperatorTestResult).status in [
				OperatorTestResult.STATUS_FAIL, OperatorTestResult.STATUS_ERROR]:
			failed += 1
	return failed


func skip_count() -> int:
	return _count(OperatorTestResult.STATUS_SKIP)


## Writes one JSON document per suite seen. Returns the written paths.
func write_results() -> Array:
	var by_suite: Dictionary = {}
	for result_v in _results:
		var result := result_v as OperatorTestResult
		if not by_suite.has(result.suite_id):
			by_suite[result.suite_id] = []
		(by_suite[result.suite_id] as Array).append(result.to_dict())
	var written: Array = []
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RESULTS_DIR))
	for suite_id in by_suite.keys():
		var doc := {
			"suite_id": suite_id,
			"generated_unix_ms": Time.get_unix_time_from_system() * 1000.0,
			"results": by_suite[suite_id],
		}
		var json_text := JSON.stringify(doc, "  ")
		var path := "%s/%s.json" % [RESULTS_DIR, str(suite_id).replace("/", "_")]
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(json_text)
			file.close()
			written.append(ProjectSettings.globalize_path(path))
		_mirror_to_external(str(suite_id).replace("/", "_"), json_text, written)
	return written


static func _mirror_to_external(suite_file: String, json_text: String, written: Array) -> void:
	# Android external files dir (adb-pullable without run-as). No-op on
	# platforms where the path does not exist.
	if OS.get_name() != "Android":
		return
	var external_root := "/sdcard/Android/data/com.lovemoon.operator/files/test_results"
	if DirAccess.make_dir_recursive_absolute(external_root) != OK \
			and not DirAccess.dir_exists_absolute(external_root):
		return
	var path := "%s/%s.json" % [external_root, suite_file]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(json_text)
		file.close()
		written.append(path)


func _count(status: String) -> int:
	var n := 0
	for result in _results:
		if (result as OperatorTestResult).status == status:
			n += 1
	return n


static func _first_reason(result: OperatorTestResult) -> String:
	if result.failures.is_empty():
		return "unknown"
	var failure: Variant = result.failures[0]
	var reason := str((failure as OperatorTestFailure).message) \
			if failure is OperatorTestFailure else str(failure)
	# Keep the marker single-line and grep-friendly.
	return reason.replace("\n", " ").replace("=", ":")
