extends RefCounted

const CaptureAppBaseScript := preload("res://scripts/app/modes/capture_app_base.gd")
const ModeSelectScript := preload("res://scripts/app/launcher/mode_select.gd")
const QuickEntryConfigScript := preload("res://scripts/app/launcher/quick_entry_config.gd")
const ViewportTemplate := preload("res://scenes/ui/viewport_2d_in_3d_clean.tscn")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	t.eq(
		ModeSelectScript.PASSTHROUGH_BACKGROUND_MODE,
		Environment.BG_COLOR,
		"launcher passthrough must use its transparent color instead of the default gray clear color"
	)
	var viewport_quad := ViewportTemplate.instantiate()
	var viewport := viewport_quad.get_node("Viewport") as SubViewport
	var screen := viewport_quad.get_node("Screen") as MeshInstance3D
	t.is_true(
		viewport != null and viewport.transparent_bg,
		"launcher card viewports must preserve transparent pixels"
	)
	t.is_true(
		screen != null and screen.material_override == null,
		"launcher card meshes must allow XR Tools to bind the runtime viewport texture"
	)
	viewport_quad.free()
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

	t.eq(
		QuickEntryConfigScript.resolve_from_tags(PackedStringArray()),
		QuickEntryConfigScript.MODE_LAUNCHER,
		"exports without a quick-entry tag must keep the launcher"
	)
	var quick_entry_modes: Array[String] = [
		QuickEntryConfigScript.MODE_LAUNCHER,
		QuickEntryConfigScript.MODE_TELEOP,
		QuickEntryConfigScript.MODE_EGO_CAPTURE,
		QuickEntryConfigScript.MODE_LIVE_FEED,
	]
	for mode in quick_entry_modes:
		var tag := QuickEntryConfigScript.tag_for_mode(mode)
		t.eq(
			QuickEntryConfigScript.resolve_from_tags(PackedStringArray([tag])),
			mode,
			"quick-entry tag must resolve to %s" % mode
		)

	var process_root := Node.new()
	t.eq(
		QuickEntryConfigScript.consume_for_process(
			process_root, QuickEntryConfigScript.MODE_TELEOP),
		QuickEntryConfigScript.MODE_TELEOP,
		"quick entry must be applied on the first launcher visit"
	)
	t.eq(
		QuickEntryConfigScript.consume_for_process(
			process_root, QuickEntryConfigScript.MODE_TELEOP),
		"",
		"quick entry must not reopen the mode after returning to the launcher"
	)
	process_root.free()

	var launcher_root := Node.new()
	t.eq(
		QuickEntryConfigScript.consume_for_process(
			launcher_root, QuickEntryConfigScript.MODE_LAUNCHER),
		"",
		"the launcher default must not create a direct startup route"
	)
	t.eq(
		QuickEntryConfigScript.consume_for_process(
			launcher_root, QuickEntryConfigScript.MODE_LIVE_FEED),
		QuickEntryConfigScript.MODE_LIVE_FEED,
		"showing the launcher must not consume a future direct route"
	)
	launcher_root.free()

	var teleop_only := FeatureSet.from_enabled_ids([
		OperatorFeature.MODE_TELEOP,
		OperatorFeature.MODE_EXIT,
	])
	t.is_true(
		ModeSelectScript._mode_available(ModeSelectScript.MODE_TELEOP, teleop_only),
		"a teleop-only build must allow the teleop mode"
	)
	t.is_true(
		ModeSelectScript._mode_available(ModeSelectScript.MODE_MUJOCO, teleop_only),
		"the internal MuJoCo bring-up route has no feature flag and always resolves"
	)
	for disabled_mode in [
		ModeSelectScript.MODE_EGO_CAPTURE,
		ModeSelectScript.MODE_LIVE_FEED,
		ModeSelectScript.MODE_VR,
	]:
		t.is_false(
			ModeSelectScript._mode_available(disabled_mode, teleop_only),
			"a teleop-only build must reject the stripped mode %s" % disabled_mode
		)

	var full_build := FeatureSet.from_enabled_ids([
		OperatorFeature.MODE_TELEOP,
		OperatorFeature.MODE_EGO_CAPTURE,
		OperatorFeature.MODE_LIVE_FEED,
		OperatorFeature.MODE_EXIT,
	])
	t.is_true(
		ModeSelectScript._mode_available(ModeSelectScript.MODE_EGO_CAPTURE, full_build),
		"a full build must keep the ego capture automation route"
	)
	t.is_false(
		ModeSelectScript._mode_available(ModeSelectScript.MODE_VR, full_build),
		"a mode disabled by its feature flag stays unreachable in a full build"
	)

	t.eq(
		ModeSelectScript.resolve_startup_route(
			ModeSelectScript.MODE_EGO_CAPTURE,
			ModeSelectScript.MODE_TELEOP,
			full_build,
			true),
		ModeSelectScript.MODE_EGO_CAPTURE,
		"an explicit request must outrank the export quick entry"
	)
	t.eq(
		ModeSelectScript.resolve_startup_route(
			"", ModeSelectScript.MODE_TELEOP, teleop_only, false),
		ModeSelectScript.MODE_TELEOP,
		"the quick entry must open when nothing was requested explicitly"
	)
	t.eq(
		ModeSelectScript.resolve_startup_route(
			ModeSelectScript.MODE_EGO_CAPTURE,
			ModeSelectScript.MODE_TELEOP,
			teleop_only,
			true),
		"",
		"a request this build cannot serve must fall back to the launcher, "
		+ "never to the quick-entry mode"
	)
	t.eq(
		ModeSelectScript.resolve_startup_route("", "", full_build, false),
		"",
		"no request and no quick entry must show the launcher"
	)
	t.eq(
		ModeSelectScript.resolve_startup_route(
			"", ModeSelectScript.MODE_LIVE_FEED, teleop_only, false),
		"",
		"a quick entry whose mode was stripped must show the launcher"
	)
	t.eq(
		ModeSelectScript.resolve_startup_route(
			"", ModeSelectScript.MODE_TELEOP, teleop_only, true),
		"",
		"an invalid explicit request must show the launcher, never the quick entry"
	)

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
