class_name MjProfiler
extends Node

@export var simulation_path: NodePath
@export var sample_interval := 1.0

var sample_count := 0
var last_sample := {}
var max_mean_step_usec := 0.0
var max_step_usec := 0.0
var max_static_memory_kb := 0.0
var _simulation: MjSimulation
var _accumulator := 0.0


func _ready() -> void:
	_resolve_nodes()


func _process(delta: float) -> void:
	_accumulator += delta
	if _accumulator < sample_interval:
		return
	_accumulator = 0.0
	sample()


func sample() -> Dictionary:
	_resolve_nodes()
	var native_status := _simulation.get_native_status() if _simulation else {}
	var mean_step := float(native_status.get("mean_step_usec", 0.0))
	var peak_step := float(native_status.get("max_step_usec", 0.0))
	var memory_kb := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1024.0
	max_mean_step_usec = maxf(max_mean_step_usec, mean_step)
	max_step_usec = maxf(max_step_usec, peak_step)
	max_static_memory_kb = maxf(max_static_memory_kb, memory_kb)
	sample_count += 1
	last_sample = {
		"sample_count": sample_count,
		"timestamp_usec": Time.get_ticks_usec(),
		"backend": native_status.get("backend", "unknown"),
		"native_loaded": bool(native_status.get("loaded", false)),
		"step_index": int(native_status.get("step_index", 0)),
		"sim_time": float(native_status.get("sim_time", 0.0)),
		"mean_step_usec": mean_step,
		"max_step_usec": peak_step,
		"memory_static_kb": memory_kb,
		"max_mean_step_usec": max_mean_step_usec,
		"max_static_memory_kb": max_static_memory_kb,
	}
	return last_sample.duplicate(true)


func summary() -> Dictionary:
	return {
		"samples": sample_count,
		"last": last_sample.duplicate(true),
		"max_mean_step_usec": max_mean_step_usec,
		"max_step_usec": max_step_usec,
		"max_static_memory_kb": max_static_memory_kb,
	}


func _resolve_nodes() -> void:
	if _simulation == null and not simulation_path.is_empty():
		_simulation = get_node_or_null(simulation_path) as MjSimulation
