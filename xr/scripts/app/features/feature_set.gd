class_name FeatureSet
extends RefCounted

## Runtime view of the product features enabled in this APK / session.
##
## This is the ONLY app-level place allowed to call
## `OS.has_feature("operator_feature_*")`. All other modules should ask
## a FeatureSet instance instead.
##
## Resolution order in `from_export_tags()`:
## 1. APK exported with the `operator_features` plugin:
##    `operator_features_configured` tag present -> read each
##    `operator_feature_*` runtime tag.
## 2. Legacy APK exported with only the `operator_launcher` plugin:
##    `operator_launcher_cards_configured` present -> map the mode
##    features through their `launcher_card_alias`; non-mode features
##    fall back to registry defaults.
## 3. Editor / dev run: registry defaults, optionally overridden by a
##    gitignored `res://dev_features.cfg` ([features] section with
##    `<feature_id>=true/false` entries). Absence of the file means
##    plain defaults.
## 4. Explicit per-launch opt-ins are applied last. Currently
##    `operator.isaac_teleop=true` enables teleop + its IsaacTeleop sink.

const FEATURES_CONFIGURED_TAG := "operator_features_configured"
const LAUNCHER_CARDS_CONFIGURED_TAG := "operator_launcher_cards_configured"
const DEV_FEATURES_CFG_PATH := "res://dev_features.cfg"
const ISAAC_TELEOP_ARG_KEYS := ["operator.isaac_teleop", "operator_isaac_teleop"]
# Historical long-form aliases some builds shipped alongside the short
# card tags (kept for legacy-APK compatibility only).
const _EXTRA_CARD_ALIASES := {
	"operator_launcher_card_ego": ["operator_launcher_card_ego_capture"],
	"operator_launcher_card_live": ["operator_launcher_card_live_feed"],
}

# feature id (int) -> bool
var _enabled: Dictionary = {}


static func from_export_tags() -> FeatureSet:
	var feature_set := FeatureSet.new()
	var defs := FeatureRegistry.definitions()
	if OS.has_feature(FEATURES_CONFIGURED_TAG):
		for def in defs:
			feature_set._enabled[def.id] = OS.has_feature(def.runtime_tag)
		feature_set._apply_runtime_opt_ins(_runtime_args())
		return feature_set
	if OS.has_feature(LAUNCHER_CARDS_CONFIGURED_TAG):
		for def in defs:
			if def.launcher_card_alias.is_empty():
				feature_set._enabled[def.id] = def.default_value
			else:
				var card_enabled := OS.has_feature(def.launcher_card_alias)
				for extra in _EXTRA_CARD_ALIASES.get(def.launcher_card_alias, []):
					card_enabled = card_enabled or OS.has_feature(String(extra))
				feature_set._enabled[def.id] = card_enabled
		feature_set._apply_runtime_opt_ins(_runtime_args())
		return feature_set
	# Editor / dev fallback: registry defaults + optional overrides.
	for def in defs:
		feature_set._enabled[def.id] = def.default_value
	feature_set._apply_dev_overrides()
	feature_set._apply_runtime_opt_ins(_runtime_args())
	return feature_set


static func from_enabled_ids(ids: Array) -> FeatureSet:
	var feature_set := FeatureSet.new()
	for def in FeatureRegistry.definitions():
		feature_set._enabled[def.id] = ids.has(def.id)
	return feature_set


func enabled(id: int) -> bool:
	return bool(_enabled.get(id, false))


## Explicit runtime/test override. Returns false for an unknown feature id.
func set_enabled(id: int, value: bool) -> bool:
	if FeatureRegistry.definition_for(id) == null:
		return false
	_enabled[id] = value
	return true


## Apply supported opt-in arguments to this feature set. Public so the
## parser can be covered without depending on process-global OS arguments.
func apply_runtime_overrides(args: Array) -> void:
	_apply_runtime_opt_ins(args)


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


func _apply_runtime_opt_ins(args: Array) -> void:
	if not _isaac_teleop_requested(args):
		return
	# This is an explicit per-launch development entry point. Both features
	# are enabled together so the sink cannot be requested outside teleop.
	set_enabled(OperatorFeature.MODE_TELEOP, true)
	set_enabled(OperatorFeature.SINK_ISAAC_TELEOP, true)


static func _isaac_teleop_requested(args: Array) -> bool:
	var requested := false
	for i in range(args.size()):
		var arg := String(args[i]).strip_edges().trim_prefix("--")
		for key in ISAAC_TELEOP_ARG_KEYS:
			if arg == key and i + 1 < args.size():
				requested = _truthy(String(args[i + 1]))
			elif arg.begins_with(key + "="):
				requested = _truthy(arg.substr(key.length() + 1))
	return requested


static func _runtime_args() -> Array:
	var args: Array = []
	args.append_array(OS.get_cmdline_user_args())
	args.append_array(OS.get_cmdline_args())
	return args


static func _truthy(value: String) -> bool:
	return value.strip_edges().to_lower() in ["1", "true", "yes", "on"]
