@tool
extends EditorPlugin
# Ships spatialmp4_muxer-<flavor>.aar (which holds libspatialmp4_writer.so +
# the patched FFmpeg + SpatialMp4MuxerPlugin Kotlin singleton) into the
# exported Android APK. Lives next to the provider addon so each plugin can
# be enabled / disabled independently.

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = SpatialMp4MuxerExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class SpatialMp4MuxerExportPlugin:
	extends EditorExportPlugin

	var _include_spatialmp4 := false

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return "SpatialMp4MuxerPlugin"

	func _export_begin(
		features: PackedStringArray, _is_debug: bool, _path: String, _flags: int
	) -> void:
		_include_spatialmp4 = features.has("operator_capture_stack")

	func _export_end() -> void:
		_include_spatialmp4 = false

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var libraries := PackedStringArray()
		if not _include_spatialmp4:
			return libraries
		var flavor := "debug" if debug else "release"
		var addon_relative_path := "spatialmp4_muxer/bin/spatialmp4_muxer-%s.aar" % flavor
		if FileAccess.file_exists("res://addons/%s" % addon_relative_path):
			libraries.append(addon_relative_path)
		return libraries
