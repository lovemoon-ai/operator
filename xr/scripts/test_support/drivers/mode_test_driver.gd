class_name ModeTestDriver
extends ModuleTestDriver
## v2 test harness (WP7): automation driver for app/modes composition.
## Composes a FeatureSet × FakeCapabilityRegistry and reports which product
## modules would be composed / degraded / absent — the 4-row truth table:
##   feature on  + capability on   -> composed
##   feature on  + capability off  -> degraded
##   feature off + capability *    -> absent
##
## No production scene is instantiated; this exercises the composition
## decision surface (FeatureRegistry definitions + capability gates).

# Mode/runtime capability requirements for the composition decision.
# FeatureDefinition.requires_capabilities covers feature-declared needs
# (e.g. robot_constraint -> ROBOT_CONTROL); this adds the per-mode sensor
# requirements the composition roots ask the platform for.
const MODE_CAPABILITY_REQUIREMENTS := {
	"mode_teleop": ["pose", "controller"],
	"mode_ego_capture": ["camera_rgb"],
	"mode_live_feed": ["camera_rgb", "live_stream_server"],
	"mode_pose_inference": ["pose", "hand_tracking", "qr_scan", "live_stream_server"],
	"mode_memworld": ["pose", "hand_tracking", "camera_rgb", "qr_scan", "live_stream_server"],
	"mode_vr": ["pose"],
	"sink_spatialmp4": ["spatial_mp4_mux"],
	"sink_live_stream": ["live_stream_server"],
}

var features: FeatureSet
var capability_registry: FakeCapabilityRegistry
var _composed: Array = []
var _degraded: Array = []
var _absent: Array = []


func module_id() -> String:
	return "app/modes"


func supported_cases() -> Array:
	return ["feature_composition", "capability_degradation"]


## Fixture: {"features": ["mode_ego_capture", ...] (enabled ids),
##           "capabilities": [...] (FakeCapabilityRegistry fixture form)}.
func setup(fixture: Dictionary) -> Dictionary:
	var enabled_ids: Array = []
	for name_v in fixture.get("features", []):
		var id := OperatorFeature.from_string(str(name_v))
		if id < 0:
			return {"ok": false, "error": "unknown feature '%s'" % str(name_v)}
		enabled_ids.append(id)
	features = FeatureSet.from_enabled_ids(enabled_ids)
	capability_registry = FakeCapabilityRegistry.from_fixture(fixture)
	_recompose()
	return {"ok": true}


func command(name: String, args: Dictionary = {}) -> Dictionary:
	match name:
		"set_capability_available":
			capability_registry.set_available(
				SensorCapability.from_string(str(args.get("capability", ""))))
			_recompose()
			return {"ok": true}
		"set_capability_unavailable":
			capability_registry.set_unavailable(
				SensorCapability.from_string(str(args.get("capability", ""))),
				str(args.get("reason", "test: unavailable")))
			_recompose()
			return {"ok": true}
		"recompose":
			_recompose()
			return {"ok": true}
	return {"ok": false, "error": "unknown command '%s'" % name}


func snapshot() -> Dictionary:
	return {
		"feature_set": _enabled_feature_names(),
		"capability_set": _available_capability_names(),
		"composed": _composed.duplicate(),
		"degraded": _degraded.duplicate(),
		"absent": _absent.duplicate(),
	}


func assert_invariants() -> Array:
	var out: Array = []
	# Disabled features must never be composed (or even degraded).
	for bucket in [_composed, _degraded]:
		for feature_name_v in bucket:
			var id := OperatorFeature.from_string(str(feature_name_v))
			if not features.enabled(id):
				out.append(OperatorTestFailure.create(
					"disabled_feature_composed",
					"disabled feature '%s' appeared in composition" % str(feature_name_v)))
	return out


func _recompose() -> void:
	_composed = []
	_degraded = []
	_absent = []
	for def_v in FeatureRegistry.definitions():
		var def := def_v as FeatureDefinition
		var feature_name := OperatorFeature.id_to_string(def.id)
		if not features.enabled(def.id):
			_absent.append(feature_name)
			continue
		var missing: Array = []
		for cap_name_v in def.requires_capabilities:
			if not _capability_available(str(cap_name_v)):
				missing.append(str(cap_name_v))
		for cap_name_v in MODE_CAPABILITY_REQUIREMENTS.get(feature_name, []):
			if not _capability_available(str(cap_name_v)):
				missing.append(str(cap_name_v))
		var deps_ok := true
		for required_id in def.requires_features:
			if not features.enabled(int(required_id)):
				deps_ok = false
		if missing.is_empty() and deps_ok:
			_composed.append(feature_name)
		else:
			_degraded.append(feature_name)


func _capability_available(capability_name: String) -> bool:
	var lowered := capability_name.to_lower()
	return capability_registry.has_capability(SensorCapability.from_string(lowered))


func _enabled_feature_names() -> Array:
	var out: Array = []
	for id in features.enabled_ids():
		out.append(OperatorFeature.id_to_string(id))
	return out


func _available_capability_names() -> Array:
	var out: Array = []
	for info_v in capability_registry.capabilities():
		var info := info_v as CapabilityInfo
		if info.available():
			out.append(SensorCapability.id_to_string(info.capability_id))
	out.sort()
	return out
