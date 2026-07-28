class_name FeatureRegistry

## Canonical table of all `operator_feature_*` definitions.
##
## NOTE: `xr/addons/operator_features/export_plugin.gd` duplicates this
## name/default table in its `FEATURE_OPTIONS` const (a @tool export
## plugin must not preload runtime scripts). Keep the two tables in
## sync; `tests/validate_xr_features.py` cross-checks them.


static func definitions() -> Array[FeatureDefinition]:
	var defs: Array[FeatureDefinition] = []
	var robot_constraint_requires: Array[int] = [OperatorFeature.ROBOT_CONTROL]
	defs.append(FeatureDefinition.create(
		OperatorFeature.MODE_TELEOP, false, "app/modes"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.MODE_EGO_CAPTURE, true, "app/modes"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.MODE_LIVE_FEED, false, "app/modes"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.MODE_VR, false, "app/modes"))
	# The Exit card quits the app rather than opening a scene, but it is
	# still a launcher card and follows the same on/off contract.
	defs.append(FeatureDefinition.create(
		OperatorFeature.MODE_EXIT, true, "app/modes"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.SINK_SPATIALMP4, true, "sinks/spatialmp4"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.SINK_LIVE_STREAM, false, "sinks/live_stream"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.SINK_UPLOAD, true, "sinks/upload"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.ROBOT_CONTROL, false, "core/teleop"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.ROBOT_CONSTRAINT, false, "core/teleop",
		robot_constraint_requires, [], ["ROBOT_CONTROL"]))
	defs.append(FeatureDefinition.create(
		OperatorFeature.DEBUG_METRICS, false, "app/debug"))
	defs.append(FeatureDefinition.create(
		OperatorFeature.TEST_HARNESS, false, "test_support"))
	return defs


static func definition_for(id: int) -> FeatureDefinition:
	for def in definitions():
		if def.id == id:
			return def
	return null


## Validate an `enabled` map of feature id (int) -> bool against
## dependency and conflict rules. Returns a list of error strings
## (empty when valid).
static func validate(enabled: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	for def in definitions():
		if not bool(enabled.get(def.id, false)):
			continue
		for required_id in def.requires_features:
			if not bool(enabled.get(required_id, false)):
				errors.append("%s requires %s" % [
					def.option,
					"operator_feature_%s" % OperatorFeature.id_to_string(required_id),
				])
		for conflict_id in def.conflicts:
			if bool(enabled.get(conflict_id, false)):
				errors.append("%s conflicts with %s" % [
					def.option,
					"operator_feature_%s" % OperatorFeature.id_to_string(conflict_id),
				])
	return errors
