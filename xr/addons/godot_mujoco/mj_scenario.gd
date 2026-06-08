class_name MjScenario
extends Resource

@export var scenario_name := "mobile_manipulator_pickplace"
@export_file("*.xml", "*.mjcf", "*.urdf") var model_path := "res://assets/mujoco/mobile_manipulator_smoke.xml"
@export var task_name := "pickplace"
@export var seed := 1
@export var reset_policy := {
	"robot_home": true,
	"object_pose_jitter": 0.02,
	"lighting_jitter": 0.0,
}
@export var success_conditions := ["episode_frames_recorded", "native_backend_loaded"]
@export var failure_conditions := ["native_backend_missing", "dataset_validation_failed"]


func instantiate_metadata() -> Dictionary:
	return {
		"scenario": scenario_name,
		"model_path": model_path,
		"task": task_name,
		"seed": seed,
		"reset_policy": reset_policy.duplicate(true),
		"success_conditions": success_conditions.duplicate(true),
		"failure_conditions": failure_conditions.duplicate(true),
	}


func deterministic_offset(label: String, amplitude := 1.0) -> Vector3:
	var hash := hash("%s:%s:%d" % [scenario_name, label, seed])
	var x := float((hash >> 0) & 1023) / 1023.0 - 0.5
	var y := float((hash >> 10) & 1023) / 1023.0 - 0.5
	var z := float((hash >> 20) & 1023) / 1023.0 - 0.5
	return Vector3(x, y, z) * amplitude
