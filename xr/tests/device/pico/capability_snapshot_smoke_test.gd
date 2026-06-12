extends RefCounted
## WP7 device smoke test (Pico): dump the REAL PlatformRegistry capability
## snapshot to JSON and assert the registry answers basic queries. This is
## a conformance probe — it must run on a real headset (never desktop).

const CASE_ID := "device.pico.capability_snapshot"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var registry := PlatformRegistry.create()
	var infos := registry.capabilities()
	t.is_true(infos.size() > 0, "platform registry must report capabilities")

	var snapshot: Array = []
	for info_v in infos:
		snapshot.append((info_v as CapabilityInfo).to_dict())
	var doc := {
		"device_kind": "pico",
		"os_name": OS.get_name(),
		"model_name": OS.get_model_name(),
		"capabilities": snapshot,
	}
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("user://test_results"))
	var path := "user://test_results/capability_snapshot_pico.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if t.is_true(file != null, "capability snapshot file must open"):
		file.store_string(JSON.stringify(doc, "  "))
		file.close()
		t.log_line("capability snapshot written: %s" % ProjectSettings.globalize_path(path))

	for cap_id in SensorCapability.all_ids():
		var info := registry.capability_info(cap_id)
		t.is_true(info != null, "capability_info must answer for %s"
			% SensorCapability.id_to_string(cap_id))
