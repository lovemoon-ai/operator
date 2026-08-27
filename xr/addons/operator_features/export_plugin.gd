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
	const QUICK_ENTRY_OPTION := "operator_quick_entry"
	const QUICK_ENTRY_DEFAULT := "launcher"
	const QUICK_ENTRY_MODES := ["launcher", "teleop", "ego_capture", "live_feed"]
	const QUICK_ENTRY_TAG_PREFIX := "operator_quick_entry_"
	# Single-build override for the preset's startup route, so a developer can
	# build the Teleop preset but still land on the launcher. It deliberately
	# overrides *only* the startup route — every product surface (which modes
	# exist, which sinks ship, which resources are packed) comes from the
	# selected export preset alone, so `godot --export-release "Pico Teleop"`
	# from the editor and `make build-pico-teleop` produce the same APK.
	const QUICK_ENTRY_ENV := "OPERATOR_QUICK_ENTRY"
	const CAPTURE_STACK_FEATURE := "operator_capture_stack"
	const QUICK_ENTRY_REQUIRED_FEATURE := {
		"teleop": "operator_feature_mode_teleop",
		"ego_capture": "operator_feature_mode_ego_capture",
		"live_feed": "operator_feature_mode_live_feed",
	}
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
		{"name": "operator_feature_mode_exit", "default": true},
		{"name": "operator_feature_sink_spatialmp4", "default": true},
		{"name": "operator_feature_sink_live_stream", "default": false},
		{"name": "operator_feature_sink_upload", "default": true},
		{"name": "operator_feature_robot_control", "default": false},
		{"name": "operator_feature_robot_constraint", "default": false},
		{"name": "operator_feature_debug_metrics", "default": false},
		{"name": "operator_feature_test_harness", "default": false},
	]
	var _invalid_quick_entry_warned := false

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
		options.append({
			"option": {
				"name": QUICK_ENTRY_OPTION,
				"type": TYPE_STRING,
				"hint": PROPERTY_HINT_ENUM,
				"hint_string": "launcher,teleop,ego_capture,live_feed",
			},
			"default_value": QUICK_ENTRY_DEFAULT,
		})
		return options

	func _get_export_option_warning(
		_platform: EditorExportPlatform, option: String
	) -> String:
		if option != QUICK_ENTRY_OPTION \
				and not option.begins_with("operator_feature_mode_"):
			return ""
		var quick_entry := _selected_quick_entry()
		if quick_entry == QUICK_ENTRY_DEFAULT:
			return ""
		var required_feature := String(QUICK_ENTRY_REQUIRED_FEATURE.get(quick_entry, ""))
		if required_feature.is_empty():
			return "Unknown operator quick entry: %s" % quick_entry
		if not _feature_enabled(required_feature):
			return "%s requires %s to be enabled" % [QUICK_ENTRY_OPTION, required_feature]
		return ""

	func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
		# NOTE: .gd files under these prefixes never reach this hook in 4.5
		# exports — the built-in script export plugin skip()s them first (the
		# plugin loop breaks on skip). The authoritative exclusion is the
		# presets' exclude_filter in export_presets.cfg; this hook remains as
		# belt-and-braces for non-script resources.
		#
		# The same applies to the Teleop presets' capture/VR resources: they are
		# excluded by that preset's own exclude_filter, not here, because a
		# preset is the only thing that decides which product surface an APK
		# ships.
		if _feature_enabled(TEST_HARNESS_OPTION):
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
			if _feature_enabled(option_name):
				features.append(option_name)
		# `operator_capture_stack` must be a preset custom feature. Godot does not
		# propagate features returned here to sibling export plugins or GDExtension
		# library selection, so deriving that tag dynamically would strip native
		# capture libraries from otherwise complete builds.
		features.append(QUICK_ENTRY_TAG_PREFIX + _selected_quick_entry())
		return features

	func _selected_quick_entry() -> String:
		var configured := String(get_option(QUICK_ENTRY_OPTION)).strip_edges().to_lower()
		var override := OS.get_environment(QUICK_ENTRY_ENV).strip_edges().to_lower()
		if not override.is_empty():
			if QUICK_ENTRY_MODES.has(override):
				return override
			if not _invalid_quick_entry_warned:
				push_warning(
					"[operator-features] Ignoring invalid %s=%s"
					% [QUICK_ENTRY_ENV, override]
				)
				_invalid_quick_entry_warned = true
		if not QUICK_ENTRY_MODES.has(configured):
			return QUICK_ENTRY_DEFAULT
		return configured

	func _feature_enabled(option_name: String) -> bool:
		return bool(get_option(option_name))
