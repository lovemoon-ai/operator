@tool
extends EditorPlugin
# Ships capture_common-<flavor>.aar into Android exports. Quest/PICO provider
# AARs depend on these shared Kotlin classes but keep their vendor-specific
# camera/OpenXR logic in their own modules.

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = CaptureCommonExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class CaptureCommonExportPlugin:
	extends EditorExportPlugin

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return "SpatialCaptureCommon"

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var libraries := PackedStringArray()
		var flavor := "debug" if debug else "release"
		var addon_relative_path := "capture_common/bin/capture_common-%s.aar" % flavor
		if FileAccess.file_exists("res://addons/%s" % addon_relative_path):
			libraries.append(addon_relative_path)
		return libraries
