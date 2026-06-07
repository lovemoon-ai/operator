@tool
extends EditorPlugin

var _android_export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_android_export_plugin = QuestCaptureAndroidExportPlugin.new()
	add_export_plugin(_android_export_plugin)


func _exit_tree() -> void:
	if _android_export_plugin:
		remove_export_plugin(_android_export_plugin)
		_android_export_plugin = null


class QuestCaptureAndroidExportPlugin:
	extends EditorExportPlugin

	var _include_quest := false

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return "QuestCapturePlugin"

	func _export_begin(features: PackedStringArray, is_debug: bool, path: String, flags: int) -> void:
		_include_quest = features.has("quest")

	func _export_end() -> void:
		_include_quest = false

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var libraries := PackedStringArray()
		if not _include_quest:
			return libraries
		var flavor := "debug" if debug else "release"
		# Stage 3 split: the muxer's AAR moved to addons/spatialmp4_muxer/ and
		# is exported by that addon's plugin. quest_capture_android now ships
		# only the provider (Camera2 + HEVC encoder + clock + depth conversion).
		var addon_relative_path := "quest_capture_android/bin/questcapture-%s.aar" % flavor
		if FileAccess.file_exists("res://addons/%s" % addon_relative_path):
			libraries.append(addon_relative_path)
		return libraries

	func _get_android_manifest_element_contents(platform: EditorExportPlatform, debug: bool) -> String:
		if not _include_quest:
			return ""
		# BOUNDARYLESS_APP opts the app into Meta's Boundaryless mode so the
		# Quest runtime fully suppresses the guardian (not just the visual
		# overlay) while a passthrough layer is being rendered. Combined with
		# the XR_META_boundary_visibility call in capture_app.gd, this also
		# stops the boundary from re-appearing when the user walks beyond the
		# configured play space. See:
		#   https://developers.meta.com/horizon/documentation/unity/unity-boundaryless/
		# Requirements: 6DOF app (Quest 3 is 6DOF), passthrough actively
		# rendered. Has no effect on Quest 2 in fully-immersive VR sessions.
		return """
	<uses-permission android:name="com.oculus.permission.BOUNDARY_VISIBILITY" />
	<uses-feature android:name="com.oculus.feature.BOUNDARYLESS_APP" android:required="true" />
	<uses-feature android:name="android.hardware.camera" android:required="false" />
	<uses-feature android:name="android.hardware.vr.headtracking" android:version="1" android:required="true" />
	"""
