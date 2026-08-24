extends "res://scripts/teleop/teleop_target.gd"
## Owns an in-headset embodiment. Native mode runs the bundled retargeting
## library; remote mode sends tracking frames to retargeting-service and always
## applies the returned state to a simulation/rendering pipeline in the headset.

const BodyPoseProviderScript := preload("res://scripts/robot_constraint/body_pose_provider.gd")
const BodyPoseDebugOverlayScript := preload(
	"res://scripts/robot_constraint/body_pose_debug_overlay.gd"
)
const GroundGridViewScript := preload("res://scripts/teleop/simulation/ground_grid_view.gd")
const MjSimulationScript := preload("res://addons/godot_mujoco/mj_simulation.gd")
const MujocoMeshViewScript := preload("res://scripts/teleop/simulation/mujoco_mesh_view.gd")
const MujocoSkeletonViewScript := preload("res://scripts/teleop/simulation/mujoco_skeleton_view.gd")
const RemoteRetargeterScript := preload("res://scripts/teleop/retargeting/remote_retargeter.gd")
const RobotProfileRegistryScript := preload(
	"res://scripts/teleop/retargeting/robot_profile_registry.gd"
)
const So101NativeRetargeterScript := preload(
	"res://scripts/teleop/retargeting/so101_native_retargeter.gd"
)

var runtime_root: Node
var xr_origin: XROrigin3D
var head_camera: XRCamera3D
var tracking_provider: TrackingProvider

var profile: Dictionary = {}
var backend := "native"
var show_vr_pose := false
var _body_provider: Node
var _vr_pose_overlay: Node3D
var _overlay: Node3D
var _remote: Node
var _simulation: Node
var _simulation_view: Node3D
var _ground_grid: MeshInstance3D
var _control_mode: ControlMode
var _so101_native: RefCounted
var _sample_accumulator := 0.0
var _deadman_was_enabled := false
var _controller_reference_position := Vector3.ZERO
var _controller_reference_rotation := Quaternion.IDENTITY
var _last_gripper := 0.0
var _started_pico_body := false


func _init() -> void:
	target_kind = "inside"


func configure_runtime(
	root: Node, origin: XROrigin3D, camera: XRCamera3D, tracking: TrackingProvider
) -> void:
	runtime_root = root
	xr_origin = origin
	head_camera = camera
	tracking_provider = tracking


func start(config: Dictionary) -> void:
	stop()
	# The settings page names this `inside_profile`; `profile_id` is accepted so
	# a caller holding a profile dictionary can start a target directly.
	var profile_id := str(config.get("inside_profile", config.get("profile_id", "")))
	profile = RobotProfileRegistryScript.get_profile(profile_id)
	backend = str(config.get("retargeting_backend", "native"))
	show_vr_pose = bool(config.get("show_vr_pose", false))
	if profile.is_empty():
		_fail("unknown_profile", "Unknown Inside Robot profile")
		return
	if not RobotProfileRegistryScript.supports_backend(str(profile.get("profile_id")), backend):
		_fail(
			"backend_unavailable",
			"%s does not support %s retargeting" % [profile.get("display_name", "Robot"), backend]
		)
		return
	if runtime_root == null or head_camera == null or tracking_provider == null:
		_fail("runtime_missing", "Inside Robot XR runtime is not configured")
		return
	_set_state(State.STARTING, "starting Inside Robot")
	descriptor = _inside_descriptor()

	if bool(profile.get("requires_body_tracking", false)) or show_vr_pose:
		_create_body_provider()
	_create_local_embodiment()
	if state == State.FAULTED:
		return

	if backend == "native":
		_start_native()
	else:
		_start_remote(config)


func _process(delta: float) -> void:
	if not is_ready() or not control_enabled:
		return
	if str(profile.get("profile_id", "")) != "so101":
		return
	_sample_accumulator += delta
	if _sample_accumulator < 1.0 / 60.0:
		return
	_sample_accumulator = 0.0
	_submit_so101_frame()


func set_control_enabled(enabled: bool) -> void:
	super.set_control_enabled(enabled)
	if not enabled:
		_deadman_was_enabled = false


func reset() -> void:
	_deadman_was_enabled = false
	if _remote != null:
		_remote.reset()
	if _so101_native != null:
		_so101_native.reset()
	if _simulation != null:
		_simulation.reset()


func get_control_mode():
	return _control_mode


func stop() -> void:
	control_enabled = false
	set_process(false)
	if _body_provider != null:
		_body_provider.set_enabled(false)
	if _remote != null:
		_remote.stop()
		_dispose_runtime_node(_remote)
		_remote = null
	if _vr_pose_overlay != null:
		_dispose_runtime_node(_vr_pose_overlay)
		_vr_pose_overlay = null
	if _overlay != null:
		_dispose_runtime_node(_overlay)
		_overlay = null
	if _body_provider != null:
		_dispose_runtime_node(_body_provider)
		_body_provider = null
	if _simulation_view != null:
		_dispose_runtime_node(_simulation_view)
		_simulation_view = null
	if _ground_grid != null:
		_dispose_runtime_node(_ground_grid)
		_ground_grid = null
	if _simulation != null:
		_simulation.pause()
		_dispose_runtime_node(_simulation)
		_simulation = null
	if _started_pico_body:
		var bridge := _pico_bridge()
		if bridge != null and bridge.has_method("stop_body_tracking"):
			bridge.call("stop_body_tracking")
		_started_pico_body = false
	_control_mode = null
	_so101_native = null
	profile.clear()
	descriptor.clear()
	_deadman_was_enabled = false
	_set_state(State.IDLE, "stopped")


## Detach now, destroy at the end of the frame. Freeing outright killed the
## render thread (SIGSEGV in VkThread): stopping a robot destroys meshes the
## renderer is still holding for the frame in flight, which is why switching
## robots or leaving Teleop could take the app down. Removing the node from the
## tree stops it rendering immediately, so the deferred free costs nothing
## visible.
func _dispose_runtime_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.queue_free()


func _create_body_provider() -> void:
	var bridge := _pico_bridge()
	var requires_body := bool(profile.get("requires_body_tracking", false))
	if bridge != null and bridge.has_method("start_body_tracking"):
		_started_pico_body = bool(bridge.call("start_body_tracking", {}))
	_body_provider = BodyPoseProviderScript.new()
	_body_provider.name = "InsideRobotBodyPoseProvider"
	_body_provider.configure(tracking_provider, bridge)
	_body_provider.allow_fallback = not requires_body
	if requires_body:
		_body_provider.source_mode = (
			BodyPoseProviderScript.SourceMode.PICO_ONLY
			if bridge != null and bridge.has_method("sample_body_joints")
			else BodyPoseProviderScript.SourceMode.GODOT_ONLY
		)
		_body_provider.tracking_unavailable.connect(_on_body_tracking_unavailable)
	else:
		_body_provider.source_mode = BodyPoseProviderScript.SourceMode.AUTO
	_body_provider.sample_rate_hz = 60.0
	runtime_root.add_child(_body_provider)
	_body_provider.set_enabled(true)


func _on_body_tracking_unavailable(source: String, _reason: String) -> void:
	if source != "pico" or state == State.IDLE or state == State.FAULTED:
		return
	var message := tr("UI_PICO_BODY_TRACKING_UNAVAILABLE")
	stop()
	_fail("pico_body_tracking_unavailable", message)


func _create_local_embodiment() -> void:
	var overlay_path := str(profile.get("overlay_script", ""))
	if not overlay_path.is_empty():
		# A script that fails to parse still loads as an un-instantiable
		# resource. Without this check the target reported READY while nothing
		# was ever rendered, which is how a broken overlay stayed invisible.
		var script: Script = load(overlay_path)
		if script == null or not script.can_instantiate():
			_fail("overlay_unusable", "Inside Robot overlay cannot load: %s" % overlay_path)
			return
		var instance: Variant = script.new()
		if instance == null or not (instance is Node3D):
			_fail("overlay_unusable", "Inside Robot overlay is not a Node3D: %s" % overlay_path)
			return
		_overlay = instance
		_overlay.name = "InsideRobot_%s" % str(profile.get("profile_id", "robot"))
		if "native_retargeting_enabled" in _overlay:
			_overlay.set("native_retargeting_enabled", backend == "native")
		if "debug_place_in_front_of_view" in _overlay:
			_overlay.set("debug_place_in_front_of_view", true)
		# Overlay debug decorations are authoring aids, not product visuals: the
		# cyan VR-pose markers only clutter the scene for an operator, and the
		# target draws a shared ground grid for every robot, so the overlay's
		# own grid would just double the lines. Both stay available when an
		# overlay is run on its own.
		if "show_ground_grid" in _overlay:
			_overlay.set("show_ground_grid", false)
		# Per-robot pose markers are authoring diagnostics with inconsistent
		# coverage. Teleop uses the shared BodyPoseDebugOverlay below so all
		# four robots get the same full skeleton in the same location.
		if "debug_show_vr_pose" in _overlay:
			_overlay.set("debug_show_vr_pose", false)
		if _overlay.has_method("set_head_camera"):
			_overlay.call("set_head_camera", head_camera)
		runtime_root.add_child(_overlay)
		if _overlay.has_signal("qpos_updated"):
			_overlay.connect("qpos_updated", Callable(self, "_on_overlay_qpos_updated"))

	# An overlay renders the robot itself, so it needs no simulation view — the
	# skeleton spheres would just be drawn on top of the real model. Only robots
	# without an overlay get a view built from the MuJoCo simulation.
	if _overlay == null and str(profile.get("simulation_backend", "")).begins_with("mujoco"):
		_simulation = MjSimulationScript.new()
		_simulation.name = "InsideRobotSimulation"
		_simulation.model_path = str(profile.get("simulation_model", ""))
		_simulation.fixed_timestep = 1.0 / 120.0
		_simulation.auto_start = str(profile.get("simulation_backend", "")) == "mujoco"
		runtime_root.add_child(_simulation)
		# Show the robot's real mesh when its bundle ships one; the skeleton is
		# the fallback so a missing or mismatched visual model degrades to
		# something rather than nothing.
		var visual_model := str(profile.get("visual_model", ""))
		if not visual_model.is_empty():
			var mesh_view: Node3D = MujocoMeshViewScript.new()
			mesh_view.name = "InsideRobotMeshView"
			runtime_root.add_child(mesh_view)
			if bool(mesh_view.call("configure", _simulation, head_camera, visual_model)):
				_simulation_view = mesh_view
			else:
				_dispose_runtime_node(mesh_view)
		if _simulation_view == null:
			_simulation_view = MujocoSkeletonViewScript.new()
			_simulation_view.name = "InsideRobotSimulationView"
			runtime_root.add_child(_simulation_view)
			_simulation_view.call("configure", _simulation, head_camera)

	# Every Inside Robot scene gets the same ground grid at the base of the
	# robot — a height reference, whatever renders the embodiment.
	var robot_visual: Node3D = _overlay if _overlay != null else _simulation_view
	if robot_visual != null:
		_ground_grid = GroundGridViewScript.new()
		_ground_grid.name = "InsideRobotGroundGrid"
		runtime_root.add_child(_ground_grid)
		_ground_grid.call("configure", robot_visual)
		if show_vr_pose and _body_provider != null:
			_create_vr_pose_overlay(robot_visual)


func _create_vr_pose_overlay(robot_visual: Node3D) -> void:
	_vr_pose_overlay = BodyPoseDebugOverlayScript.new()
	_vr_pose_overlay.name = "InsideRobotVRPose"
	_vr_pose_overlay.set("follow_head_camera", false)
	_vr_pose_overlay.call("set_head_camera", head_camera)
	_vr_pose_overlay.call("set_reference_visual", robot_visual)
	runtime_root.add_child(_vr_pose_overlay)
	_vr_pose_overlay.call("configure", _body_provider)


func _start_native() -> void:
	if str(profile.get("profile_id", "")) == "so101":
		_control_mode = ControlMode.new()
		_control_mode.configure(profile.get("local_control_descriptor", {}))
		_so101_native = So101NativeRetargeterScript.new()
	if _overlay != null:
		if not _overlay.has_method("is_native_retargeting_ready"):
			_fail(
				"native_retargeting_contract_missing",
				"%s overlay cannot report native retargeting readiness"
				% profile.get("display_name", "Robot")
			)
			return
		if not bool(_overlay.call("is_native_retargeting_ready")):
			var detail := "native retargeting failed to initialize"
			if _overlay.has_method("get_native_retargeting_error"):
				detail = str(_overlay.call("get_native_retargeting_error"))
			_fail("native_retargeting_unavailable", detail)
			return
		if _body_provider == null or not _overlay.has_method("set_body_pose_provider"):
			_fail(
				"body_tracking_unavailable",
				"%s native retargeting requires a body-pose provider"
				% profile.get("display_name", "Robot")
			)
			return
		_overlay.call("set_body_pose_provider", _body_provider)
	_set_state(State.READY, "native retargeting ready")
	set_process(true)
	target_ready.emit(descriptor)


func _start_remote(config: Dictionary) -> void:
	_remote = RemoteRetargeterScript.new()
	_remote.name = "RemoteRetargeter"
	_remote.service_ready.connect(_on_remote_ready)
	_remote.result_received.connect(_on_remote_result)
	_remote.state_changed.connect(_on_remote_state_changed)
	_remote.faulted.connect(_on_remote_fault)
	runtime_root.add_child(_remote)
	if _body_provider != null:
		_body_provider.canonical_frame_ready.connect(_on_canonical_frame)
	if str(profile.get("profile_id", "")) == "so101":
		_control_mode = ControlMode.new()
		_control_mode.configure(profile.get("local_control_descriptor", {}))
	var err := int(
		(
			_remote
			. call(
				"start",
				{
					"host": str(config.get("retargeting_host", "")),
					"port": int(config.get("retargeting_port", 8000)),
					"tls": bool(config.get("retargeting_tls", false)),
					"profile": profile,
				}
			)
		)
	)
	if err != OK:
		_fail("remote_start_failed", "Could not start Remote Retargeting")


func _on_remote_ready(_service_profile: Dictionary) -> void:
	_set_state(State.READY, "remote retargeting ready")
	set_process(true)
	target_ready.emit(descriptor)


func _on_remote_state_changed(_remote_state: String, detail: String) -> void:
	if state == State.STARTING:
		state_changed.emit(state, detail)


func _on_remote_fault(code: String, message: String) -> void:
	# A single solve timeout/degradation is observable but does not destroy the
	# local simulation. Transport/protocol failures are terminal.
	if _remote != null and _remote.is_ready():
		warning_raised.emit(code, message)
		return
	_fail(code, message)


func _on_canonical_frame(frame: Dictionary) -> void:
	if _remote == null or not _remote.is_ready() or not control_enabled:
		return
	_remote.submit_payload(
		{"frame": frame}, int(frame.get("timestamp_ns", Time.get_ticks_usec() * 1000))
	)


func _submit_so101_frame() -> void:
	if _control_mode == null:
		return
	# Native owns an in-process solver and deliberately has no RemoteRetargeter.
	# Only the remote backend requires a ready socket before sampling controls.
	if backend == "remote" and (_remote == null or not _remote.is_ready()):
		return
	var command := _control_mode.collect_command(tracking_provider)
	var enabled := bool(command.get("buttons", {}).get("enable", false))
	var pose: Dictionary = command.get("poses", {}).get("end_effector", {})
	if not enabled or pose.is_empty():
		_deadman_was_enabled = false
		return
	var position_values: Array = pose.get("position", [])
	var rotation_values: Array = pose.get("rotation", [])
	if position_values.size() != 3 or rotation_values.size() != 4:
		return
	var current_position := Vector3(
		float(position_values[0]), float(position_values[1]), float(position_values[2])
	)
	var current_rotation := (
		Quaternion(
			float(rotation_values[0]),
			float(rotation_values[1]),
			float(rotation_values[2]),
			float(rotation_values[3])
		)
		. normalized()
	)
	if not _deadman_was_enabled:
		_controller_reference_position = current_position
		_controller_reference_rotation = current_rotation
		_deadman_was_enabled = true
	var home_position_values: Array = profile.get("home_ee_position", [0.0, 0.0, 0.0])
	var home_position := Vector3(
		float(home_position_values[0]),
		float(home_position_values[1]),
		float(home_position_values[2])
	)
	var delta := current_position - _controller_reference_position
	var scale := float(profile.get("position_scale", 1.0))
	var target_position := home_position + _xr_vector_to_robot(delta) * scale

	var relative_xr := current_rotation * _controller_reference_rotation.inverse()
	var relative_robot := _xr_rotation_to_robot(relative_xr)
	var home_q_values: Array = profile.get("home_ee_orientation_wxyz", [1.0, 0.0, 0.0, 0.0])
	var home_rotation := (
		Quaternion(
			float(home_q_values[1]),
			float(home_q_values[2]),
			float(home_q_values[3]),
			float(home_q_values[0])
		)
		. normalized()
	)
	var target_rotation := (relative_robot * home_rotation).normalized()
	_last_gripper = clampf(float(command.get("axes", {}).get("gripper", 0.0)), 0.0, 1.0)
	if backend == "native" and _so101_native != null:
		_apply_retarget_result(_so101_native.solve(target_position, target_rotation))
	elif _remote != null:
		(
			_remote
			. submit_payload(
				{
					"position": [target_position.x, target_position.y, target_position.z],
					"orientation_wxyz":
					[target_rotation.w, target_rotation.x, target_rotation.y, target_rotation.z],
				},
				int(command.get("timestamp_ns", Time.get_ticks_usec() * 1000))
			)
		)


func _on_remote_result(result: Dictionary) -> void:
	_apply_retarget_result(result)


func _on_overlay_qpos_updated(qpos: PackedFloat64Array) -> void:
	if _simulation != null:
		_simulation.set_configuration(qpos)


func _apply_retarget_result(result: Dictionary) -> void:
	var q_values: Array = result.get("q", [])
	if q_values.is_empty():
		return
	if _overlay != null and _overlay.has_method("apply_remote_qpos"):
		var qpos := PackedFloat64Array()
		for value in q_values:
			qpos.append(float(value))
		_overlay.call("apply_remote_qpos", qpos)
	if _simulation != null and _overlay == null:
		var joint_names: Array = result.get("joint_names", profile.get("joint_names", []))
		for i in range(mini(joint_names.size(), q_values.size())):
			_simulation.set_actuator_control(str(joint_names[i]), float(q_values[i]))
		_simulation.set_actuator_control("gripper", lerpf(-0.174533, 1.745329, _last_gripper))
	(
		telemetry_received
		. emit(
			{
				"retargeting":
				{
					"status": result.get("status", ""),
					"metrics": result.get("metrics", {}),
					"degradation": result.get("degradation", {}),
				},
				"q": q_values,
			}
		)
	)


func _inside_descriptor() -> Dictionary:
	var local_control: Dictionary = profile.get("local_control_descriptor", {})
	return {
		"descriptor_version": 2,
		"execution": {"kind": "inside", "environment": "simulation"},
		"device":
		{
			"type": "inside_robot",
			"name": profile.get("display_name", "Inside Robot"),
			"profile_id": profile.get("profile_id", ""),
		},
		"input_contract":
		{
			"rate_hz": 60,
			"coordinate_space": "operator_xr_world",
			"channels":
			[
				{
					"name": "operator_input",
					"type": profile.get("input_type", ""),
				},
			],
		},
		"retargeting": {"backend": backend},
		"simulation": {"backend": profile.get("simulation_backend", "kinematic")},
		"control_schema": local_control.get("control_schema", {}),
		"input_mapping": local_control.get("input_mapping", []),
		"capabilities":
		{
			"teleop": true,
			"simulation": true,
			"remote_retargeting": backend == "remote",
		},
	}


func _pico_bridge() -> Object:
	if get_tree() == null:
		return null
	var autoload := get_tree().root.get_node_or_null("PicoOpenXRBridge")
	if autoload != null and autoload.has_method("get_bridge"):
		return autoload.call("get_bridge")
	return null


func _xr_vector_to_robot(value: Vector3) -> Vector3:
	# OpenXR: +X right, +Y up, -Z forward. Robot convention: +X forward,
	# +Y left, +Z up.
	return Vector3(-value.z, -value.x, value.y)


func _xr_rotation_to_robot(value: Quaternion) -> Quaternion:
	var xr_basis := Basis(value)
	var x := _xr_vector_to_robot(xr_basis.x)
	var y := _xr_vector_to_robot(xr_basis.y)
	var z := _xr_vector_to_robot(xr_basis.z)
	# Change of basis M * R * M^-1. The columns above are M*R; transform the
	# canonical robot axes back through M^-1 by reordering them explicitly.
	var mapped := Basis(x, y, z)
	var map_basis := Basis(
		_xr_vector_to_robot(Vector3.RIGHT),
		_xr_vector_to_robot(Vector3.UP),
		_xr_vector_to_robot(Vector3.BACK)
	)
	return Quaternion(mapped * map_basis.inverse()).normalized()
