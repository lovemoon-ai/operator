extends Node3D

const MjSimulationScript := preload("res://addons/godot_mujoco/mj_simulation.gd")
const MjBodyTrackerScript := preload("res://addons/godot_mujoco/mj_body_tracker.gd")
const MjTeleopRigScript := preload("res://addons/godot_mujoco/mj_teleop_rig.gd")
const MjLeRobotRecorderScript := preload("res://addons/godot_mujoco/mj_lerobot_recorder.gd")
const MjProfilerScript := preload("res://addons/godot_mujoco/mj_profiler.gd")
const MjHapticsBridgeScript := preload("res://addons/godot_mujoco/mj_haptics_bridge.gd")

const DEFAULT_DURATION_SECONDS := 20.0
const DEFAULT_MIN_FRAMES := 120
const DATASET_ROOT := "/sdcard/Android/data/com.lovemoon.operator/files/mujoco_lerobot"
const FALLING_BOX_BODY := "falling_box"
const RAMP_BALL_BODY := "ramp_ball"
const PHYSICS_SAMPLE_INTERVAL := 0.25

@onready var _origin: XROrigin3D = $XROrigin3D
@onready var _left_controller: XRController3D = $XROrigin3D/LeftController
@onready var _right_controller: XRController3D = $XROrigin3D/RightController
@onready var _camera: XRCamera3D = $XROrigin3D/XRCamera3D

var _simulation: MjSimulation
var _teleop: MjTeleopRig
var _recorder: MjLeRobotRecorder
var _profiler: MjProfiler
var _scenario: MjScenario
var _label: Label3D
var _duration := DEFAULT_DURATION_SECONDS
var _min_frames := DEFAULT_MIN_FRAMES
var _elapsed := 0.0
var _started := false
var _failed := false
var _physics_initial := {}
var _physics_latest := {}
var _physics_min_contact_count := 0
var _physics_max_contact_count := 0
var _physics_sample_accumulator := 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_duration = _arg_float("--mujoco-duration", DEFAULT_DURATION_SECONDS)
	_min_frames = int(_arg_float("--mujoco-min-frames", DEFAULT_MIN_FRAMES))
	_configure_world()
	_build_runtime()
	var reset_result := MjResetPolicy.apply(_simulation, _scenario)
	_capture_initial_physics_state()
	_started = _recorder.start_episode({
		"device_test": true,
		"duration_seconds": _duration,
		"physics_scene": _physics_scene_metadata(),
		"physics_initial": _physics_initial,
		"native_status": _simulation.get_native_status(),
		"device_capability": MjDeviceCapabilityProfile.collect(),
		"scenario": _scenario.instantiate_metadata(),
		"reset": reset_result,
	})
	print("[GodotMuJoCoTest] started duration=%.2f min_frames=%d" % [_duration, _min_frames])


func _process(delta: float) -> void:
	if _failed:
		return
	_elapsed += delta
	_sample_physics(delta)
	_update_label()
	if _started and _elapsed >= _duration:
		_finish()


func _build_runtime() -> void:
	_simulation = MjSimulationScript.new()
	_simulation.name = "MjSimulation"
	_scenario = MjScenario.new()
	_scenario.seed = 42
	_simulation.model_path = _scenario.model_path
	_simulation.fixed_timestep = 1.0 / 120.0
	_simulation.auto_start = true
	_simulation.require_native_backend = true
	add_child(_simulation)
	if not _simulation.is_native_backend_loaded():
		_failed = true
		push_error("[GodotMuJoCoTest] Native MuJoCo backend is required for device E2E")
		get_tree().quit(2)
		return

	_teleop = MjTeleopRigScript.new()
	_teleop.name = "MjTeleopRig"
	_teleop.simulation_path = NodePath("../MjSimulation")
	_teleop.left_controller_path = NodePath("../XROrigin3D/LeftController")
	_teleop.right_controller_path = NodePath("../XROrigin3D/RightController")
	add_child(_teleop)

	var haptics := MjHapticsBridgeScript.new()
	haptics.name = "MjHapticsBridge"
	haptics.simulation_path = NodePath("../MjSimulation")
	haptics.controller_path = NodePath("../XROrigin3D/RightController")
	add_child(haptics)

	_recorder = MjLeRobotRecorderScript.new()
	_recorder.name = "MjLeRobotRecorder"
	_recorder.simulation_path = NodePath("../MjSimulation")
	_recorder.teleop_path = NodePath("../MjTeleopRig")
	_recorder.dataset_root = DATASET_ROOT
	add_child(_recorder)

	_profiler = MjProfilerScript.new()
	_profiler.name = "MjProfiler"
	_profiler.simulation_path = NodePath("../MjSimulation")
	_profiler.sample_interval = 1.0
	add_child(_profiler)

	for i in range(min(18, _simulation.model.body_names.size())):
		var tracker := MjBodyTrackerScript.new()
		tracker.name = "Body_%02d_%s" % [i, _simulation.model.body_names[i]]
		tracker.body_name = _simulation.model.body_names[i]
		tracker.simulation_path = NodePath("../../MjSimulation")
		_origin.add_child(tracker)

	_add_visual_body("falling_box_visual", FALLING_BOX_BODY, Color(0.1, 0.85, 0.25, 1.0), "box")
	_add_visual_body("ramp_ball_visual", RAMP_BALL_BODY, Color(0.95, 0.75, 0.10, 1.0), "sphere")
	_add_visual_body("red_cube_visual", "red_cube", Color(0.9, 0.05, 0.05, 1.0), "box")


func _finish() -> void:
	var summary := _recorder.stop_episode()
	var validation := MjDatasetValidator.validate_episode(_recorder.episode_dir, _min_frames, true)
	var replay := _recorder.replay_episode("", _min_frames)
	var native_status := _simulation.get_native_status()
	var profiler_summary := _profiler.summary() if _profiler else {}
	var physics_validation := _validate_physics_scene()
	var ok := bool(validation.get("ok", false)) and bool(replay.get("ok", false)) and bool(physics_validation.get("ok", false)) and int(validation.get("frames", 0)) >= _min_frames and _simulation.step_index > _min_frames and bool(native_status.get("loaded", false))
	print("[GodotMuJoCoTest] summary=%s validation=%s replay=%s profiler=%s physics=%s sim_steps=%d" % [JSON.stringify(summary), JSON.stringify(validation), JSON.stringify(replay), JSON.stringify(profiler_summary), JSON.stringify(physics_validation), _simulation.step_index])
	if ok:
		print("[GodotMuJoCoTest] PHYSICS_PASS %s" % JSON.stringify(physics_validation))
		print("[GodotMuJoCoTest] PASS episode_dir=%s frames=%d steps=%d" % [summary.get("episode_dir", ""), int(validation.get("frames", 0)), _simulation.step_index])
		get_tree().quit(0)
	else:
		_failed = true
		push_error("[GodotMuJoCoTest] FAIL validation=%s physics=%s steps=%d" % [JSON.stringify(validation), JSON.stringify(physics_validation), _simulation.step_index])
		get_tree().quit(2)


func _configure_world() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.use_xr = true
		viewport.transparent_bg = false
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.015, 0.018, 0.025, 1.0)
	add_child(world)
	var light := DirectionalLight3D.new()
	light.light_energy = 1.5
	light.rotation_degrees = Vector3(-50.0, 20.0, 0.0)
	add_child(light)
	_label = Label3D.new()
	_label.name = "Status"
	_label.font_size = 36
	_label.outline_size = 8
	_origin.add_child(_label)


func _add_visual_body(node_name: String, body_name: String, color: Color, shape: String) -> void:
	var tracker := MjBodyTrackerScript.new()
	tracker.name = node_name
	tracker.body_name = body_name
	tracker.simulation_path = NodePath("../../MjSimulation")
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh_instance.material_override = material
	if shape == "sphere":
		var sphere := SphereMesh.new()
		sphere.radius = 0.035
		sphere.height = 0.07
		mesh_instance.mesh = sphere
	else:
		var box := BoxMesh.new()
		box.size = Vector3(0.08, 0.08, 0.08)
		mesh_instance.mesh = box
	tracker.add_child(mesh_instance)
	_origin.add_child(tracker)


func _update_label() -> void:
	if _label == null:
		return
	var box_drop := _physics_delta(FALLING_BOX_BODY, "z")
	var ball_roll := _physics_delta(RAMP_BALL_BODY, "x")
	_label.text = "MuJoCo physics %.1fs\nsteps %d frames %d\nbox dz %.2f ball dx %.2f contacts %d" % [_elapsed, _simulation.step_index if _simulation else 0, _recorder.frame_count if _recorder else 0, box_drop, ball_roll, _physics_max_contact_count]
	if _camera:
		_label.global_transform = _camera.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, -0.08, -1.3))


func _physics_scene_metadata() -> Dictionary:
	return {
		"description": "MuJoCo computes gravity, free-body collision, ramp rolling, and contact counts for dynamic props.",
		"dynamic_bodies": [FALLING_BOX_BODY, RAMP_BALL_BODY, "red_cube"],
		"static_geoms": ["floor", "inclined_ramp", "stop_block"],
		"assertions": ["falling_box_drops_and_settles", "ramp_ball_rolls_on_slope", "native_contacts_observed"],
	}


func _capture_initial_physics_state() -> void:
	_physics_initial = _physics_snapshot()
	_physics_latest = _physics_initial.duplicate(true)
	var contact_count := _current_contact_count()
	_physics_min_contact_count = contact_count
	_physics_max_contact_count = contact_count
	print("[GodotMuJoCoTest] physics_initial=%s" % JSON.stringify(_physics_initial))


func _sample_physics(delta: float) -> void:
	if _simulation == null:
		return
	_physics_sample_accumulator += delta
	if _physics_sample_accumulator < PHYSICS_SAMPLE_INTERVAL:
		return
	_physics_sample_accumulator = 0.0
	_physics_latest = _physics_snapshot()
	var contact_count := _current_contact_count()
	_physics_min_contact_count = mini(_physics_min_contact_count, contact_count)
	_physics_max_contact_count = maxi(_physics_max_contact_count, contact_count)
	if int(_simulation.step_index) % 240 == 0:
		print("[GodotMuJoCoTest] physics_sample=%s contacts=%d" % [JSON.stringify(_physics_latest), contact_count])


func _physics_snapshot() -> Dictionary:
	return {
		FALLING_BOX_BODY: _body_position_dict(FALLING_BOX_BODY),
		RAMP_BALL_BODY: _body_position_dict(RAMP_BALL_BODY),
		"red_cube": _body_position_dict("red_cube"),
		"contact_count": _current_contact_count(),
		"sim_step": _simulation.step_index if _simulation else 0,
	}


func _body_position_dict(body_name: String) -> Dictionary:
	if _simulation == null:
		return {}
	var transform := _simulation.get_body_transform(body_name)
	return {"x": transform.origin.x, "y": transform.origin.y, "z": transform.origin.z}


func _current_contact_count() -> int:
	if _simulation == null:
		return 0
	var observation := _simulation.get_observation()
	var contact = observation.get("contact", {})
	if contact is Dictionary:
		return int(contact.get("count", 0))
	if contact is Array:
		return contact.size()
	return 0


func _physics_delta(body_name: String, axis: String) -> float:
	if not _physics_initial.has(body_name) or not _physics_latest.has(body_name):
		return 0.0
	var initial: Dictionary = _physics_initial[body_name]
	var latest: Dictionary = _physics_latest[body_name]
	return float(latest.get(axis, 0.0)) - float(initial.get(axis, 0.0))


func _validate_physics_scene() -> Dictionary:
	_physics_latest = _physics_snapshot()
	var box_drop := _physics_delta(FALLING_BOX_BODY, "z")
	var box_final_z := float((_physics_latest.get(FALLING_BOX_BODY, {}) as Dictionary).get("z", 999.0))
	var ball_roll := _physics_delta(RAMP_BALL_BODY, "x")
	var ball_abs_roll := absf(ball_roll)
	var ball_final_z := float((_physics_latest.get(RAMP_BALL_BODY, {}) as Dictionary).get("z", 999.0))
	var checks := {
		"falling_box_dropped": box_drop < -0.45,
		"falling_box_above_floor": box_final_z > 0.025 and box_final_z < 0.12,
		"ramp_ball_rolled_on_slope": ball_abs_roll > 0.16,
		"ramp_ball_settled_near_floor": ball_final_z > 0.025 and ball_final_z < 0.14,
		"contacts_observed": _physics_max_contact_count > 0,
	}
	var failures := []
	for key in checks.keys():
		if not bool(checks[key]):
			failures.append(key)
	return {
		"ok": failures.is_empty(),
		"checks": checks,
		"failures": failures,
		"initial": _physics_initial,
		"latest": _physics_latest,
		"deltas": {"falling_box_z": box_drop, "ramp_ball_x": ball_roll, "ramp_ball_abs_x": ball_abs_roll},
		"max_contact_count": _physics_max_contact_count,
		"min_contact_count": _physics_min_contact_count,
	}


func _arg_float(name: String, fallback: float) -> float:
	var args := PackedStringArray()
	for arg in OS.get_cmdline_user_args():
		args.append(arg)
	for arg in OS.get_cmdline_args():
		args.append(arg)
	for i in range(args.size()):
		var arg := String(args[i])
		if arg == name and i + 1 < args.size():
			return float(args[i + 1])
		if arg.begins_with("%s=" % name):
			return float(arg.substr(name.length() + 1))
	var android_extra_name := name
	if android_extra_name.begins_with("--"):
		android_extra_name = android_extra_name.substr(2)
	android_extra_name = android_extra_name.replace("-", ".")
	for arg in args:
		var text := String(arg)
		if text.begins_with("%s=" % android_extra_name):
			return float(text.substr(android_extra_name.length() + 1))
	return fallback
