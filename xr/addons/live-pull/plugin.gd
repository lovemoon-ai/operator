@tool
extends EditorPlugin


func _enter_tree() -> void:
	var icon := get_editor_interface().get_base_control().get_theme_icon("Node3D", "EditorIcons")
	add_custom_type(
		"LivePullClient",
		"Node",
		preload("res://addons/live-pull/live_pull_client.gd"),
		icon
	)
	add_custom_type(
		"LivePullDenseMapView",
		"Node3D",
		preload("res://addons/live-pull/live_pull_dense_map_view.gd"),
		icon
	)


func _exit_tree() -> void:
	remove_custom_type("LivePullDenseMapView")
	remove_custom_type("LivePullClient")
