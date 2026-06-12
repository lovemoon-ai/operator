class_name OperatorTestManifest
extends RefCounted
## v2 test harness (WP7): parsed feature test manifest. Schema:
## {id, feature, owner, required_features, required_capabilities,
##  test_cases:[{id, level, suite?, fixture?, script?, preset_matrix?,
##  required_device?}]}.

var id := ""
var feature := ""
var owner := ""
var required_features: Array = []
var required_capabilities: Array = []
var cases: Array = []  # Array[OperatorTestCase]
var errors: Array[String] = []


static func from_dict(d: Dictionary) -> OperatorTestManifest:
	var manifest := OperatorTestManifest.new()
	manifest.id = str(d.get("id", ""))
	manifest.feature = str(d.get("feature", ""))
	manifest.owner = str(d.get("owner", ""))
	manifest.required_features = d.get("required_features", [])
	manifest.required_capabilities = d.get("required_capabilities", [])
	if manifest.id.is_empty():
		manifest.errors.append("manifest missing 'id'")
	if manifest.feature != "operator_feature_%s" % manifest.id:
		manifest.errors.append(
			"manifest feature '%s' does not match id '%s'" % [manifest.feature, manifest.id])
	if OperatorFeature.from_string(manifest.id) < 0:
		manifest.errors.append("unknown feature id '%s'" % manifest.id)
	var cases_v: Variant = d.get("test_cases", [])
	if typeof(cases_v) != TYPE_ARRAY:
		manifest.errors.append("'test_cases' must be an array")
		return manifest
	for case_v in (cases_v as Array):
		if typeof(case_v) != TYPE_DICTIONARY:
			manifest.errors.append("test_cases entries must be objects")
			continue
		var test_case := OperatorTestCase.from_dict(
			case_v as Dictionary, manifest.feature, manifest.owner, manifest.id)
		if test_case.case_id.is_empty():
			manifest.errors.append("test case missing 'id'")
			continue
		if not OperatorTestCase.KNOWN_LEVELS.has(test_case.level):
			manifest.errors.append(
				"test case '%s' has unknown level '%s'" % [test_case.case_id, test_case.level])
		manifest.cases.append(test_case)
	return manifest
