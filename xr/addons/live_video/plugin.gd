@tool
extends EditorPlugin


func _enter_tree() -> void:
	var icon := get_editor_interface().get_base_control().get_theme_icon("Node3D", "EditorIcons")
	add_custom_type(
		"LiveVideoView",
		"Node3D",
		preload("res://addons/live_video/live_video_view.gd"),
		icon
	)


func _exit_tree() -> void:
	remove_custom_type("LiveVideoView")
