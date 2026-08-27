@tool
extends EditorPlugin

# Ships qrscanner-<flavor>.aar and its ZXing runtime jar into Android exports.
# The runtime entry-point is the Android GodotPlugin singleton
# "QRScannerPlugin"; GDScript accesses it via Engine.get_singleton(). See
# xr/scripts/ego_qr_scanner.gd.

var _android_export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_android_export_plugin = QRScannerAndroidExportPlugin.new()
	add_export_plugin(_android_export_plugin)


func _exit_tree() -> void:
	if _android_export_plugin:
		remove_export_plugin(_android_export_plugin)
		_android_export_plugin = null


class QRScannerAndroidExportPlugin:
	extends EditorExportPlugin

	var _include_capture := false

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return "QRScannerPlugin"

	func _export_begin(
		features: PackedStringArray, _is_debug: bool, _path: String, _flags: int
	) -> void:
		_include_capture = features.has("operator_capture_stack")

	func _export_end() -> void:
		_include_capture = false

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var libraries := PackedStringArray()
		if not _include_capture:
			return libraries
		var flavor := "debug" if debug else "release"
		var addon_relative_path := "qr_scanner/bin/qrscanner-%s.aar" % flavor
		if FileAccess.file_exists("res://addons/%s" % addon_relative_path):
			libraries.append(addon_relative_path)
		var zxing_relative_path := "qr_scanner/bin/zxing-core-3.5.3.jar"
		if FileAccess.file_exists("res://addons/%s" % zxing_relative_path):
			libraries.append(zxing_relative_path)
		return libraries
