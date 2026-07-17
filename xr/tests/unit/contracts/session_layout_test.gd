extends RefCounted
## Contract test: every artifact created for an Ego recording, including the
## final and partial MP4, belongs to the session directory.

const CASE_ID := "storage.session_layout"
const SessionSpoolWriterScript := preload("res://scripts/core/capture/session_spool_writer.gd")
const EgoUploaderScript := preload("res://scripts/sinks/upload/ego_uploader.gd")


class FakeCameraMetadataPlugin:
	extends RefCounted

	func getDeviceIdentityJson() -> String:
		return JSON.stringify({"device_type": "quest3", "device_model": "Quest 3"})

	func getLeftCameraMetadataJson() -> String:
		return JSON.stringify({
			"recording_intrinsics": {"width": 1280, "height": 960}
		})

	func getRightCameraMetadataJson() -> String:
		return JSON.stringify({
			"recording_width": 1280,
			"recording_height": 960,
		})


func run(ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var storage: TempStorageRoot = ctx.get("storage") as TempStorageRoot
	var root := storage.path()
	var writer := SessionSpoolWriterScript.new()
	writer.set_android_plugin(FakeCameraMetadataPlugin.new())
	var collision_base := "20260716_120000"
	var collision_dir := root.path_join(collision_base)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(collision_dir))
	_write_text(collision_dir.path_join("sentinel.txt"), "keep")
	t.eq(
		writer._make_unique_session_id(root, collision_base),
		"%s_001" % collision_base,
		"existing session directories receive a suffix instead of being reused"
	)
	t.eq(
		FileAccess.get_file_as_string(collision_dir.path_join("sentinel.txt")),
		"keep",
		"collision allocation does not modify the existing session"
	)
	var options := {
		"save_root": root,
		"record_head_pose": true,
		"record_controller_pose": true,
		"record_hand_data": true,
		"record_body_tracking": false,
		"record_motion_trackers": true,
		"record_depth": true,
		"record_audio": false,
	}
	var started := writer.start_session(options)
	t.is_true(started, "writer creates the session directory")
	if not started:
		return

	var session_dir := writer.get_session_dir()
	var session_id := session_dir.get_file()
	var expected_mp4 := session_dir.path_join("%s.mp4" % session_id)
	var expected_partial := session_dir.path_join("%s.partial.mp4" % session_id)
	t.eq(writer.output_mp4_path, expected_mp4, "final MP4 path is inside the session directory")
	t.eq(
		writer.partial_mp4_path,
		expected_partial,
		"partial MP4 path is inside the session directory"
	)
	t.is_true(
		FileAccess.file_exists(session_dir.path_join(SessionLayout.MANIFEST_FILENAME)),
		"manifest is written beside the MP4"
	)
	for optional_dir in [
		"poses",
		"body_motion",
		SessionLayout.DEPTH_DIR,
	]:
		var absolute_dir := ProjectSettings.globalize_path(session_dir.path_join(optional_dir))
		t.is_false(
			DirAccess.dir_exists_absolute(absolute_dir),
			"disabled or empty optional directory is not created: %s" % optional_dir
		)

	var manifest_text := FileAccess.get_file_as_string(
		session_dir.path_join(SessionLayout.MANIFEST_FILENAME)
	)
	var parsed: Variant = JSON.parse_string(manifest_text)
	t.is_true(parsed is Dictionary, "manifest is valid JSON")
	if parsed is Dictionary:
		var manifest := parsed as Dictionary
		t.eq(
			str(manifest.get("output_mp4_path", "")),
			expected_mp4,
			"manifest records the co-located final MP4"
		)
		t.eq(
			str(manifest.get("partial_mp4_path", "")),
			expected_partial,
			"manifest records the co-located partial MP4"
		)

	var media := FileAccess.open(expected_mp4, FileAccess.WRITE)
	t.is_true(media != null, "test can create the finalized MP4 fixture")
	if media == null:
		return
	media.store_string("spatial-mp4-test")
	media.close()
	writer.close()

	for legacy_artifact in [
		"android_timebase.json",
		"left_camera_characteristics.json",
		"right_camera_characteristics.json",
		"left_camera_frames.jsonl",
		"right_camera_frames.jsonl",
	]:
		t.is_false(
			FileAccess.file_exists(session_dir.path_join(legacy_artifact)),
			"default session omits legacy camera file: %s" % legacy_artifact
		)

	var finalized_text := FileAccess.get_file_as_string(
		session_dir.path_join(SessionLayout.MANIFEST_FILENAME)
	)
	var finalized_parsed: Variant = JSON.parse_string(finalized_text)
	t.is_true(finalized_parsed is Dictionary, "finalized manifest is valid JSON")
	if finalized_parsed is Dictionary:
		var finalized_manifest := finalized_parsed as Dictionary
		var resolved := finalized_manifest.get("resolved_capture_options", {}) as Dictionary
		t.eq(int(resolved.get("rgb_width", 0)), 1280, "manifest uses native left camera width")
		t.eq(int(resolved.get("rgb_height", 0)), 960, "manifest uses native left camera height")
		t.eq(int(resolved.get("rgb_encoded_width", 0)), 2560, "manifest records stereo encoded width")
		t.eq(int(resolved.get("rgb_camera_count", 0)), 2, "manifest records two native cameras")
		var confirmations := finalized_manifest.get("stream_confirmations", {}) as Dictionary
		var rgb := confirmations.get("rgb", {}) as Dictionary
		t.is_true(
			bool(rgb.get("saved_in_mp4", false)),
			"RGB confirmation uses embedded MP4 metadata"
		)
		t.eq(str(rgb.get("status", "")), "saved", "RGB stream is confirmed saved")

		var upload_artifacts := {"manifest": {}, "media": {}}
		var upload_order: Array = EgoUploaderScript.new()._artifact_upload_order(upload_artifacts)
		t.eq(str(upload_order.front()), "manifest", "uploader sends manifest first")
		t.eq(str(upload_order.back()), "media", "uploader sends media last")


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(value)
	file.close()
