class_name OperatorTestCase
extends RefCounted
## v2 test harness (WP7): one runnable (or statically validated) test case,
## parsed from a feature test manifest (xr/tests/manifests/features/*.json).

const LEVEL_STATIC := "static"
const LEVEL_CONTRACT := "contract"
const LEVEL_UNIT := "unit"
const LEVEL_INTEGRATION := "integration"
const LEVEL_DEVICE := "device"
const LEVEL_E2E := "e2e"

const KNOWN_LEVELS := [
	LEVEL_STATIC, LEVEL_CONTRACT, LEVEL_UNIT,
	LEVEL_INTEGRATION, LEVEL_DEVICE, LEVEL_E2E,
]

var suite_id := ""
var case_id := ""
var module_id := ""
var feature := ""  # operator_feature_* option name
var feature_ids: Array = []
var level := ""
var fixture_id := ""
var script_path := ""
var preset_matrix := false
var required_device := ""


static func from_dict(d: Dictionary, manifest_feature: String, manifest_owner: String, default_suite: String) -> OperatorTestCase:
	var test_case := OperatorTestCase.new()
	test_case.case_id = str(d.get("id", ""))
	test_case.suite_id = str(d.get("suite", default_suite))
	test_case.module_id = str(d.get("module", manifest_owner))
	test_case.feature = manifest_feature
	test_case.feature_ids = [manifest_feature]
	test_case.level = str(d.get("level", ""))
	test_case.fixture_id = str(d.get("fixture", ""))
	test_case.script_path = str(d.get("script", ""))
	test_case.preset_matrix = bool(d.get("preset_matrix", false))
	test_case.required_device = str(d.get("required_device", ""))
	return test_case


## Whether this case can execute inside the Godot runtime (has a script).
## Static / preset-matrix cases are owned by host-side validators.
func runnable() -> bool:
	return not script_path.is_empty() and level != LEVEL_STATIC
