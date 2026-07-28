class_name FeatureDefinition
extends RefCounted

## Metadata for one `operator_feature_*` product feature.
##
## `option` is the export-preset option name and `runtime_tag` is the
## runtime feature tag; both are `operator_feature_<id>` by convention.

var id: int = -1
var option: String = ""
var runtime_tag: String = ""
var default_value: bool = false
var owner: String = ""
var requires_features: Array[int] = []
var conflicts: Array[int] = []
var requires_capabilities: Array[String] = []


static func create(
		feature_id: int,
		feature_default: bool,
		feature_owner: String,
		requires: Array[int] = [],
		conflicting: Array[int] = [],
		capabilities: Array[String] = []
) -> FeatureDefinition:
	var def := FeatureDefinition.new()
	def.id = feature_id
	var id_string := OperatorFeature.id_to_string(feature_id)
	def.option = "operator_feature_%s" % id_string
	def.runtime_tag = def.option
	def.default_value = feature_default
	def.owner = feature_owner
	def.requires_features = requires
	def.conflicts = conflicting
	def.requires_capabilities = capabilities
	return def
