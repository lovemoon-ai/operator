extends RefCounted
## Device coverage for actually starting an Inside Robot.
##
## Every robot the settings page offers must reach READY and materialise an
## embodiment. This is the gap that let a settings key rename ship: the panel
## listed robots, the wire tests solved poses, but nothing exercised the target
## that turns "operator pressed Confirm" into a robot in the scene.

const CASE_ID := "teleop.inside_robot_start"
const InsideRobotTargetScript := preload("res://scripts/teleop/targets/inside_robot_target.gd")
const GroundGridScript := preload("res://scripts/teleop/simulation/ground_grid_view.gd")


class ReadyRemote:
	extends Node

	func is_ready() -> bool:
		return true

	func stop() -> void:
		pass


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var offered := RobotProfileRegistry.ids()
	if not t.is_true(not offered.is_empty(), "this build ships at least one Inside Robot"):
		return

	var tree := Engine.get_main_loop() as SceneTree
	if not t.is_true(tree != null, "a scene tree is available"):
		return

	# One robot per run. Instantiating every offered robot in a single frame
	# loads tens of MB of meshes at once and the renderer dies on the freed
	# scene — a stress no operator creates, since Teleop starts one embodiment.
	# Coverage of the others is cicd/08_inside_robot_display.sh, which launches
	# the app once per robot the way a user does.
	#
	# Prefer a robot rendered by the shared mesh view: the bespoke overlays are
	# each exercised by that gate, while the generic renderer is only reachable
	# here.
	_start_one(tree, _preferred_profile(offered), t)


## The first robot with a visual model and no bespoke overlay, else the first.
func _preferred_profile(offered: Array) -> String:
	for profile_id in offered:
		var profile := RobotProfileRegistry.get_profile(str(profile_id))
		var has_overlay := not str(profile.get("overlay_script", "")).is_empty()
		var has_visual := not str(profile.get("visual_model", "")).is_empty()
		if has_visual and not has_overlay:
			return str(profile_id)
	return str(offered[0])


func _start_one(tree: SceneTree, profile_id: String, t: OperatorTestAssertions) -> void:
	var root := Node3D.new()
	root.name = "InsideStartProbe_%s" % profile_id
	tree.root.add_child(root)

	var origin := XROrigin3D.new()
	root.add_child(origin)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	var tracking: FakeTrackingProvider = FakeTrackingProvider.new()
	root.add_child(tracking)

	var target: Node = InsideRobotTargetScript.new()
	var faults: Array[String] = []
	var warnings: Array[String] = []
	var telemetry: Array[Dictionary] = []
	target.faulted.connect(func(code: String, message: String) -> void:
		faults.append("%s: %s" % [code, message])
	)
	target.warning_raised.connect(func(code: String, message: String) -> void:
		warnings.append("%s: %s" % [code, message])
	)
	target.telemetry_received.connect(func(data: Dictionary) -> void:
		telemetry.append(data.duplicate(true))
	)
	target.configure_runtime(root, origin, camera, tracking)
	root.add_child(target)

	# Native is what a headset runs with no host attached; remote needs a
	# service and is covered by teleop.remote.
	var backend := (
		"native" if RobotProfileRegistry.supports_backend(profile_id, "native") else "remote"
	)
	target.start({"inside_profile": profile_id, "retargeting_backend": backend})

	t.is_true(
		faults.is_empty(), "%s starts without fault (%s)" % [profile_id, ", ".join(faults)]
	)
	t.eq(
		str(target.profile.get("profile_id", "")),
		profile_id,
		"%s resolved its profile from the settings key" % profile_id
	)
	if backend == "native":
		t.is_true(target.is_ready(), "%s reaches READY on native retargeting" % profile_id)

	if profile_id == "so101" and backend == "native":
		# Drive the same end-to-end path as Teleop: controller mapping, deadman
		# anchoring, native IK, and result application. A solver-only unit test
		# cannot catch an early return before the solver is called.
		tracking.set_controller_input(1, {"grip": 1.0, "trigger": 0.5})
		tracking.set_controller_pose(
			1,
			{
				"position": Vector3(0.2, 1.2, -0.4),
				"rotation": Quaternion.IDENTITY,
				"is_active": true,
			}
		)
		target.set_control_enabled(true)
		target._process(1.0)
		t.is_true(not telemetry.is_empty(), "SO101 native controller frame reaches IK")
		if not telemetry.is_empty():
			t.eq(
				(telemetry.back().get("q", []) as Array).size(),
				int(target.profile.get("expected_q_size", 0)),
				"SO101 native IK applies the full arm result"
			)

	# A timeout from a ready remote solver is recoverable. It must use the
	# warning channel instead of the terminal fault channel that opens Settings.
	var faults_before_warning := faults.size()
	var ready_remote := ReadyRemote.new()
	root.add_child(ready_remote)
	target.set("_remote", ready_remote)
	target.call("_on_remote_fault", "result_timeout", "temporary slowdown")
	t.eq(warnings.size(), 1, "recoverable remote timeout emits one warning")
	t.eq(faults.size(), faults_before_warning, "recoverable remote timeout is not terminal")
	t.is_true(target.is_ready(), "recoverable remote timeout keeps the target active")
	target.set("_remote", null)
	root.remove_child(ready_remote)
	ready_remote.free()

	# An embodiment must exist: either the robot overlay or the in-headset
	# simulation, depending on what the profile declares.
	var overlay: Node = target.get("_overlay")
	var simulation: Node = target.get("_simulation")
	var view: Node = target.get("_simulation_view")
	var has_embodiment := overlay != null or simulation != null
	t.is_true(has_embodiment, "%s created an in-headset embodiment" % profile_id)

	# Every Inside Robot scene shows the shared ground grid on the XR floor,
	# whatever renders the embodiment.
	t.is_true(
		target.get("_ground_grid") != null, "%s shows the ground grid" % profile_id
	)

	# A robot with no bespoke overlay must still render as itself: its bundle's
	# meshes, not the debug skeleton.
	var profile := RobotProfileRegistry.get_profile(profile_id)
	var visual_model := str(profile.get("visual_model", ""))
	var matched := -1
	if overlay == null and not visual_model.is_empty():
		if t.is_true(view != null, "%s created a visual view" % profile_id):
			t.is_true(
				view.has_method("matched_link_count"),
				"%s renders its mesh rather than the fallback skeleton" % profile_id
			)
			if view.has_method("matched_link_count"):
				matched = int(view.call("matched_link_count"))
				t.is_true(
					matched >= 3, "%s bound %d mesh links to simulation bodies" % [profile_id, matched]
				)
			# Bound names alone would still be an empty scene; the robot has to
			# carry actual geometry for the operator to see anything.
			var meshes := _count_meshes(view)
			t.is_true(meshes > 0, "%s mesh view holds %d drawable meshes" % [profile_id, meshes])
	# The ground-reference grid must exist for this robot too and sit at its
	# base, so the operator can read the robot's height.
	var grid: Node = target.get("_ground_grid")
	if t.is_true(grid != null, "%s has a ground grid" % profile_id):
		var robot_visual: Node3D = overlay if overlay != null else view
		if robot_visual != null and grid.has_method("place_under_robot"):
			t.is_true(grid.call("place_under_robot"), "%s grid places under the robot" % profile_id)
			var box: AABB = GroundGridScript.world_aabb(robot_visual)
			t.almost_eq(
				(grid as Node3D).global_position.y,
				box.position.y,
				0.02,
				"%s grid sits at the robot's base" % profile_id
			)

	t.log_line(
		"%s: backend=%s overlay=%s simulation=%s mesh_links=%d"
		% [profile_id, backend, str(overlay != null), str(simulation != null), matched]
	)

	# Stopping is the path that crashed the renderer: it must release every
	# runtime node and leave nothing rendering behind the settings page. This
	# is what happens each time the operator opens the config page, switches
	# robot, or leaves Teleop.
	target.stop()
	t.is_true(target.is_stopped(), "%s reports stopped" % profile_id)
	t.is_true(target.get("_overlay") == null, "%s released its overlay" % profile_id)
	t.is_true(target.get("_simulation") == null, "%s released its simulation" % profile_id)
	t.is_true(target.get("_simulation_view") == null, "%s released its view" % profile_id)
	t.is_true(
		target.get("_ground_grid") == null, "%s released its ground grid" % profile_id
	)
	# Detached, not yet destroyed: queue_free() runs at the end of the frame,
	# but removing the node from the tree is what stops it drawing. Counting
	# meshes still parented to the probe root is therefore the real check.
	var still_rendering := _count_meshes(root)
	t.eq(still_rendering, 0, "%s leaves nothing rendering after stop" % profile_id)

	# Restarting the same target is the "close the page without confirming"
	# path, and previously ran straight into the freed-node crash. Enabling VR
	# Pose here also covers SO101: the display-only skeleton must create body
	# tracking even though arm retargeting itself does not require it.
	target.start(
		{
			"inside_profile": profile_id,
			"retargeting_backend": backend,
			"show_vr_pose": true,
		}
	)
	t.is_false(target.is_stopped(), "%s restarts after being stopped" % profile_id)
	t.is_true(
		target.get("_body_provider") != null,
		"%s Show VR Pose creates a canonical body provider" % profile_id
	)
	t.is_true(
		target.get("_vr_pose_overlay") != null,
		"%s Show VR Pose creates the shared skeleton" % profile_id
	)
	target.stop()

	root.queue_free()


## Drawable meshes below a node, ignoring empty placeholders. Bound link names
## alone would still leave the operator looking at nothing.
func _count_meshes(node: Node) -> int:
	var total := 0
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		if instance.mesh != null and instance.get_aabb().size.length() > 0.0001:
			total += 1
	for child in node.get_children():
		total += _count_meshes(child)
	return total
