extends RefCounted
## Unit coverage for descriptor-driven EE-pose trail routing and segment breaks.

const CASE_ID := "teleop.ee_pose_trajectory"
const HAND_LEFT := 0
const HAND_RIGHT := 1


func run(ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var trajectory := EEPoseTrajectory.new()
	trajectory.min_point_distance_m = 0.005
	t.eq(trajectory.max_segments_per_hand, 2,
		"operation trails retain two deadman segments by default")
	trajectory.configure_for_device({
		"input_mapping": [
			{"source": "active_controller_pose", "target": "custom_tool_target"},
		]
	})
	trajectory.set_enabled(true)

	trajectory.record_command(
		{"poses": {"custom_tool_target": {"position": [0.0, 1.0, -0.3]}}},
		HAND_LEFT,
		{HAND_LEFT: true, HAND_RIGHT: false}
	)
	t.eq(trajectory.point_count(HAND_LEFT), 1,
		"active-controller targets follow the current driving hand")
	t.eq(trajectory.point_count(HAND_RIGHT), 0,
		"the idle hand does not receive the single-arm trail")

	trajectory.record_command(
		{"poses": {"custom_tool_target": {"position": [0.02, 1.0, -0.3]}}},
		HAND_LEFT,
		{HAND_LEFT: true, HAND_RIGHT: false}
	)
	t.eq(trajectory.line_segment_count(HAND_LEFT), 1,
		"successive active poses form a trail segment")

	# Releasing the deadman closes the current polyline. The next press records
	# a new starting point without drawing a jump across the inactive interval.
	trajectory.record_command(
		{"poses": {"custom_tool_target": {"position": [0.5, 1.0, -0.3]}}},
		HAND_LEFT,
		{HAND_LEFT: false, HAND_RIGHT: false}
	)
	trajectory.record_command(
		{"poses": {"custom_tool_target": {"position": [0.6, 1.0, -0.3]}}},
		HAND_LEFT,
		{HAND_LEFT: true, HAND_RIGHT: false}
	)
	t.eq(trajectory.point_count(HAND_LEFT), 3,
		"a new deadman interval starts a new stored trail point")
	t.eq(trajectory.line_segment_count(HAND_LEFT), 1,
		"deadman release prevents a bridge segment across inactive motion")

	# Complete the second segment, then start a third one. The first segment is
	# discarded as a whole while the two newest deadman intervals remain.
	trajectory.record_command(
		{"poses": {"custom_tool_target": {"position": [0.62, 1.0, -0.3]}}},
		HAND_LEFT,
		{HAND_LEFT: true, HAND_RIGHT: false}
	)
	trajectory.record_command(
		{"poses": {"custom_tool_target": {"position": [0.8, 1.0, -0.3]}}},
		HAND_LEFT,
		{HAND_LEFT: false, HAND_RIGHT: false}
	)
	trajectory.record_command(
		{"poses": {"custom_tool_target": {"position": [1.0, 1.0, -0.3]}}},
		HAND_LEFT,
		{HAND_LEFT: true, HAND_RIGHT: false}
	)
	t.eq(trajectory.trajectory_segment_count(HAND_LEFT), 2,
		"starting a third operation keeps only the two newest segments")
	t.eq(trajectory.point_count(HAND_LEFT), 3,
		"the oldest operation segment is removed with all of its points")
	t.eq(trajectory.line_segment_count(HAND_LEFT), 1,
		"retained operations are never bridged together")
	trajectory.record_command(
		{"poses": {"custom_tool_target": {"position": [1.02, 1.0, -0.3]}}},
		HAND_LEFT,
		{HAND_LEFT: true, HAND_RIGHT: false}
	)
	t.eq(trajectory.line_segment_count(HAND_LEFT), 2,
		"the newest operation continues drawing after old-segment eviction")

	var registry: OperatorTestRegistry = ctx.get("registry")
	var dual_fixture: Dictionary = registry.fixture("fake_robot_descriptor_so101_dual")
	trajectory.configure_for_device(dual_fixture.get("descriptor", dual_fixture))
	trajectory.record_command(
		{
			"poses": {
				"left_end_effector": {"position": [-0.2, 1.1, -0.4]},
				"right_end_effector": {"position": [0.2, 1.1, -0.4]},
			}
		},
		HAND_RIGHT,
		{HAND_LEFT: true, HAND_RIGHT: true}
	)
	t.eq(trajectory.point_count(HAND_LEFT), 1,
		"dual descriptor routes the left EE pose to the left trail")
	t.eq(trajectory.point_count(HAND_RIGHT), 1,
		"dual descriptor routes the right EE pose to the right trail")

	# Reset-to-home is a successfully sent DeviceCommand button. It clears both
	# hands and must not draw the poses bundled in the reset command itself.
	trajectory.record_command(
		{
			"buttons": {"reset": true},
			"poses": {
				"left_end_effector": {"position": [-0.4, 1.2, -0.5]},
				"right_end_effector": {"position": [0.4, 1.2, -0.5]},
			}
		},
		HAND_RIGHT,
		{HAND_LEFT: true, HAND_RIGHT: true}
	)
	t.eq(trajectory.point_count(HAND_LEFT), 0,
		"reset-to-home clears every left-hand trajectory segment")
	t.eq(trajectory.point_count(HAND_RIGHT), 0,
		"reset-to-home clears every right-hand trajectory segment")

	trajectory.set_enabled(false)
	t.eq(trajectory.point_count(HAND_LEFT), 0, "disabling clears the left trail")
	t.eq(trajectory.point_count(HAND_RIGHT), 0, "disabling clears the right trail")
	trajectory.free()
