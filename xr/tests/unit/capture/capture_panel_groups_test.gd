extends RefCounted
## Regression contract for the groups owned by the Ego capture settings panel.
## Robot constraints are configured by Teleop and must not reappear here.

const CASE_ID := "capture.panel_groups"
const CapturePanelScript := preload("res://scripts/ui/view_locked_capture_panel.gd")
const BuildInfo := preload("res://scripts/app/build_info.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var panel: Node = CapturePanelScript.new(false)
	var root := Engine.get_main_loop().root as Window
	root.add_child(panel)

	var group_containers: Dictionary = panel.get("_group_containers")
	var group_buttons: Dictionary = panel.get("_group_buttons")
	t.is_true(group_containers.has("display"), "Ego capture panel builds its display group")
	t.is_false(group_containers.has("robot_constraint"), "Ego capture panel omits robot constraints")
	t.is_false(group_buttons.has("robot_constraint"), "Ego capture sidebar omits robot constraints")
	t.eq(group_containers.keys().back(), "build_info", "Ego capture sidebar ends with Version info")
	var build_texts := _label_texts(group_containers.get("build_info"))
	t.ne(BuildInfo.version(), "", "the release version is baked into the project")
	t.contains(build_texts, BuildInfo.version(), "Version info shows the release version")
	t.is_true(BuildInfo.commit().is_valid_hex_number(), "the exported APK carries its source commit")
	t.contains(build_texts, BuildInfo.commit(), "Version info shows the source commit")
	t.eq(BuildInfo.build_time().length(), 16, "the exported APK carries its build time")
	t.contains(build_texts, BuildInfo.build_time(), "Version info shows the build time")

	panel.queue_free()


func _label_texts(group: Node) -> Array:
	var texts: Array = []
	if group != null:
		for label in group.find_children("*", "Label", true, false):
			texts.append((label as Label).text)
	return texts
