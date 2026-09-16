extends RefCounted
## Keeps the shared XR interaction contract stable: PICO uses its calibrated
## palm ray, while non-PICO builds retain the OpenXR hand aim path.

const CASE_ID := "contracts.pico_interaction_parity"
const OperatorInteractionScript := preload("res://scripts/interaction/operator_interaction.gd")
const OperatorStartXRScript := preload("res://scripts/xr/operator_start_xr.gd")
const SettingsInteractionRouterScript := preload("res://scripts/ui/settings_interaction_router.gd")
const TrackingProviderScript := preload("res://scripts/xr/tracking_provider.gd")
const PointerVisualScript := preload("res://scripts/xr/operator_ui_pointer_visual.gd")


class TeleopCapturingTarget:
	extends RefCounted

	func captures_teleop_input() -> bool:
		return true


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_stale_hand_profile(t)
	_test_invalid_pose_fallback(t)
	_test_ray_transform_recovery(t)
	t.eq(
		OperatorInteractionScript._mode_from_evidence(false, true, true, false, false, true),
		"controllers",
		"controller profiles must take priority over bare-hand profiles"
	)
	t.eq(
		OperatorInteractionScript._mode_from_evidence(false, false, false, true, true, true),
		"controllers",
		"tracked controllers must take priority over hand gestures"
	)
	t.eq(
		OperatorInteractionScript._mode_from_evidence(false, false, true, true, false, true),
		"hands",
		"an explicit hand profile must take priority over generic pose tracking"
	)
	t.eq(
		OperatorInteractionScript._mode_from_evidence(false, false, false, false, true, false),
		"hands",
		"a bare-hand pinch must activate hand interaction"
	)

	var no_permissions := PackedStringArray()
	t.is_true(
		OperatorStartXRScript._requires_pico_hand_permission(
			"Android", true, true, no_permissions),
		"PICO Android builds must request hand tracking before OpenXR starts"
	)
	t.is_false(
		OperatorStartXRScript._requires_pico_hand_permission(
			"Android",
			true,
			true,
			PackedStringArray([OperatorStartXRScript.PICO_HAND_TRACKING_PERMISSION])
		),
		"an already-granted PICO hand permission must not be requested again"
	)
	t.is_false(
		OperatorStartXRScript._requires_pico_hand_permission(
			"Android", false, true, no_permissions),
		"non-PICO Android builds must not request the PICO permission"
	)
	t.is_false(
		OperatorStartXRScript._requires_pico_hand_permission(
			"Android", true, false, no_permissions),
		"builds without OpenXR hand tracking must initialize normally"
	)

	for scene_path in [
		"res://scenes/main.tscn",
		"res://scenes/teleop_main.tscn",
		"res://scenes/vr_mode.tscn",
	]:
		var packed_scene := load(scene_path) as PackedScene
		t.is_true(packed_scene != null, "%s must remain loadable" % scene_path)
		if packed_scene == null:
			continue
		var scene_root := packed_scene.instantiate()
		var start_xr := scene_root.get_node_or_null("StartXR")
		t.is_true(
			start_xr != null and start_xr.get_script() == OperatorStartXRScript,
			"%s must use the permission-aware StartXR implementation" % scene_path
		)
		scene_root.free()
	t.is_true(
		SettingsInteractionRouterScript._is_finite_vector(Vector3.ZERO),
		"finite hand-ray vectors must remain usable"
	)
	t.is_false(
		SettingsInteractionRouterScript._is_finite_vector(Vector3(NAN, 0.0, 0.0)),
		"invalid XR vectors must be rejected"
	)
	t.eq(
		SettingsInteractionRouterScript._hand_ray_strategy_for_platform(true),
		SettingsInteractionRouterScript.HAND_RAY_STRATEGY_PALM,
		"PICO builds must use the palm-only hand ray"
	)
	t.eq(
		SettingsInteractionRouterScript._hand_ray_strategy_for_platform(false),
		SettingsInteractionRouterScript.HAND_RAY_STRATEGY_AIM,
		"non-PICO builds must keep the OpenXR hand aim path"
	)

	var palm_basis := Basis(Vector3.UP, deg_to_rad(35.0)) \
			* Basis(Vector3.RIGHT, deg_to_rad(-20.0))
	var palm_position := Vector3(0.4, 1.3, -0.7)
	var palm_ray := SettingsInteractionRouterScript._palm_pose_ray(
		Transform3D(palm_basis, palm_position)
	)
	t.is_true(not palm_ray.is_empty(), "a valid Pico palm pose must produce a hand ray")
	t.is_true(
		(palm_ray.get("origin", Vector3.ZERO) as Vector3).is_equal_approx(palm_position),
		"Pico hand ray must originate at the palm"
	)
	t.is_true(
		(palm_ray.get("direction", Vector3.ZERO) as Vector3).is_equal_approx(
			(
				palm_basis.z.normalized()
				+ palm_basis.y.normalized()
						* SettingsInteractionRouterScript.HAND_RAY_FORWARD_BIAS
			).normalized()
		),
		"Pico hand ray must apply a fixed palm-local forward bias"
	)
	t.is_true(
		(palm_ray.get("direction", Vector3.ZERO) as Vector3).dot(palm_basis.y.normalized()) > 0.0,
		"the ergonomic bias must pull the ray toward the palm's finger-forward axis"
	)
	var moved_palm_ray := SettingsInteractionRouterScript._palm_pose_ray(
		Transform3D(palm_basis, Vector3(-2.0, 0.5, 4.0))
	)
	t.is_true(
		(moved_palm_ray.get("direction", Vector3.ZERO) as Vector3).is_equal_approx(
			palm_ray.get("direction", Vector3.ZERO) as Vector3
		),
		"moving the hand without rotating the palm must not change ray direction"
	)
	t.is_true(
		SettingsInteractionRouterScript._palm_pose_ray(
			Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), palm_position)
		).is_empty(),
		"a palm pose without a direction axis must be rejected"
	)

	var capture_target := TeleopCapturingTarget.new()
	t.is_true(
		SettingsInteractionRouterScript._target_captures_teleop_input(capture_target),
		"video interaction targets must be able to capture teleop controller input"
	)
	t.is_false(
		SettingsInteractionRouterScript._target_captures_teleop_input(RefCounted.new()),
		"ordinary interaction targets must not suppress teleop input"
	)
	var neutral_input := TrackingProviderScript._neutral_controller_input({
		"trigger": 0.8,
		"grip": 0.9,
		"primary": Vector2(0.4, -0.7),
		"primary_click": 1.0,
		"timestamp_ns": 123,
	})
	t.is_true((neutral_input["primary"] as Vector2).is_zero_approx(),
		"captured joystick vectors must be neutralized")
	t.eq(neutral_input["trigger"], 0.0, "captured trigger input must be neutralized")
	t.eq(neutral_input["grip"], 0.0, "captured deadman input must be neutralized")
	t.eq(neutral_input["primary_click"], 0.0, "captured joystick clicks must be neutralized")
	t.eq(neutral_input["timestamp_ns"], 123, "input capture must preserve sample timing")


func _test_stale_hand_profile(t: OperatorTestAssertions) -> void:
	const HAND := "/interaction_profiles/ext/hand_interaction_ext"
	const CONTROLLER := "/interaction_profiles/bytedance/pico4s_controller"
	var state: Dictionary = OperatorInteractionScript.advance_controller_evidence({}, HAND, 10, 0, false)
	t.is_false(bool(state["override"]), "a hand profile alone stays in hands mode")
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 1, false)
	t.is_true(bool(state["override"]), "fresh trigger overrides Pico's stale hand profile")
	t.is_true(bool(state["controller_edge"]), "trigger activation is recorded as fresh controller evidence")
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 0, false)
	t.is_true(bool(state["override"]), "releasing trigger does not drop the controller ray")
	for _frame in range(100):
		state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 0, false)
	t.is_true(bool(state["override"]), "idle controllers retain ownership without an expiry timeout")
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 0, true)
	t.is_false(bool(state["override"]), "fresh explicit hand pinch restores bare-hand input")
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 0, false)
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 1, true)
	t.is_true(bool(state["override"]), "simultaneous physical trigger beats hand pinch")
	state = OperatorInteractionScript.advance_controller_evidence(state, CONTROLLER, 10, 1, false)
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 1, false)
	t.is_false(bool(state["override"]), "profile changes do not reuse a cached held trigger")
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 0, false)
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 10, 1, false)
	t.is_true(bool(state["override"]), "a new press can recover after a profile transition")
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 11, 1, false)
	t.is_false(bool(state["override"]), "a replacement tracker cannot inherit fallback ownership")
	state = OperatorInteractionScript.advance_controller_evidence({}, HAND, 12, 2, false)
	state = OperatorInteractionScript.advance_controller_evidence(state, HAND, 12, 3, false)
	t.is_true(bool(state["override"]), "holding grip must not mask a new trigger press")

	# Keep the 'physical action' assumption tied to the actual shipped map.
	var action_map := load("res://openxr_action_map.tres") as OpenXRActionMap
	var profiles: Array = action_map.get("interaction_profiles")
	var hand_profiles := 0
	for profile_v in profiles:
		var profile: Resource = profile_v
		if str(profile.get("interaction_profile_path")).find("hand_interaction") == -1:
			continue
		hand_profiles += 1
		var bindings: Array = profile.get("bindings")
		for binding_v in bindings:
			var binding: Resource = binding_v
			var action: Resource = binding.get("action")
			t.is_false(
				OperatorInteractionScript.CONTROLLER_ONLY_ACTIONS.has(StringName(action.resource_name)),
				"bare-hand profile must not bind controller-only action %s" % action.resource_name,
			)
	t.is_true(hand_profiles > 0, "the shipped action map includes a hand interaction profile")
	_test_mixed_controller_selection(t)


func _test_mixed_controller_selection(t: OperatorTestAssertions) -> void:
	# Isolated tracker names: never replace the headset's real left/right trackers.
	var left_tracker := XRPositionalTracker.new()
	var right_tracker := XRPositionalTracker.new()
	left_tracker.name = "operator_test_pointer_left"
	right_tracker.name = "operator_test_pointer_right"
	left_tracker.type = XRServer.TRACKER_CONTROLLER
	right_tracker.type = XRServer.TRACKER_CONTROLLER
	for tracker in [left_tracker, right_tracker]:
		tracker.set_pose(&"aim", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(tracker)
	var root := Node3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	var left := XRController3D.new()
	var right := XRController3D.new()
	left.tracker = StringName(left_tracker.name)
	right.tracker = StringName(right_tracker.name)
	left.pose = &"aim"
	right.pose = &"aim"
	root.add_child(left)
	root.add_child(right)
	# XRNode3D learns tracking through pose_changed after it binds the tracker.
	for tracker in [left_tracker, right_tracker]:
		tracker.set_pose(&"aim", Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	var router := SettingsInteractionRouterScript.new()
	root.add_child(router)
	router.left_pointer = left
	router.right_pointer = right
	router.controller_source_filter = func(pointer: XRController3D) -> bool: return pointer == left
	t.eq(router._active_controller_pointer(), left, "a tracked right bare hand must not starve a left controller")
	left_tracker.invalidate_pose(&"aim")
	t.eq(router._active_controller_pointer(), null, "lost controller tracking must not fall back to a bare-hand pose")
	root.free()
	XRServer.remove_tracker(left_tracker)
	XRServer.remove_tracker(right_tracker)


func _test_invalid_pose_fallback(t: OperatorTestAssertions) -> void:
	var tracker := XRPositionalTracker.new()
	tracker.name = "operator_test_invalid_aim"
	tracker.type = XRServer.TRACKER_CONTROLLER
	tracker.profile = "/interaction_profiles/bytedance/pico4s_controller"
	var bad_basis := Basis(Vector3(NAN, 0, 0), Vector3.UP, Vector3.BACK)
	var good := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.3, -0.4))
	tracker.set_pose(&"aim", Transform3D(bad_basis, Vector3.ZERO), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	tracker.set_pose(&"default", good, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(tracker)
	var service := OperatorInteractionScript.new()
	t.is_false(service._pose_is_tracked(tracker, &"aim"), "a high-confidence NaN aim is not usable")
	t.eq(service._preferred_pointer_pose(StringName(tracker.name)), &"default", "invalid aim falls back to a real finite default pose")
	tracker.set_pose(&"aim", good, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	t.eq(service._preferred_pointer_pose(StringName(tracker.name)), &"aim", "a recovered aim is preferred again")
	t.is_false(OperatorInteractionScript.usable_pose_transform(
		Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)),
		"degenerate orientation is not a usable pose")
	service.free()
	XRServer.remove_tracker(tracker)


func _test_ray_transform_recovery(t: OperatorTestAssertions) -> void:
	var visual := PointerVisualScript.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(visual)
	var origin := Vector3(0.2, 1.3, -0.4)
	visual.show_idle_ray(origin, Vector3.FORWARD)
	t.is_true(visual.is_visible_in_tree(), "finite input draws the idle ray")
	var original := visual.global_transform
	visual.show_idle_ray(origin, Vector3(NAN, 0, -1))
	t.is_false(visual.visible, "NaN direction hides the ray before contaminating its transform")
	t.is_true(visual.global_transform.is_equal_approx(original), "invalid data never changes the render transform")
	visual.show_ray(origin, Vector3.FORWARD, Vector3(INF, 0, 0))
	t.is_false(visual.visible, "non-finite hit points are rejected")
	visual.show_idle_ray(origin, Vector3.ZERO)
	t.is_false(visual.visible, "zero-length direction is rejected")
	visual.scale = Vector3(2, 3, 4)
	visual.show_idle_ray(origin, Vector3.FORWARD)
	t.is_true(visual.global_basis.get_scale().is_equal_approx(Vector3.ONE), "fresh ray basis cannot inherit poisoned or accumulated scale")
	t.is_true(visual.visible and visual.global_transform.is_finite(), "valid input restores ray visibility")
	visual.free()
