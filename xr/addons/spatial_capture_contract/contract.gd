@tool
extends EditorPlugin
# Registers an Android export hook so spatial_capture_contract/bin/contract.jar
# (the compiled Kotlin/JVM contract types: SpatialDataSink, Intrinsics, etc.)
# ships into the final APK alongside the muxer + provider AARs. Without this,
# the muxer's compileOnly references to SpatialDataSink would resolve at
# build time but the runtime classpath would be missing the interface, and
# QuestCapturePlugin.bindMuxer(...) would ClassNotFoundException on first use.

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = SpatialCaptureContractExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class SpatialCaptureContractExportPlugin:
	extends EditorExportPlugin

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return "SpatialCaptureContract"

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var libraries := PackedStringArray()
		var addon_relative_path := "spatial_capture_contract/bin/contract.jar"
		if FileAccess.file_exists("res://addons/%s" % addon_relative_path):
			libraries.append(addon_relative_path)
		return libraries
