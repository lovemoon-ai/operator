class_name MjModelResource
extends Resource

@export_file("*.xml", "*.mjcf", "*.urdf") var source_path := ""
@export var robot_name := ""
@export var source_format := ""
@export var body_names: PackedStringArray = []
@export var joint_names: PackedStringArray = []
@export var actuator_names: PackedStringArray = []
@export var geom_names: PackedStringArray = []
@export var sensor_names: PackedStringArray = []
@export var stable_ids: Dictionary = {}
@export var metadata: Dictionary = {}


func is_valid_model() -> bool:
	return not source_path.is_empty() and body_names.size() > 0


func duplicate_summary() -> Dictionary:
	return {
		"source_path": source_path,
		"source_format": source_format,
		"robot_name": robot_name,
		"body_count": body_names.size(),
		"joint_count": joint_names.size(),
		"actuator_count": actuator_names.size(),
		"geom_count": geom_names.size(),
		"sensor_count": sensor_names.size(),
		"stable_ids": stable_ids,
	}
