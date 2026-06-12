class_name OperatorTestRegistry
extends RefCounted
## v2 test harness (WP7): central, data-driven registry.
## Loads feature test manifests from res://tests/manifests/features/,
## resolves fixtures from res://tests/fixtures/**, and maps module ids to
## ModuleTestDriver factories. Adding a module/test means adding data +
## a driver entry here — not editing a giant runner script.

const MANIFEST_DIR := "res://tests/manifests/features"
const FIXTURE_DIRS := [
	"res://tests/fixtures/sensors",
	"res://tests/fixtures/platform",
	"res://tests/fixtures/teleop",
	"res://tests/fixtures/capture",
	"res://tests/fixtures/pipeline",
	"res://tests/fixtures/storage",
]
# module_id -> driver script path (instantiated per case).
const DRIVER_SCRIPTS := {
	"core/capture": "res://scripts/test_support/drivers/capture_test_driver.gd",
	"core/teleop": "res://scripts/test_support/drivers/teleop_test_driver.gd",
	"app/modes": "res://scripts/test_support/drivers/mode_test_driver.gd",
}

var _manifests: Array = []  # Array[OperatorTestManifest]
var _loaded := false
var _load_errors: Array[String] = []


func load_manifests() -> Array:
	if _loaded:
		return _manifests
	_loaded = true
	var dir := DirAccess.open(MANIFEST_DIR)
	if dir == null:
		_load_errors.append("cannot open manifest dir %s" % MANIFEST_DIR)
		return _manifests
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var path := "%s/%s" % [MANIFEST_DIR, file_name]
			var parsed: Variant = _load_json(path)
			if typeof(parsed) != TYPE_DICTIONARY:
				_load_errors.append("manifest %s is not a JSON object" % path)
			else:
				var manifest := OperatorTestManifest.from_dict(parsed as Dictionary)
				for error in manifest.errors:
					_load_errors.append("%s: %s" % [path, error])
				_manifests.append(manifest)
		file_name = dir.get_next()
	dir.list_dir_end()
	return _manifests


func load_errors() -> Array[String]:
	load_manifests()
	return _load_errors


## All cases matching the optional suite / case filters ("" = any).
func cases(suite_filter := "", case_filter := "") -> Array:
	var out: Array = []
	for manifest_v in load_manifests():
		var manifest := manifest_v as OperatorTestManifest
		for case_v in manifest.cases:
			var test_case := case_v as OperatorTestCase
			if not suite_filter.is_empty() and suite_filter != "all" \
					and test_case.suite_id != suite_filter:
				continue
			if not case_filter.is_empty() and test_case.case_id != case_filter:
				continue
			out.append(test_case)
	return out


func suites() -> Array:
	var seen: Dictionary = {}
	for case_v in cases():
		seen[(case_v as OperatorTestCase).suite_id] = true
	var out := seen.keys()
	out.sort()
	return out


## Resolve a fixture id to its JSON dictionary (searched across the
## fixture dirs as <id>.json). Returns {} when not found or empty id.
func fixture(fixture_id: String) -> Dictionary:
	if fixture_id.is_empty():
		return {}
	for dir_path in FIXTURE_DIRS:
		var path := "%s/%s.json" % [dir_path, fixture_id]
		if FileAccess.file_exists(path):
			var parsed: Variant = _load_json(path)
			if typeof(parsed) == TYPE_DICTIONARY:
				return parsed as Dictionary
	push_warning("[OperatorTestRegistry] Fixture not found: %s" % fixture_id)
	return {}


## Instantiate the ModuleTestDriver for a module id (null when unmapped).
func create_driver(module_id: String) -> ModuleTestDriver:
	var script_path: String = DRIVER_SCRIPTS.get(module_id, "")
	if script_path.is_empty():
		return null
	var script: GDScript = load(script_path)
	if script == null:
		return null
	return script.new() as ModuleTestDriver


static func _load_json(path: String) -> Variant:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null
	return JSON.parse_string(text)
