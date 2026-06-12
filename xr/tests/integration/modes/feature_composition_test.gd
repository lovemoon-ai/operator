extends RefCounted
## WP7 integration test (generic, data-driven): feature × capability
## composition truth table for the feature this case is attached to:
##   feature enabled + capability available    -> composed
##   feature enabled + capability unavailable  -> degraded (if it needs any)
##   feature disabled + capability available   -> absent
##   feature disabled + capability unavailable -> absent
## The feature id comes from ctx.case (manifest), so one script covers all
## operator_feature_* composition cases.

const CASE_ID := "modes.feature_composition"


func run(ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var test_case: OperatorTestCase = ctx.get("case")
	var feature_name := OperatorFeature.id_to_string(
		OperatorFeature.from_string(test_case.feature if test_case != null else "mode_ego_capture"))
	if not t.is_true(not feature_name.is_empty(), "case must map to a known feature"):
		return
	var def := FeatureRegistry.definition_for(OperatorFeature.from_string(feature_name))

	# Enabled feature set = this feature + its declared feature dependencies.
	var enabled_features: Array = [feature_name]
	for required_id in def.requires_features:
		enabled_features.append(OperatorFeature.id_to_string(int(required_id)))

	var all_caps: Array = []
	for cap_id in SensorCapability.all_ids():
		all_caps.append(SensorCapability.id_to_string(cap_id))

	var needs_capabilities: bool = not def.requires_capabilities.is_empty() \
		or ModeTestDriver.MODE_CAPABILITY_REQUIREMENTS.has(feature_name)

	# Row 1: enabled + all capabilities -> composed.
	var driver := ModeTestDriver.new()
	driver.setup({"features": enabled_features, "capabilities": all_caps})
	var snap := driver.snapshot()
	t.contains(snap.get("composed", []), feature_name,
		"enabled feature with capabilities must be composed")
	t.merge_failures(driver.assert_invariants())

	# Row 2: enabled + no capabilities -> degraded (when it needs any),
	# never absent, never a crash.
	driver = ModeTestDriver.new()
	driver.setup({"features": enabled_features, "capabilities": []})
	snap = driver.snapshot()
	if needs_capabilities:
		t.contains(snap.get("degraded", []), feature_name,
			"enabled feature without capabilities must be degraded")
	else:
		t.contains(snap.get("composed", []), feature_name,
			"capability-free feature composes regardless of platform")
	t.is_false((snap.get("absent", []) as Array).has(feature_name),
		"enabled feature must never be reported absent")
	t.merge_failures(driver.assert_invariants())

	# Rows 3+4: disabled -> absent with and without capabilities.
	for caps in [all_caps, []]:
		driver = ModeTestDriver.new()
		driver.setup({"features": [], "capabilities": caps})
		snap = driver.snapshot()
		t.contains(snap.get("absent", []), feature_name,
			"disabled feature must stay absent (caps=%d)" % (caps as Array).size())
		t.is_false((snap.get("composed", []) as Array).has(feature_name),
			"disabled feature must not be composed")
		t.merge_failures(driver.assert_invariants())

	# Optional platform fixture row: composing against the fixture's
	# capability profile must yield composed-or-degraded, never absent.
	var fixture: Dictionary = ctx.get("fixture", {})
	if not fixture.is_empty():
		driver = ModeTestDriver.new()
		driver.setup({
			"features": enabled_features,
			"capabilities": fixture.get("capabilities", []),
		})
		snap = driver.snapshot()
		t.is_false((snap.get("absent", []) as Array).has(feature_name),
			"fixture platform: enabled feature must be composed or degraded")
		t.merge_failures(driver.assert_invariants())
