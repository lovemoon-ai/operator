@tool
extends EditorPlugin

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = OperatorLauncherExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class OperatorLauncherExportPlugin:
	extends EditorExportPlugin

	const CONFIGURED_FEATURE := "operator_launcher_cards_configured"
	const CARD_OPTIONS := [
		{"name": "operator_launcher_card_teleop", "default": false},
		{"name": "operator_launcher_card_ego", "default": true},
		{"name": "operator_launcher_card_live", "default": false},
		{"name": "operator_launcher_card_pose_inference", "default": true},
		{"name": "operator_launcher_card_memworld", "default": true},
		{"name": "operator_launcher_card_vr", "default": false},
		{"name": "operator_launcher_card_exit", "default": true},
	]

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return "operator-launcher"

	func _get_export_options(platform: EditorExportPlatform) -> Array[Dictionary]:
		var options: Array[Dictionary] = []
		for card_option in CARD_OPTIONS:
			options.append({
				"option": {
					"name": String(card_option["name"]),
					"type": TYPE_BOOL,
				},
				"default_value": bool(card_option["default"]),
			})
		return options

	func _get_export_features(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var features := PackedStringArray([CONFIGURED_FEATURE])
		for card_option in CARD_OPTIONS:
			var option_name := String(card_option["name"])
			if bool(get_option(option_name)):
				features.append(option_name)
		return features
