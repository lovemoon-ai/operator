extends RefCounted
## Keeps the shared PICO APK on the established interaction contract: explicit
## controller evidence wins, while bare-hand interaction remains the fallback.

const CASE_ID := "contracts.pico_interaction_parity"
const OperatorInteractionScript := preload("res://scripts/interaction/operator_interaction.gd")
const OperatorStartXRScript := preload("res://scripts/xr/operator_start_xr.gd")
const SettingsInteractionRouterScript := preload("res://scripts/ui/settings_interaction_router.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
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
