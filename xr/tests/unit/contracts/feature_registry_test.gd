extends RefCounted
## WP7 unit test: FeatureRegistry definitions and dependency/conflict
## validation.

const CASE_ID := "contracts.feature_registry"

## Every launcher card, Exit included, must be a plain product feature.
## The retired operator_launcher_card_* alias system is gone.
const EXPECTED_CARD_FEATURES := [
	"mode_teleop",
	"mode_ego_capture",
	"mode_live_feed",
	"mode_vr",
	"mode_exit",
]


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var defs := FeatureRegistry.definitions()
	t.eq(defs.size(), OperatorFeature.all_ids().size(),
		"registry must define every OperatorFeature id")

	var seen: Dictionary = {}
	var defined_ids: Dictionary = {}
	for def_v in defs:
		var def := def_v as FeatureDefinition
		t.is_false(seen.has(def.id), "duplicate definition for id %d" % def.id)
		seen[def.id] = true
		var id_string := OperatorFeature.id_to_string(def.id)
		defined_ids[id_string] = true
		t.eq(def.option, "operator_feature_%s" % id_string,
			"option name follows operator_feature_<id> for %s" % id_string)
		t.eq(def.runtime_tag, def.option, "runtime tag equals option name for %s" % id_string)

	# Every launcher card is a first-class feature (no legacy alias layer).
	for card_id in EXPECTED_CARD_FEATURES:
		t.is_true(defined_ids.has(card_id),
			"launcher card %s must be a registered feature" % card_id)

	# The Exit card ships enabled by default so dev/editor runs can leave.
	var exit_def := FeatureRegistry.definition_for(OperatorFeature.MODE_EXIT)
	t.is_true(exit_def != null, "mode_exit must have a definition")
	t.is_true(exit_def.default_value, "mode_exit defaults to enabled")

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
