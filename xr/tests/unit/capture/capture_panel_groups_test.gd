extends RefCounted
## Regression contract for the groups owned by the Ego capture settings panel.
## Robot constraints are configured by Teleop and must not reappear here.

const CASE_ID := "capture.panel_groups"
const CapturePanelScript := preload("res://scripts/ui/view_locked_capture_panel.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var panel: Node = CapturePanelScript.new(false)
	var root := Engine.get_main_loop().root as Window
	root.add_child(panel)

	var group_containers: Dictionary = panel.get("_group_containers")
	var group_buttons: Dictionary = panel.get("_group_buttons")
	t.is_true(group_containers.has("display"), "Ego capture panel builds its display group")
	t.is_false(group_containers.has("robot_constraint"), "Ego capture panel omits robot constraints")
	t.is_false(group_buttons.has("robot_constraint"), "Ego capture sidebar omits robot constraints")

	panel.queue_free()
