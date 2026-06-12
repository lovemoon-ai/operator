@tool
extends EditorPlugin

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = OperatorFeaturesExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class OperatorFeaturesExportPlugin:
	extends EditorExportPlugin

	const CONFIGURED_FEATURE := "operator_features_configured"
	const TEST_HARNESS_OPTION := "operator_feature_test_harness"
	# Test-only resources excluded from the PCK whenever the test-harness
	# feature is disabled (all production presets). Test APKs (preset
	# "Meta Quest Test") set the option true and keep them.
	const TEST_ONLY_PREFIXES := [
		"res://tests/",
		"res://scripts/test_support/",
		"res://scenes/test_runner.tscn",
	]
	# KEEP IN SYNC with xr/scripts/contracts/features/feature_registry.gd.
	# This table is intentionally duplicated because a @tool export plugin
	# should not preload runtime scripts; tests/validate_xr_features.py
	# cross-checks both tables (name + default).
	const FEATURE_OPTIONS := [
		{"name": "operator_feature_mode_teleop", "default": false},
		{"name": "operator_feature_mode_ego_capture", "default": true},
		{"name": "operator_feature_mode_live_feed", "default": false},
		{"name": "operator_feature_mode_vr", "default": false},
		{"name": "operator_feature_sink_spatialmp4", "default": true},
		{"name": "operator_feature_sink_jsonl", "default": true},
		{"name": "operator_feature_sink_live_stream", "default": false},
		{"name": "operator_feature_sink_upload", "default": true},
		{"name": "operator_feature_robot_control", "default": false},
		{"name": "operator_feature_robot_constraint", "default": false},
		{"name": "operator_feature_debug_metrics", "default": false},
		{"name": "operator_feature_test_harness", "default": false},
	]

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return "operator-features"

	func _get_export_options(platform: EditorExportPlatform) -> Array[Dictionary]:
		var options: Array[Dictionary] = []
		for feature_option in FEATURE_OPTIONS:
			options.append({
				"option": {
					"name": String(feature_option["name"]),
					"type": TYPE_BOOL,
				},
				"default_value": bool(feature_option["default"]),
			})
		return options

	func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
		# NOTE: .gd files under these prefixes never reach this hook in
		# 4.5 exports — the built-in script export plugin skip()s them
		# first (plugin loop breaks on skip). The authoritative exclusion
		# is the production presets' exclude_filter in export_presets.cfg;
		# this hook remains as belt-and-braces for non-script resources.
		if bool(get_option(TEST_HARNESS_OPTION)):
			return
		for prefix in TEST_ONLY_PREFIXES:
			var prefix_string := String(prefix)
			if path == prefix_string or path.begins_with(prefix_string):
				skip()
				return

	func _get_export_features(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var features := PackedStringArray([CONFIGURED_FEATURE])
		for feature_option in FEATURE_OPTIONS:
			var option_name := String(feature_option["name"])
			if bool(get_option(option_name)):
				features.append(option_name)
		return features
