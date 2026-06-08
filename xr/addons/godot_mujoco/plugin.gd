@tool
extends EditorPlugin


func _enter_tree() -> void:
	var icon := get_editor_interface().get_base_control().get_theme_icon("Node3D", "EditorIcons")
	add_custom_type("MjSimulation", "Node", preload("res://addons/godot_mujoco/mj_simulation.gd"), icon)
	add_custom_type("MjBodyTracker", "Node3D", preload("res://addons/godot_mujoco/mj_body_tracker.gd"), icon)
	add_custom_type("MjTeleopRig", "Node", preload("res://addons/godot_mujoco/mj_teleop_rig.gd"), icon)
	add_custom_type("MjLeRobotRecorder", "Node", preload("res://addons/godot_mujoco/mj_lerobot_recorder.gd"), icon)
	add_custom_type("MjProfiler", "Node", preload("res://addons/godot_mujoco/mj_profiler.gd"), icon)
	add_custom_type("MjHapticsBridge", "Node", preload("res://addons/godot_mujoco/mj_haptics_bridge.gd"), icon)


func _exit_tree() -> void:
	remove_custom_type("MjHapticsBridge")
	remove_custom_type("MjProfiler")
	remove_custom_type("MjLeRobotRecorder")
	remove_custom_type("MjTeleopRig")
	remove_custom_type("MjBodyTracker")
	remove_custom_type("MjSimulation")
