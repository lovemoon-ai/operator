extends RefCounted
## WP7 unit test: FeatureRegistry definitions, dependency/conflict
## validation, and launcher-card alias mapping.

const CASE_ID := "contracts.feature_registry"

const EXPECTED_ALIASES := {
	"mode_teleop": "operator_launcher_card_teleop",
	"mode_ego_capture": "operator_launcher_card_ego",
	"mode_live_feed": "operator_launcher_card_live",
	"mode_vr": "operator_launcher_card_vr",
}


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var defs := FeatureRegistry.definitions()
	t.eq(defs.size(), OperatorFeature.all_ids().size(),
		"registry must define every OperatorFeature id")

	var seen: Dictionary = {}
	for def_v in defs:
		var def := def_v as FeatureDefinition
		t.is_false(seen.has(def.id), "duplicate definition for id %d" % def.id)
		seen[def.id] = true
		var id_string := OperatorFeature.id_to_string(def.id)
		t.eq(def.option, "operator_feature_%s" % id_string,
			"option name follows operator_feature_<id> for %s" % id_string)
		t.eq(def.runtime_tag, def.option, "runtime tag equals option name for %s" % id_string)
		if EXPECTED_ALIASES.has(id_string):
			t.eq(def.launcher_card_alias, EXPECTED_ALIASES[id_string],
				"launcher card alias for %s" % id_string)

	# from_string accepts bare ids and prefixed option names.
	t.eq(OperatorFeature.from_string("mode_ego_capture"), OperatorFeature.MODE_EGO_CAPTURE,
		"from_string accepts bare ids")
	t.eq(OperatorFeature.from_string("operator_feature_robot_constraint"),
		OperatorFeature.ROBOT_CONSTRAINT, "from_string accepts prefixed names")
	t.eq(OperatorFeature.from_string("nonexistent_feature"), -1,
		"from_string rejects unknown names")

	# Dependency rule: robot_constraint requires robot_control.
	var invalid := {OperatorFeature.ROBOT_CONSTRAINT: true}
	t.is_true(FeatureRegistry.validate(invalid).size() > 0,
		"robot_constraint without robot_control must fail validation")
	var valid := {
		OperatorFeature.ROBOT_CONSTRAINT: true,
		OperatorFeature.ROBOT_CONTROL: true,
	}
	t.eq(FeatureRegistry.validate(valid).size(), 0,
		"robot_constraint with robot_control must validate")

	# FeatureSet built from explicit ids honors the same rules.
	var features := FeatureSet.from_enabled_ids(
		[OperatorFeature.ROBOT_CONSTRAINT])
	t.is_true(features.validate().size() > 0,
		"FeatureSet.validate surfaces dependency errors")

	# Per-launch IsaacTeleop opt-in enables the mode and sink together while
	# leaving normal feature sets untouched.
	var opt_in := FeatureSet.from_enabled_ids([])
	opt_in.apply_runtime_overrides(["operator.isaac_teleop=true"])
	t.is_true(opt_in.enabled(OperatorFeature.MODE_TELEOP),
		"IsaacTeleop opt-in enables teleop mode")
	t.is_true(opt_in.enabled(OperatorFeature.SINK_ISAAC_TELEOP),
		"IsaacTeleop opt-in enables its sink")
	t.eq(opt_in.validate().size(), 0, "IsaacTeleop opt-in satisfies feature dependencies")
	var paired := FeatureSet.from_enabled_ids([])
	paired.apply_runtime_overrides(["--operator.isaac_teleop", "true"])
	t.is_true(paired.enabled(OperatorFeature.SINK_ISAAC_TELEOP),
		"Android extra pair form is accepted")
	var opt_out := FeatureSet.from_enabled_ids([])
	opt_out.apply_runtime_overrides(["operator.isaac_teleop=false"])
	t.is_false(opt_out.enabled(OperatorFeature.SINK_ISAAC_TELEOP),
		"explicit false does not enable the sink")
	t.is_false(opt_out.set_enabled(9999, true), "unknown feature overrides are rejected")
