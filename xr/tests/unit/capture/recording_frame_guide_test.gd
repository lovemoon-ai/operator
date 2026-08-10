extends RefCounted

const RecordingFrameGuideScript := preload("res://scripts/ui/recording_frame_guide.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var centered := {
		"recording_intrinsics": {
			"fx": 640.0,
			"fy": 640.0,
			"cx": 640.0,
			"cy": 480.0,
			"width": 1280,
			"height": 960,
		},
		"lens_pose_translation": [0.0, 0.0, 0.0],
		"lens_pose_rotation": [0.0, 0.0, 0.0, 1.0],
	}
	var geometry: Dictionary = RecordingFrameGuideScript.geometry_from_metadata(centered, 1.5)
	var size: Vector2 = geometry.get("quad_size", Vector2.ZERO)
	var pose: Transform3D = geometry.get("head_from_guide", Transform3D.IDENTITY)
	t.almost_eq(size.x, 3.0, 0.0001, "horizontal field boundary follows recording intrinsics")
	t.almost_eq(size.y, 2.25, 0.0001, "vertical field boundary follows recording intrinsics")
	t.almost_eq(pose.origin.x, 0.0, 0.0001, "centered principal point keeps the guide centered")
	t.almost_eq(pose.origin.y, 0.0, 0.0001, "centered principal point keeps the guide level")
	t.almost_eq(pose.origin.z, -1.5, 0.0001, "guide is projected in front of the headset")

	var off_centered: Dictionary = centered.duplicate(true)
	off_centered["recording_intrinsics"]["cx"] = 600.0
	var off_centered_geometry: Dictionary = RecordingFrameGuideScript.geometry_from_metadata(off_centered, 1.5)
	var off_centered_pose: Transform3D = off_centered_geometry.get("head_from_guide", Transform3D.IDENTITY)
	t.is_true(off_centered_pose.origin.x > 0.0, "principal-point offset shifts the visible guide")

	t.is_true(
		RecordingFrameGuideScript.geometry_from_metadata({"recording_intrinsics": {}}, 1.5).is_empty(),
		"missing calibration fails closed instead of displaying an inaccurate guide"
	)
