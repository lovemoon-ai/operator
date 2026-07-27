extends RefCounted
## Device coverage for opening the config page while an Inside Robot is running.
##
## This is the operator's most ordinary action after starting a robot, and it
## was crashing: stopping the embodiment freed meshes the render thread still
## held, and nothing stopped the robot drawing over the settings page. Both are
## invisible to the start-only tests, so this case drives the same target the
## controller drives and asserts what the operator sees.

const CASE_ID := "teleop.inside_settings_roundtrip"
const InsideRobotTargetScript := preload("res://scripts/teleop/targets/inside_robot_target.gd")
const TeleopControllerPanelScript := preload("res://scripts/ui/teleop_controller_panel.gd")
const TrackingProviderScript := preload("res://scripts/xr/tracking_provider.gd")
const GroundGridScript := preload("res://scripts/teleop/simulation/ground_grid_view.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var offered := RobotProfileRegistry.ids()
	if not t.is_true(not offered.is_empty(), "this build ships at least one Inside Robot"):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if not t.is_true(tree != null, "a scene tree is available"):
		return

	var profile_id := str(offered[0])
	var root := Node3D.new()
	root.name = "InsideRoundtripProbe"
	tree.root.add_child(root)
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	var tracking: TrackingProvider = TrackingProviderScript.new()
	root.add_child(tracking)

	var target: Node = InsideRobotTargetScript.new()
	var faults: Array[String] = []
	target.faulted.connect(func(code: String, message: String) -> void:
		faults.append("%s: %s" % [code, message])
	)
	target.configure_runtime(root, origin, camera, tracking)
	root.add_child(target)

	var config := {"inside_profile": profile_id, "retargeting_backend": "native"}
	target.start(config)
	t.is_true(target.is_ready(), "%s starts" % profile_id)
	t.is_true(_count_meshes(root) > 0 or target.get("_overlay") != null, "robot is rendering")
	t.is_true(
		target.get("_vr_pose_overlay") == null,
		"VR Pose skeleton is absent when the Display option is off"
	)

	# Inside descriptors may still carry controller mappings (SO101 does), but
	# the grip-mounted operation-help overlay is only useful for Outside robots.
	var controller_overlay: Node = TeleopControllerPanelScript.new()
	controller_overlay.call("configure_for_device", target.descriptor)
	t.is_false(
		bool(controller_overlay.get("_enabled_for_device")),
		"Inside mode disables the controller-mounted overlay"
	)
	controller_overlay.free()

	# An overlay renders the robot itself, so no MuJoCo skeleton/mesh view must
	# be stacked on top of it, and the overlay's authoring decorations (ground
	# grid, VR-pose markers) must be off for the operator.
	var overlay: Node = target.get("_overlay")
	if overlay != null:
		t.is_true(
			target.get("_simulation_view") == null,
			"%s shows no debug skeleton over its overlay" % profile_id
		)
		if "show_ground_grid" in overlay:
			t.is_false(overlay.get("show_ground_grid"), "%s hides the ground grid" % profile_id)
		if "debug_show_vr_pose" in overlay:
			t.is_false(
				overlay.get("debug_show_vr_pose"),
				"%s keeps its private VR-pose markers hidden" % profile_id
			)

	# The Display option uses the shared canonical skeleton, rather than a
	# robot-specific debug implementation. It is world-locked beside the
	# currently rendered robot and therefore works for every profile.
	target.stop()
	target.start(
		{
			"inside_profile": profile_id,
			"retargeting_backend": "native",
			"show_vr_pose": true,
		}
	)
	var toggled: Node3D = target.get("_overlay")
	var toggled_visual: Node3D = (
		toggled if toggled != null else target.get("_simulation_view")
	)
	var vr_pose: Node3D = target.get("_vr_pose_overlay")
	t.is_true(vr_pose != null, "%s show_vr_pose creates the canonical skeleton" % profile_id)
	if vr_pose != null:
		t.is_false(
			bool(vr_pose.get("follow_head_camera")),
			"%s VR Pose skeleton is world-locked" % profile_id
		)
		t.is_true(
			vr_pose.get("_reference_visual") == toggled_visual,
			"%s VR Pose skeleton is anchored beside the robot" % profile_id
		)
		if toggled_visual != null:
			if toggled_visual.has_method("_lock_in_front_of_view"):
				toggled_visual.call("_lock_in_front_of_view")
			elif toggled_visual.has_method("bind_now"):
				toggled_visual.call("bind_now")
			vr_pose.call("_on_canonical_frame_ready", _synthetic_body_frame())
			t.is_true(
				bool(vr_pose.get("_display_root_locked")),
				"%s VR Pose skeleton resolves a stable world anchor" % profile_id
			)
			var robot_box := GroundGridScript.world_aabb(toggled_visual)
			var robot_center := robot_box.position + robot_box.size * 0.5
			var camera_right := camera.global_transform.basis.x.normalized()
			var display_root: Transform3D = vr_pose.get("_display_root")
			t.is_true(
				(display_root.origin - robot_center).dot(camera_right) > 0.0,
				"%s VR Pose skeleton is on the robot's visible right side" % profile_id
			)
			var hips: MeshInstance3D = vr_pose.get_node_or_null("BodyPosePoint_hips")
			t.is_true(
				hips != null and hips.visible,
				"%s VR Pose skeleton renders canonical joints" % profile_id
			)
	if toggled != null and "debug_show_vr_pose" in toggled:
		t.is_false(
			bool(toggled.get("debug_show_vr_pose")),
			"%s does not stack its private pose markers over the shared skeleton" % profile_id
		)
	# Restore the default embodiment for the round-trip checks below.
	target.stop()
	target.start(config)
	t.is_true(target.is_ready(), "%s restarts after the VR-pose check" % profile_id)
	overlay = target.get("_overlay")

	# The shared ground grid is the operator's height reference: it must exist
	# and sit at the base (lowest point) of the robot, not float at its middle.
	var grid: Node = target.get("_ground_grid")
	if t.is_true(grid != null, "%s has a ground grid" % profile_id):
		var robot_visual: Node3D = overlay if overlay != null else target.get("_simulation_view")
		if robot_visual != null and grid.has_method("place_under_robot"):
			t.is_true(grid.call("place_under_robot"), "%s grid places under the robot" % profile_id)
			var box: AABB = GroundGridScript.world_aabb(robot_visual)
			t.almost_eq(
				(grid as Node3D).global_position.y,
				box.position.y,
				0.02,
				"%s grid sits at the robot's base" % profile_id
			)
			var locked_position := (grid as Node3D).global_position
			var original_visual_transform := robot_visual.global_transform
			robot_visual.global_position += Vector3(0.25, 0.10, 0.25)
			grid.call("_process", 1.0)
			t.eq(
				(grid as Node3D).global_position,
				locked_position,
				"%s grid remains fixed in world space after placement" % profile_id
			)
			robot_visual.global_transform = original_visual_transform

	# Opening the config page: the controller stops the target so the robot
	# neither obscures the page nor keeps its meshes resident.
	target.stop()
	t.is_true(target.is_stopped(), "opening the page stops the embodiment")
	t.eq(_count_meshes(root), 0, "nothing renders behind the config page")

	# Closing without confirming restores the robot the operator interrupted.
	target.start(config)
	t.is_true(target.is_ready(), "closing the page restores the robot")
	t.is_true(faults.is_empty(), "no fault across the round trip (%s)" % ", ".join(faults))

	# A second round trip is where a stale freed node would surface.
	target.stop()
	target.start(config)
	t.is_true(target.is_ready(), "a second round trip still works")
	t.is_true(faults.is_empty(), "no fault after two round trips (%s)" % ", ".join(faults))

	target.stop()
	t.is_true(target.get("_vr_pose_overlay") == null, "stopping releases the VR Pose skeleton")
	root.queue_free()
	t.log_line("%s survived two config-page round trips" % profile_id)


func _count_meshes(node: Node) -> int:
	var total := 0
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		if instance.mesh != null and instance.get_aabb().size.length() > 0.0001:
			total += 1
	for child in node.get_children():
		total += _count_meshes(child)
	return total


func _synthetic_body_frame() -> Dictionary:
	return {
		"joints": {
			"hips": _joint(Vector3(0.0, 1.0, 0.0)),
			"spine": _joint(Vector3(0.0, 1.2, 0.0)),
			"chest": _joint(Vector3(0.0, 1.4, 0.0)),
			"head": _joint(Vector3(0.0, 1.75, 0.0)),
			"left_shoulder": _joint(Vector3(-0.2, 1.45, 0.0)),
			"left_upper_arm": _joint(Vector3(-0.4, 1.4, 0.0)),
			"left_lower_arm": _joint(Vector3(-0.6, 1.3, 0.0)),
			"right_shoulder": _joint(Vector3(0.2, 1.45, 0.0)),
			"right_upper_arm": _joint(Vector3(0.4, 1.4, 0.0)),
			"right_lower_arm": _joint(Vector3(0.6, 1.3, 0.0)),
			"left_upper_leg": _joint(Vector3(-0.1, 0.9, 0.0)),
			"left_lower_leg": _joint(Vector3(-0.1, 0.45, 0.0)),
			"left_foot": _joint(Vector3(-0.1, 0.05, 0.0)),
			"right_upper_leg": _joint(Vector3(0.1, 0.9, 0.0)),
			"right_lower_leg": _joint(Vector3(0.1, 0.45, 0.0)),
			"right_foot": _joint(Vector3(0.1, 0.05, 0.0)),
		}
	}


func _joint(position: Vector3) -> Dictionary:
	return {
		"valid": true,
		"tracked": true,
		"inferred": false,
		"pose": {
			"p": [position.x, position.y, position.z],
			"q": [0.0, 0.0, 0.0, 1.0],
		}
	}
