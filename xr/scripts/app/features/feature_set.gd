class_name FeatureSet
extends RefCounted

## Runtime view of the product features enabled in this APK / session.
##
## This is the ONLY app-level place allowed to call
## `OS.has_feature("operator_feature_*")`. All other modules should ask
## a FeatureSet instance instead.
##
## Resolution order in `from_export_tags()`:
## 1. Exported APK: the `operator_features` plugin always emits the
##    `operator_features_configured` tag, so its presence means "read
##    each `operator_feature_*` runtime tag".
## 2. Editor / dev run: registry defaults, optionally overridden by a
##    gitignored `res://dev_features.cfg` ([features] section with
##    `<feature_id>=true/false` entries). Absence of the file means
##    plain defaults.

const FEATURES_CONFIGURED_TAG := "operator_features_configured"
const DEV_FEATURES_CFG_PATH := "res://dev_features.cfg"

# feature id (int) -> bool
var _enabled: Dictionary = {}


static func from_export_tags() -> FeatureSet:
	var feature_set := FeatureSet.new()
	var defs := FeatureRegistry.definitions()
	if OS.has_feature(FEATURES_CONFIGURED_TAG):
		for def in defs:
			feature_set._enabled[def.id] = OS.has_feature(def.runtime_tag)
		return feature_set
	# Editor / dev fallback: registry defaults + optional overrides.
	for def in defs:
		feature_set._enabled[def.id] = def.default_value
	feature_set._apply_dev_overrides()
	return feature_set


static func from_enabled_ids(ids: Array) -> FeatureSet:
	var feature_set := FeatureSet.new()
	for def in FeatureRegistry.definitions():
		feature_set._enabled[def.id] = ids.has(def.id)
	return feature_set


func enabled(id: int) -> bool:
	return bool(_enabled.get(id, false))


func enabled_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in _enabled.keys():
		if bool(_enabled[id]):
			ids.append(int(id))
	ids.sort()
	return ids


func validate() -> Array[String]:
	return FeatureRegistry.validate(_enabled)


func _apply_dev_overrides() -> void:
	if not FileAccess.file_exists(DEV_FEATURES_CFG_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(DEV_FEATURES_CFG_PATH) != OK:
		push_warning("[FeatureSet] Failed to parse %s; using defaults" % DEV_FEATURES_CFG_PATH)
		return
	if not cfg.has_section("features"):
		return
	for key in cfg.get_section_keys("features"):
		var id := OperatorFeature.from_string(String(key))
		if id < 0:
			push_warning("[FeatureSet] Unknown feature '%s' in %s" % [key, DEV_FEATURES_CFG_PATH])
			continue
		_enabled[id] = bool(cfg.get_value("features", key, false))
