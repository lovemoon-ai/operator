class_name OperatorTestRunner
extends RefCounted
## v2 test harness (WP7): executes registered test cases.
## Lifecycle per case: load fixture -> build deterministic context
## (TestClock, temp storage, registry) -> run the case script
## (run(ctx, t)) -> collect failures -> teardown/cleanup -> report.
##
## Test scripts are plain RefCounted GDScripts exposing:
##   func run(ctx: Dictionary, t: OperatorTestAssertions) -> void
## ctx keys: case (OperatorTestCase), fixture (Dictionary), registry
## (OperatorTestRegistry), clock (OperatorTestClock), storage
## (TempStorageRoot).

var _registry: OperatorTestRegistry
var _reporter: OperatorTestReporter


func _init(registry: OperatorTestRegistry = null, reporter: OperatorTestReporter = null) -> void:
	_registry = registry if registry != null else OperatorTestRegistry.new()
	_reporter = reporter if reporter != null else OperatorTestReporter.new()


func registry() -> OperatorTestRegistry:
	return _registry


func reporter() -> OperatorTestReporter:
	return _reporter


## Run all cases matching the filters. Returns Array[OperatorTestResult].
func run(suite_filter := "", case_filter := "") -> Array:
	var out: Array = []
	for case_v in _registry.cases(suite_filter, case_filter):
		out.append(run_case(case_v as OperatorTestCase))
	return out


func run_case(test_case: OperatorTestCase) -> OperatorTestResult:
	var result := OperatorTestResult.new()
	result.suite_id = test_case.suite_id
	result.case_id = test_case.case_id
	result.module_id = test_case.module_id
	result.feature_ids = test_case.feature_ids.duplicate()
	result.level = test_case.level
	result.fixture_id = test_case.fixture_id
	result.device_kind = OS.get_name().to_lower()

	if not test_case.runnable():
		# Static / preset-matrix cases are validated host-side
		# (tests/validate_xr_features.py, validate_xr_test_manifests.py);
		# device-level placeholders without scripts are also skipped.
		result.status = OperatorTestResult.STATUS_SKIP
		_reporter.on_case_finished(result)
		return result

	_reporter.on_case_start(test_case.suite_id, test_case.case_id)
	var start_ms := Time.get_ticks_msec()
	var t := OperatorTestAssertions.new()
	var storage := TempStorageRoot.new(test_case.case_id)

	var script: GDScript = load(test_case.script_path)
	if script == null:
		t.fail("setup", "cannot load test script %s" % test_case.script_path)
	else:
		var instance: Variant = script.new()
		if instance == null or not (instance as Object).has_method("run"):
			t.fail("setup", "test script %s has no run(ctx, t)" % test_case.script_path)
		else:
			var ctx := {
				"case": test_case,
				"fixture": _registry.fixture(test_case.fixture_id),
				"registry": _registry,
				"clock": OperatorTestClock.new(),
				"storage": storage,
			}
			instance.run(ctx, t)

	# Teardown must always run to clean storage even when the case failed.
	storage.cleanup()

	result.duration_ms = Time.get_ticks_msec() - start_ms
	result.failures = t.failures()
	result.logs = t.logs()
	result.status = OperatorTestResult.STATUS_PASS if t.passed() else OperatorTestResult.STATUS_FAIL
	_reporter.on_case_finished(result)
	return result
