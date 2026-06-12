extends Node
## v2 test harness (WP7): root script for the non-XR test runner scene
## (res://scenes/test_runner.tscn). Entered only when the
## operator_feature_test_harness feature is enabled AND a test suite was
## explicitly requested (Android intent extras surface as command-line
## args, same mechanism as operator.mode). Never initializes StartXR.
##
## Launch shape:
##   adb shell am start -n com.lovemoon.operator/com.godot.game.GodotApp \
##     --es operator_test_suite capture.pipeline \
##     --es operator_test_case capture.start_stop_with_fake_sources

const SUITE_ARG_KEYS := ["operator_test_suite", "--operator-test-suite"]
const CASE_ARG_KEYS := ["operator_test_case", "--operator-test-case"]


func _ready() -> void:
	# Defer one frame so scene-change bookkeeping settles before we quit.
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	var suite := _arg_value(SUITE_ARG_KEYS)
	var case_id := _arg_value(CASE_ARG_KEYS)
	if suite.is_empty():
		suite = "all"
	print("[OperatorTestRunner] suite=%s case=%s" % [suite, case_id if not case_id.is_empty() else "<all>"])

	var runner := OperatorTestRunner.new()
	for error in runner.registry().load_errors():
		print("[OperatorTestRunner] manifest error: %s" % error)
	runner.run(suite, case_id)

	var reporter := runner.reporter()
	for path in reporter.write_results():
		print("[OperatorTestRunner] results written: %s" % path)
	print("OPERATOR_TEST_SUITE_DONE suite=%s pass=%d fail=%d skip=%d" % [
		suite, reporter.pass_count(), reporter.fail_count(), reporter.skip_count()])
	await get_tree().process_frame
	get_tree().quit(1 if reporter.fail_count() > 0 else 0)


static func _arg_value(keys: Array) -> String:
	var all_args: Array = []
	all_args.append_array(OS.get_cmdline_user_args())
	all_args.append_array(OS.get_cmdline_args())
	for i in range(all_args.size()):
		var arg := String(all_args[i]).strip_edges()
		for key_v in keys:
			var key := String(key_v)
			if arg == key and i + 1 < all_args.size():
				return String(all_args[i + 1]).strip_edges()
			if arg.begins_with(key + "="):
				return arg.substr(key.length() + 1).strip_edges()
	return ""
