extends RefCounted
## WP7 unit test: SensorFrame contract validation rules.

const CASE_ID := "contracts.sensor_frame_validation"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	# A well-formed pose frame validates clean.
	var pose := PoseFrame.build(1_000, Transform3D.IDENTITY, true)
	t.eq(pose.validate().size(), 0, "valid pose frame must have no validation errors")
	t.eq(pose.coordinate_space, "openxr_play_space", "pose frames default to the active OpenXR play space")
	t.eq(pose.frame_type, SensorFrameType.POSE, "PoseFrame builds a POSE frame")
	var local_pose := PoseFrame.build(
		1_001, Transform3D.IDENTITY, true, false,
		OpenXRExportSpace.coordinate_space_id(OpenXRExportSpace.LOCAL))
	t.eq(local_pose.coordinate_space, "openxr_local", "pose builder preserves the selected reference space")
	var floor_controller := ControllerFrame.build_pose(
		"left_controller", 1_002, Transform3D.IDENTITY, true,
		OpenXRExportSpace.coordinate_space_id(OpenXRExportSpace.LOCAL_FLOOR))
	t.eq(floor_controller.coordinate_space, "openxr_local_floor",
		"controller builder preserves the selected reference space")
	t.eq(OpenXRExportSpace.play_area_mode(OpenXRExportSpace.STAGE), XRInterface.XR_PLAY_AREA_STAGE,
		"STAGE maps to Godot's stage play-area mode")
	t.eq(OpenXRExportSpace.play_area_mode(OpenXRExportSpace.LOCAL), XRInterface.XR_PLAY_AREA_SITTING,
		"LOCAL maps to Godot's sitting/local play-area mode")
	t.eq(OpenXRExportSpace.play_area_mode(OpenXRExportSpace.LOCAL_FLOOR), XRInterface.XR_PLAY_AREA_ROOMSCALE,
		"LOCAL_FLOOR maps to Godot's roomscale/local-floor play-area mode")

	# Unknown frame type rejected.
	var unknown := SensorFrame.new()
	unknown.frame_type = 999
	unknown.timestamp_ns = 1_000
	t.is_true(unknown.validate().size() > 0, "unknown frame_type must be rejected")

	# Non-positive timestamp rejected.
	var stale := PoseFrame.build(0, Transform3D.IDENTITY, true)
	var stale_errors := stale.validate()
	t.is_true(stale_errors.size() > 0, "timestamp_ns <= 0 must be rejected")

	# Pose-like frames without a coordinate space are invalid at module
	# boundaries (doc rule).
	var spaceless := SensorFrame.new()
	spaceless.frame_type = SensorFrameType.BODY
	spaceless.timestamp_ns = 2_000
	spaceless.coordinate_space = ""
	t.is_true(spaceless.validate().size() > 0,
		"pose-like frame without coordinate_space must be rejected")

	# Non-spatial frames (depth) do not require a coordinate space.
	var depth := DepthFrame.build(3_000, "left", 4, 4, {}, PackedByteArray())
	t.eq(depth.validate().size(), 0, "depth frame without coordinate_space is valid")

	# Builders preserve payload field names sinks rely on.
	var input := ControllerFrame.build_input("right_controller", 4_000, 0,
		{"trigger_value": 0.5, "grip_value": 1.0}, 3)
	t.eq(input.frame_type, SensorFrameType.INPUT_EVENT, "input packets are INPUT_EVENT frames")
	for key in ["packet_type", "available_mask", "pressed_mask", "touched_mask",
			"changed_mask", "trigger_value", "grip_value", "thumbstick", "trackpad"]:
		t.contains(input.payload, key, "input payload must carry '%s'" % key)
