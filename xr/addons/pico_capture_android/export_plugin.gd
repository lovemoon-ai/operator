@tool
extends EditorPlugin

var _android_export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_android_export_plugin = PicoCaptureAndroidExportPlugin.new()
	add_export_plugin(_android_export_plugin)


func _exit_tree() -> void:
	if _android_export_plugin:
		remove_export_plugin(_android_export_plugin)
		_android_export_plugin = null


class PicoCaptureAndroidExportPlugin:
	extends EditorExportPlugin

	var _include_pico := false

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return "PicoCapturePlugin"

	func _export_begin(features: PackedStringArray, is_debug: bool, path: String, flags: int) -> void:
		_include_pico = features.has("pico")

	func _export_end() -> void:
		_include_pico = false

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var libraries := PackedStringArray()
		if not _include_pico:
			return libraries
		var flavor := "debug" if debug else "release"
		var addon_relative_path := "pico_capture_android/bin/picocapture-%s.aar" % flavor
		if FileAccess.file_exists("res://addons/%s" % addon_relative_path):
			libraries.append(addon_relative_path)
		return libraries

	func _export_file(path: String, type: String, features: PackedStringArray) -> void:
		if features.has("pico"):
			return
		if path.begins_with("res://addons/pico_openxr/"):
			skip()

	func _get_android_manifest_element_contents(platform: EditorExportPlatform, debug: bool) -> String:
		if not _include_pico:
			return ""
		return """
	<uses-permission android:name="com.picovr.permission.HEAD_TRACKER" />
	<uses-permission android:name="com.pico.permission.CAMERA_DATA" />
	<uses-feature android:name="android.hardware.camera" android:required="false" />
	<uses-feature android:name="android.hardware.vr.headtracking" android:version="1" android:required="true" />
	"""
