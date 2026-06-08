class_name MjSimulation
extends Node

signal model_loaded(summary: Dictionary)
signal simulation_started
signal simulation_paused
signal simulation_reset
signal stepped(snapshot: Dictionary)

@export_file("*.xml", "*.mjcf", "*.urdf") var model_path := "res://assets/mujoco/mobile_manipulator_smoke.xml"
@export var fixed_timestep := 1.0 / 120.0
@export var auto_start := true
@export var max_substeps_per_frame := 8
@export var use_native_backend := true
@export var require_native_backend := false

var model: MjModelResource
var running := false
var sim_time := 0.0
var step_index := 0
var controls := {}
var body_transforms := {}
var joint_positions := {}
var joint_velocities := {}
var actuator_states := {}
var contacts: Array[Dictionary] = []
var forces := {}
var _accumulator := 0.0
var _native_backend: Object = null
var _native_loaded := false
var _native_body_names: PackedStringArray = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	load_model(model_path)
	if auto_start:
		start()


func _physics_process(delta: float) -> void:
	if not running:
		return
	_accumulator += delta
	var substeps := 0
	while _accumulator >= fixed_timestep and substeps < max_substeps_per_frame:
		step(fixed_timestep)
		_accumulator -= fixed_timestep
		substeps += 1
	if substeps == max_substeps_per_frame:
		_accumulator = 0.0


func load_model(path: String) -> bool:
	model_path = path
	model = MjRobotImporter.import_model(path)
	if not model.is_valid_model():
		return false
	_native_loaded = false
	_native_body_names = []
	_native_backend = null
	if use_native_backend:
		_try_load_native_backend(path)
		if require_native_backend and not _native_loaded:
			return false
	_initialize_state()
	model_loaded.emit(model.duplicate_summary())
	print("[GodotMuJoCo] Model loaded %s backend=%s bodies=%d joints=%d actuators=%d" % [model.robot_name, get_backend_name(), model.body_names.size(), model.joint_names.size(), model.actuator_names.size()])
	return true


func start() -> void:
	running = true
	simulation_started.emit()


func pause() -> void:
	running = false
	simulation_paused.emit()


func reset(seed := 0) -> void:
	sim_time = 0.0
	step_index = 0
	_accumulator = 0.0
	if _native_loaded and _native_backend.has_method("reset"):
		_native_backend.reset()
	_initialize_state(seed)
	simulation_reset.emit()


func step(dt := -1.0) -> Dictionary:
	var step_dt := fixed_timestep if dt <= 0.0 else dt
	if _native_loaded and _native_backend.has_method("step"):
		_native_backend.step(step_dt)
		_sync_from_native()
	else:
		_step_fallback(step_dt)
	sim_time += step_dt
	step_index += 1
	var snapshot := get_snapshot()
	stepped.emit(snapshot)
	return snapshot


func set_actuator_control(name: String, value: float) -> void:
	controls[name] = clampf(value, -1.0, 1.0)
	if _native_loaded and _native_backend.has_method("set_actuator_control"):
		_native_backend.set_actuator_control(name, value)


func apply_action(action: Dictionary) -> void:
	var actuator_values: Dictionary = action.get("actuators", {})
	for key in actuator_values.keys():
		set_actuator_control(String(key), float(actuator_values[key]))
	if action.has("base"):
		controls["base_x"] = float(action["base"].get("x", 0.0))
		controls["base_yaw"] = float(action["base"].get("yaw", 0.0))
		_set_native_control_candidates(["base_x_position", "base_x"], controls["base_x"])
		_set_native_control_candidates(["base_yaw_position", "base_yaw"], controls["base_yaw"])
	if action.has("gripper"):
		controls["gripper"] = float(action["gripper"])
		_set_native_control_candidates(["gripper_position", "gripper_open", "gripper"], controls["gripper"] * 0.04)


func get_body_transform(body_name: String) -> Transform3D:
	return body_transforms.get(body_name, Transform3D.IDENTITY)


func get_backend_name() -> String:
	return "native_mujoco" if _native_loaded else "gdscript_fallback"


func is_native_backend_loaded() -> bool:
	return _native_loaded


func get_state_sample() -> Dictionary:
	if _native_loaded and _native_backend.has_method("get_state"):
		var native_state: Dictionary = _native_backend.get_state()
		native_state["backend"] = "native_mujoco"
		return native_state
	return {
		"backend": "gdscript_fallback",
		"step_index": step_index,
		"sim_time": sim_time,
		"joints": joint_positions.duplicate(true),
		"joint_velocities": joint_velocities.duplicate(true),
		"actuators": actuator_states.duplicate(true),
	}


func get_observation() -> Dictionary:
	var native_observation := {}
	if _native_loaded and _native_backend.has_method("get_observation"):
		native_observation = _native_backend.get_observation()
	return {
		"state": get_state_sample(),
		"rgb": {"status": "render_frame", "frame_index": Engine.get_frames_drawn()},
		"depth": {"status": "not_captured", "reason": "native_depth_pipeline_pending"},
		"segmentation": {"status": "proxy_ids", "ids": model.stable_ids if model else {}},
		"contact": native_observation.get("contact", contacts.duplicate(true)) if native_observation is Dictionary else contacts.duplicate(true),
		"force": native_observation.get("force", forces.duplicate(true)) if native_observation is Dictionary else forces.duplicate(true),
		"timestamp": Time.get_ticks_usec(),
	}


func get_native_status() -> Dictionary:
	if _native_loaded and _native_backend.has_method("get_status"):
		return _native_backend.get_status()
	return {"backend": "gdscript_fallback", "loaded": false}


func _set_native_control_candidates(names: Array, value: float) -> void:
	if not _native_loaded or not _native_backend.has_method("set_actuator_control"):
		return
	for name in names:
		_native_backend.set_actuator_control(String(name), value)


func get_snapshot() -> Dictionary:
	return {
		"step_index": step_index,
		"sim_time": sim_time,
		"body_transforms": _transforms_to_dict(),
		"state": get_state_sample(),
		"observation": get_observation(),
	}


func _initialize_state(seed := 0) -> void:
	body_transforms.clear()
	joint_positions.clear()
	joint_velocities.clear()
	actuator_states.clear()
	controls.clear()
	contacts.clear()
	forces.clear()
	if model == null:
		return
	if _native_loaded:
		var native_summary: Dictionary = _native_backend.get_model_summary() if _native_backend.has_method("get_model_summary") else {}
		_native_body_names = native_summary.get("body_names", PackedStringArray())
		if _native_body_names.size() > 0:
			model.body_names = _native_body_names
		if native_summary.has("joint_names"):
			model.joint_names = native_summary["joint_names"]
		if native_summary.has("actuator_names"):
			model.actuator_names = native_summary["actuator_names"]
		if native_summary.has("geom_names"):
			model.geom_names = native_summary["geom_names"]
		if native_summary.has("sensor_names"):
			model.sensor_names = native_summary["sensor_names"]
		if native_summary.has("stable_ids"):
			model.stable_ids = native_summary["stable_ids"]
	var body_count := max(1, model.body_names.size())
	for i in range(model.body_names.size()):
		var body_name := model.body_names[i]
		var x := float(i % 6) * 0.12 - 0.3
		var y := float(i / 6) * 0.12
		var z := 0.03 + float(i) / float(body_count) * 0.45
		body_transforms[body_name] = Transform3D(Basis.IDENTITY, Vector3(x, y, z))
	for i in range(model.joint_names.size()):
		var joint_name := model.joint_names[i]
		joint_positions[joint_name] = 0.0
		joint_velocities[joint_name] = 0.0
	for actuator_name in model.actuator_names:
		controls[actuator_name] = 0.0
		actuator_states[actuator_name] = 0.0
	if seed != 0:
		controls["seed"] = seed
	if _native_loaded:
		_sync_from_native()


func _try_load_native_backend(path: String) -> void:
	if not ClassDB.class_exists("MjNativeSimulation"):
		push_warning("[GodotMuJoCo] MjNativeSimulation class is unavailable; using GDScript fallback")
		return
	_native_backend = ClassDB.instantiate("MjNativeSimulation")
	if _native_backend == null:
		push_warning("[GodotMuJoCo] Failed to instantiate MjNativeSimulation; using GDScript fallback")
		return
	var xml := _load_native_xml(path)
	if xml.is_empty():
		push_warning("[GodotMuJoCo] Empty XML after include expansion; using GDScript fallback")
		return
	var ok := bool(_native_backend.load_xml_string(xml, path.get_file()))
	if not ok:
		var error: String = str(_native_backend.get_last_error()) if _native_backend.has_method("get_last_error") else "unknown"
		push_warning("[GodotMuJoCo] Native MuJoCo load failed: %s" % error)
		return
	_native_loaded = true
	print("[GodotMuJoCo] Native MuJoCo backend loaded: %s" % JSON.stringify(_native_backend.get_status()))


func _load_native_xml(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return ""
	return _expand_mjcf_includes(text, path.get_base_dir(), {})


func _expand_mjcf_includes(text: String, base_dir: String, seen: Dictionary) -> String:
	var regex := RegEx.new()
	regex.compile("<include\\s+file=[\"']([^\"']+)[\"']\\s*/>")
	var result := ""
	var cursor := 0
	for match_result in regex.search_all(text):
		result += text.substr(cursor, match_result.get_start() - cursor)
		var include_file := match_result.get_string(1)
		var include_path := "%s/%s" % [base_dir, include_file]
		if seen.has(include_path):
			push_warning("[GodotMuJoCo] Skipping recursive MJCF include: %s" % include_path)
		else:
			seen[include_path] = true
			var include_text := FileAccess.get_file_as_string(include_path)
			include_text = _strip_xml_declaration(include_text)
			result += _unwrap_mujoco_root(_expand_mjcf_includes(include_text, include_path.get_base_dir(), seen))
		cursor = match_result.get_end()
	result += text.substr(cursor)
	return result


func _strip_xml_declaration(text: String) -> String:
	var regex := RegEx.new()
	regex.compile("^\\s*<\\?xml[^>]*>\\s*")
	return regex.sub(text, "", true)


func _unwrap_mujoco_root(text: String) -> String:
	var open_regex := RegEx.new()
	open_regex.compile("^\\s*(?:<!--(.|\\n)*?-->)?\\s*<mujoco[^>]*>")
	var without_open := open_regex.sub(text, "", true)
	var close_regex := RegEx.new()
	close_regex.compile("</mujoco>\\s*$")
	return close_regex.sub(without_open, "", true)


func _sync_from_native() -> void:
	if not _native_loaded:
		return
	if _native_backend.has_method("get_status"):
		var status: Dictionary = _native_backend.get_status()
		sim_time = float(status.get("sim_time", sim_time))
		step_index = int(status.get("step_index", step_index))
	var body_names := _native_body_names
	if body_names.is_empty() and model:
		body_names = model.body_names
	for body_name in body_names:
		var native_transform: Dictionary = _native_backend.get_body_transform(body_name)
		if native_transform.is_empty():
			continue
		body_transforms[body_name] = _dict_to_transform(native_transform)


func _dict_to_transform(native_transform: Dictionary) -> Transform3D:
	var position = native_transform.get("position", PackedFloat64Array([0.0, 0.0, 0.0]))
	var basis_values = native_transform.get("basis", PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]))
	var basis := Basis(
		Vector3(float(basis_values[0]), float(basis_values[3]), float(basis_values[6])),
		Vector3(float(basis_values[1]), float(basis_values[4]), float(basis_values[7])),
		Vector3(float(basis_values[2]), float(basis_values[5]), float(basis_values[8]))
	)
	return Transform3D(basis, Vector3(float(position[0]), float(position[1]), float(position[2])))


func _step_fallback(dt: float) -> void:
	if model == null:
		return
	var actuator_count := max(1, model.actuator_names.size())
	for i in range(model.joint_names.size()):
		var joint_name := model.joint_names[i]
		var actuator_name := model.actuator_names[i % actuator_count] if model.actuator_names.size() > 0 else joint_name
		var target := float(controls.get(actuator_name, controls.get("gripper", 0.0)))
		var current := float(joint_positions.get(joint_name, 0.0))
		var next := lerpf(current, target, minf(1.0, dt * 8.0))
		joint_positions[joint_name] = next
		joint_velocities[joint_name] = (next - current) / maxf(dt, 0.0001)
		actuator_states[actuator_name] = target
	var base_delta := Vector3(float(controls.get("base_x", 0.0)) * dt, 0.0, 0.0)
	for i in range(model.body_names.size()):
		var body_name := model.body_names[i]
		var transform: Transform3D = body_transforms.get(body_name, Transform3D.IDENTITY)
		var phase := sim_time * 2.0 + float(i) * 0.37
		var joint_wave := 0.0
		if model.joint_names.size() > 0:
			joint_wave = float(joint_positions.get(model.joint_names[i % model.joint_names.size()], 0.0))
		transform.origin += base_delta
		transform.origin.y += sin(phase) * 0.0008
		transform.origin.z += joint_wave * 0.0005
		body_transforms[body_name] = transform
	contacts = []
	if step_index % 30 == 0:
		contacts.append({"geom1": "gripper", "geom2": "red_cube", "normal_force": absf(float(controls.get("gripper", 0.0)))})
	forces = {"gripper": absf(float(controls.get("gripper", 0.0))), "base": absf(float(controls.get("base_x", 0.0)))}


func _transforms_to_dict() -> Dictionary:
	var out := {}
	for key in body_transforms.keys():
		var t: Transform3D = body_transforms[key]
		out[key] = {"position": [t.origin.x, t.origin.y, t.origin.z], "basis": [t.basis.x, t.basis.y, t.basis.z]}
	return out
