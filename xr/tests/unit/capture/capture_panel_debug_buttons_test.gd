extends RefCounted
## Regression contract for the robot-constraint debug controls in the shared
## Capture / Live Feed settings panel. A merge once restored the button creation
## block without restoring the member variables and pressed handlers, which made
## Live Feed fail at script compile time on device.

const CASE_ID := "capture.panel_debug_buttons"
const CapturePanelScript := preload("res://scripts/ui/view_locked_capture_panel.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var panel: Node = CapturePanelScript.new(false)
	var root := Engine.get_main_loop().root as Window
	root.add_child(panel)

	var signal_counts := {
		"body_pose": 0,
		"h2": 0,
		"g1": 0,
		"galbot_g1": 0,
	}
	panel.body_pose_debug_toggled.connect(func() -> void: signal_counts["body_pose"] += 1)
	panel.h2_debug_toggled.connect(func() -> void: signal_counts["h2"] += 1)
	panel.g1_debug_toggled.connect(func() -> void: signal_counts["g1"] += 1)
	panel.galbot_g1_debug_toggled.connect(func() -> void: signal_counts["galbot_g1"] += 1)

	var body_button: Button = panel.get("_body_pose_debug_button")
	var h2_button: Button = panel.get("_h2_debug_button")
	var g1_button: Button = panel.get("_g1_debug_button")
	var galbot_button: Button = panel.get("_galbot_g1_debug_button")
	t.is_true(body_button != null, "Body pose debug button is built")
	t.is_true(h2_button != null, "Unitree H2 debug button is built")
	t.is_true(g1_button != null, "Unitree G1 debug button is built")
	t.is_true(galbot_button != null, "Galbot G1 debug button is built")

	_assert_translated(panel, t, "UI_SHOW_BODY_POSE_DEBUG")
	_assert_translated(panel, t, "UI_HIDE_BODY_POSE_DEBUG")
	_assert_translated(panel, t, "UI_SHOW_UNITREE_H2_DEBUG")
	_assert_translated(panel, t, "UI_HIDE_UNITREE_H2_DEBUG")
	_assert_translated(panel, t, "UI_SHOW_UNITREE_G1_DEBUG")
	_assert_translated(panel, t, "UI_HIDE_UNITREE_G1_DEBUG")
	_assert_translated(panel, t, "UI_SHOW_GALBOT_G1_DEBUG")
	_assert_translated(panel, t, "UI_HIDE_GALBOT_G1_DEBUG")

	if body_button != null:
		body_button.emit_signal("pressed")
		panel.set_body_pose_debug_visible(true)
		t.eq(body_button.text, panel.tr("UI_HIDE_BODY_POSE_DEBUG"), "body-pose debug button switches to hide text")
		panel.set_body_pose_debug_visible(false)
		t.eq(body_button.text, panel.tr("UI_SHOW_BODY_POSE_DEBUG"), "body-pose debug button switches to show text")
	if h2_button != null:
		h2_button.emit_signal("pressed")
		panel.set_h2_debug_visible(true)
		t.eq(h2_button.text, panel.tr("UI_HIDE_UNITREE_H2_DEBUG"), "H2 debug button switches to hide text")
		panel.set_h2_debug_visible(false)
		t.eq(h2_button.text, panel.tr("UI_SHOW_UNITREE_H2_DEBUG"), "H2 debug button switches to show text")
	if g1_button != null:
		g1_button.emit_signal("pressed")
		panel.set_g1_debug_visible(true)
		t.eq(g1_button.text, panel.tr("UI_HIDE_UNITREE_G1_DEBUG"), "G1 debug button switches to hide text")
		panel.set_g1_debug_visible(false)
		t.eq(g1_button.text, panel.tr("UI_SHOW_UNITREE_G1_DEBUG"), "G1 debug button switches to show text")
	if galbot_button != null:
		galbot_button.emit_signal("pressed")
		panel.set_galbot_g1_debug_visible(true)
		t.eq(galbot_button.text, panel.tr("UI_HIDE_GALBOT_G1_DEBUG"), "Galbot G1 debug button switches to hide text")
		panel.set_galbot_g1_debug_visible(false)
		t.eq(galbot_button.text, panel.tr("UI_SHOW_GALBOT_G1_DEBUG"), "Galbot G1 debug button switches to show text")

	t.eq(signal_counts["body_pose"], 1, "body-pose pressed handler emits once")
	t.eq(signal_counts["h2"], 1, "H2 pressed handler emits once")
	t.eq(signal_counts["g1"], 1, "G1 pressed handler emits once")
	t.eq(signal_counts["galbot_g1"], 1, "Galbot G1 pressed handler emits once")

	panel.queue_free()


func _assert_translated(panel: Node, t: OperatorTestAssertions, key: String) -> void:
	t.ne(panel.tr(key), key, "%s has localized display text" % key)
