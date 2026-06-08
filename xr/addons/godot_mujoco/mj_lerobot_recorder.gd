class_name MjLeRobotRecorder
extends Node

@export var simulation_path: NodePath
@export var teleop_path: NodePath
@export var dataset_root := "user://mujoco_lerobot"
@export var task_name := "so101_pickplace_vr"
@export var robot_name := "so101"
@export var sample_interval := 1.0 / 30.0

var recording := false
var episode_dir := ""
var frame_count := 0
var _simulation: MjSimulation
var _teleop: MjTeleopRig
var _accumulator := 0.0
var _jsonl: FileAccess
var _started_usec := 0


func _ready() -> void:
	_resolve_nodes()


func _process(delta: float) -> void:
	if not recording:
		return
	_accumulator += delta
	if _accumulator < sample_interval:
		return
	_accumulator = 0.0
	record_frame()


func start_episode(metadata := {}) -> bool:
	_resolve_nodes()
	if _simulation == null:
		push_error("[GodotMuJoCo] Cannot record without MjSimulation")
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dataset_root))
	_started_usec = Time.get_ticks_usec()
	episode_dir = "%s/episode_%d" % [dataset_root, _started_usec]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(episode_dir))
	_jsonl = FileAccess.open("%s/data.jsonl" % episode_dir, FileAccess.WRITE)
	if _jsonl == null:
		push_error("[GodotMuJoCo] Failed to open episode writer: %s" % episode_dir)
		return false
	frame_count = 0
	recording = true
	_write_json("%s/metadata.json" % episode_dir, _metadata(metadata))
	print("[GodotMuJoCo] LeRobot episode started: %s" % ProjectSettings.globalize_path(episode_dir))
	return true


func record_frame() -> void:
	if _jsonl == null or _simulation == null:
		return
	var action := _teleop.last_action if _teleop else {}
	var row := {
		"episode_index": 0,
		"frame_index": frame_count,
		"timestamp": Time.get_ticks_usec(),
		"simulation": {"step_index": _simulation.step_index, "sim_time": _simulation.sim_time},
		"observation": _simulation.get_observation(),
		"action": action,
	}
	_jsonl.store_line(JSON.stringify(row))
	frame_count += 1


func stop_episode() -> Dictionary:
	if not recording:
		return {}
	recording = false
	if _jsonl:
		_jsonl.flush()
		_jsonl.close()
	var summary := {"episode_dir": ProjectSettings.globalize_path(episode_dir), "frames": frame_count, "duration_usec": Time.get_ticks_usec() - _started_usec}
	_write_json("%s/summary.json" % episode_dir, summary)
	print("[GodotMuJoCo] LeRobot episode stopped: %s frames=%d" % [summary["episode_dir"], frame_count])
	return summary


func validate_episode(path := "") -> Dictionary:
	var root := episode_dir if path.is_empty() else path
	return MjDatasetValidator.validate_episode(root, 1, false)


func replay_episode(path := "", max_frames := 0) -> Dictionary:
	var root := episode_dir if path.is_empty() else path
	return MjDatasetValidator.replay_episode(root, max_frames)


func _resolve_nodes() -> void:
	if _simulation == null and not simulation_path.is_empty():
		_simulation = get_node_or_null(simulation_path) as MjSimulation
	if _teleop == null and not teleop_path.is_empty():
		_teleop = get_node_or_null(teleop_path) as MjTeleopRig


func _metadata(extra: Dictionary) -> Dictionary:
	var metadata := {
		"format": "lerobot-compatible-jsonl-proxy",
		"schema_version": "operator.mujoco.lerobot.v1",
		"task": task_name,
		"robot": robot_name,
		"created_usec": _started_usec,
		"modalities": ["state", "rgb", "depth", "segmentation", "contact", "force", "action"],
	}
	for key in extra.keys():
		metadata[key] = extra[key]
	return metadata


func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(value, "\t"))
		file.close()
