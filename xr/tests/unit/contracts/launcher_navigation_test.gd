extends RefCounted

const CaptureAppBaseScript := preload("res://scripts/app/modes/capture_app_base.gd")
const ModeSelectScript := preload("res://scripts/app/launcher/mode_select.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var capture := CaptureAppBaseScript.new()
	capture.keep_passthrough_visible = true
	capture._passthrough_active = true
	capture._scene_transition_target = CaptureAppBaseScript.LAUNCHER_SCENE
	t.is_true(
		capture._preserve_passthrough_for_transition(),
		"Ego -> launcher must hand off the active passthrough session"
	)

	capture._scene_transition_target = "res://scenes/vr_mode.tscn"
	t.is_false(
		capture._preserve_passthrough_for_transition(),
		"non-launcher transitions must not retain passthrough"
	)

	capture._scene_transition_target = CaptureAppBaseScript.LAUNCHER_SCENE
	capture._passthrough_active = false
	t.is_false(
		capture._preserve_passthrough_for_transition(),
		"inactive passthrough must not be treated as a handoff"
	)

	capture._passthrough_active = true
	capture.keep_passthrough_visible = false
	t.is_false(
		capture._preserve_passthrough_for_transition(),
		"a mode that disabled passthrough must not retain it"
	)
	capture.free()

	var low_tracked_camera := Transform3D(
		Basis.from_euler(Vector3(0.2, -0.4, 0.1)),
		Vector3(0.15, 0.30, 0.45)
	)
	var tracked_anchor: Transform3D = ModeSelectScript._launch_anchor_from_camera(
		low_tracked_camera, true)
	t.almost_eq(
		tracked_anchor.origin.y,
		0.30,
		0.0001,
		"a valid low PICO LOCAL-space head pose must keep its real height"
	)

	var fallback_anchor: Transform3D = ModeSelectScript._launch_anchor_from_camera(
		low_tracked_camera, false)
	t.almost_eq(
		fallback_anchor.origin.y,
		ModeSelectScript.FALLBACK_EYE_HEIGHT,
		0.0001,
		"an untracked camera must use the eye-height fallback"
	)

	var launcher := ModeSelectScript.new()
	var seven_positions: Array = launcher._compute_card_positions(7)
	t.eq(seven_positions.size(), 7, "launcher allocates one position per enabled card")
	launcher.free()
