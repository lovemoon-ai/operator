class_name BlueprintContract
extends RefCounted

const BLUEPRINT_SCHEMA := BlueprintPrimitiveSpec.BLUEPRINT_SCHEMA
const STATE_SCHEMA := BlueprintPrimitiveSpec.STATE_SCHEMA
const EVENT_SCHEMA := BlueprintPrimitiveSpec.EVENT_SCHEMA
const MAX_COMPONENTS := BlueprintPrimitiveSpec.MAX_COMPONENTS
const MAX_STATE_VALUES := BlueprintPrimitiveSpec.MAX_STATE_VALUES
const PRIMITIVES := BlueprintPrimitiveSpec.PRIMITIVES


static func parse_blueprint(value: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	if value.get("schema") != BLUEPRINT_SCHEMA:
		errors.append("unsupported Blueprint schema")
	if not _is_nonempty_string(value.get("blueprint_id")):
		errors.append("blueprint_id must not be empty")
	if not _is_positive_wire_integer(value.get("revision")):
		errors.append("revision must be greater than zero")
	var components_v: Variant = value.get("components", [])
	if not components_v is Array:
		errors.append("components must be an array")
		return {"blueprint": value, "errors": errors}
	var components := components_v as Array
	if components.size() > MAX_COMPONENTS:
		errors.append("component limit exceeded")
	var ids := {}
	var singleton_types := {}
	var binding_contracts := {}
	for component_v in components:
		if not component_v is Dictionary:
			errors.append("every component must be an object")
			continue
		_validate_component(
			component_v as Dictionary,
			ids,
			singleton_types,
			binding_contracts,
			errors,
		)
	if errors.is_empty():
		var shared := {}
		for component_v in components:
			var component: Dictionary = component_v
			for item in preload("res://scripts/contracts/blueprint/menu_declarations.gd").entries(component, primitive(str(component["type"]))):
				var key: String = item["item_key"]
				if key.is_empty():
					continue
				if shared.has(key) and shared[key] != item["contract"]:
					errors.append("conflicting shared menu item: %s" % key)
				shared[key] = item["contract"]
	return {"blueprint": value, "errors": errors}


static func parse_state(value: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	if value.get("schema") != STATE_SCHEMA:
		errors.append("unsupported BlueprintState schema")
	if not _is_nonempty_string(value.get("blueprint_id")):
		errors.append("state blueprint_id must not be empty")
	if not _is_positive_wire_integer(value.get("blueprint_revision")):
		errors.append("state blueprint_revision must be greater than zero")
	if not _is_positive_wire_integer(value.get("sequence")):
		errors.append("state sequence must be greater than zero")
	if not _is_nonnegative_wire_integer(value.get("timestamp_ns")):
		errors.append("state timestamp_ns must be a non-negative integer")
	var values_v: Variant = value.get("values", {})
	if not values_v is Dictionary:
		errors.append("state values must be an object")
	elif (values_v as Dictionary).size() > MAX_STATE_VALUES:
		errors.append("state value limit exceeded")
	else:
		for key_v in values_v as Dictionary:
			if not _is_nonempty_string(key_v):
				errors.append("state keys must be non-empty strings")
	return {"state": value, "errors": errors}


static func parse_event(value: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	if value.get("schema") != EVENT_SCHEMA:
		errors.append("unsupported BlueprintEvent schema")
	for key in ["blueprint_id", "component_id", "action"]:
		if not _is_nonempty_string(value.get(key)):
			errors.append("event %s must not be empty" % key)
	if not _is_positive_wire_integer(value.get("blueprint_revision")):
		errors.append("event blueprint_revision must be greater than zero")
	if not _is_positive_wire_integer(value.get("sequence")):
		errors.append("event sequence must be greater than zero")
	if not _is_nonnegative_wire_integer(value.get("timestamp_ns")):
		errors.append("event timestamp_ns must be a non-negative integer")
	return {"event": value, "errors": errors}


static func primitive(component_type: String) -> Dictionary:
	var primitive_v: Variant = PRIMITIVES.get(component_type, {})
	return primitive_v as Dictionary if primitive_v is Dictionary else {}


static func external_view_types() -> Array[String]:
	var result: Array[String] = []
	for component_type_v in PRIMITIVES:
		var component_type := str(component_type_v)
		if str(primitive(component_type).get("host", "")) == "external_view":
			result.append(component_type)
	return result


static func resolved_properties(component: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var primitive_spec := primitive(str(component.get("type", "")))
	var property_specs_v: Variant = primitive_spec.get("properties", {})
	if property_specs_v is Dictionary:
		var property_specs := property_specs_v as Dictionary
		for name_v in property_specs:
			var field_spec := property_specs[name_v] as Dictionary
			if field_spec.has("default"):
				result[name_v] = field_spec["default"]
	var properties_v: Variant = component.get("properties", {})
	if properties_v is Dictionary:
		result.merge(properties_v as Dictionary, true)
	return result


static func resolved_anchor(component: Dictionary) -> String:
	var primitive_spec := primitive(str(component.get("type", "")))
	return str(component.get("anchor", primitive_spec.get("default_anchor", "world")))


static func resolved_transform(component: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for field_v in BlueprintPrimitiveSpec.TRANSFORM:
		var field := str(field_v)
		var field_spec := BlueprintPrimitiveSpec.TRANSFORM[field_v] as Dictionary
		result[field] = (field_spec.get("default", []) as Array).duplicate()
	var transform_v: Variant = component.get("transform", {})
	if transform_v is Dictionary:
		result.merge(transform_v as Dictionary, true)
	return result


static func user_visibility_overridable(component: Dictionary) -> bool:
	var primitive_spec := primitive(str(component.get("type", "")))
	var supported := bool(primitive_spec.get("user_visibility_override", false))
	return supported and bool(component.get("user_overridable", supported))


static func binding_with_semantics(component_type: String, semantics: String) -> String:
	var bindings_v: Variant = primitive(component_type).get("bindings", {})
	if not bindings_v is Dictionary:
		return ""
	for binding_name_v in bindings_v as Dictionary:
		var field_spec_v: Variant = (bindings_v as Dictionary)[binding_name_v]
		if field_spec_v is Dictionary \
				and str((field_spec_v as Dictionary).get("semantics", "")) == semantics:
			return str(binding_name_v)
	return ""


static func value_matches_type(value: Variant, value_type: String) -> bool:
	match value_type:
		"boolean":
			return value is bool
		"string":
			return value is String
		"integer":
			return _is_integer_value(value)
		"number":
			return _is_finite_number(value)
		"color":
			if _is_color_string(value):
				return true
			if value is Array:
				var channels := value as Array
				return channels.size() in [3, 4] and channels.all(
					func(channel: Variant) -> bool: return _is_finite_number(channel)
				)
			return false
		"color_map":
			if not value is Dictionary:
				return false
			return (value as Dictionary).values().all(
				func(color: Variant) -> bool: return value_matches_type(color, "color")
			)
		"number_array":
			return value is Array and (value as Array).all(
				func(item: Variant) -> bool: return _is_finite_number(item)
			)
		"string_array":
			return value is Array and (value as Array).all(
				func(item: Variant) -> bool: return item is String
			)
		"integer_array":
			return value is Array and (value as Array).all(
				func(item: Variant) -> bool: return _is_integer_value(item)
			)
	return false


static func wire_integer_matches_type(value: Variant) -> bool:
	return _is_wire_integer(value)


static func _is_wire_integer(value: Variant) -> bool:
	return (
		value is int
		and int(value) >= 0
		and int(value) <= BlueprintPrimitiveSpec.MAX_WIRE_INTEGER
	)


static func _is_integer_value(value: Variant) -> bool:
	if not _is_finite_number(value):
		return false
	var number := float(value)
	return number == floorf(number)


static func _is_color_string(value: Variant) -> bool:
	if not value is String:
		return false
	var text := value as String
	if text.length() not in [4, 5, 7, 9] or not text.begins_with("#"):
		return false
	for index in range(1, text.length()):
		var code := text.unicode_at(index)
		if not (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 70)
			or (code >= 97 and code <= 102)
		):
			return false
	return true


static func _is_finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _is_positive_wire_integer(value: Variant) -> bool:
	return _is_wire_integer(value) and int(value) > 0


static func _is_nonnegative_wire_integer(value: Variant) -> bool:
	return _is_wire_integer(value)


static func _is_nonempty_string(value: Variant) -> bool:
	return value is String and not (value as String).strip_edges().is_empty()


static func _field_value_error(value: Variant, field_spec: Dictionary) -> String:
	var value_type := str(field_spec.get("type", ""))
	if not value_matches_type(value, value_type):
		return "invalid type"
	if _is_finite_number(value):
		var number := float(value)
		if field_spec.has("minimum") and number < float(field_spec["minimum"]):
			return "below minimum"
		if field_spec.has("maximum") and number > float(field_spec["maximum"]):
			return "above maximum"
	if field_spec.has("length"):
		if not value is Array or (value as Array).size() != int(field_spec["length"]):
			return "invalid length"
	if field_spec.has("max_length"):
		if not value is Array or (value as Array).size() > int(field_spec["max_length"]):
			return "too many items"
	return ""


static func compile_binding_contracts(components: Array) -> Dictionary:
	var binding_contracts: Dictionary = {}
	for component_v in components:
		if not component_v is Dictionary:
			continue
		var component := component_v as Dictionary
		var primitive_spec := primitive(str(component.get("type", "")))
		var binding_specs := primitive_spec.get("bindings", {}) as Dictionary
		var bindings_v: Variant = component.get("bindings", {})
		if not bindings_v is Dictionary:
			continue
		var bindings := bindings_v as Dictionary
		for property_v in bindings:
			var state_key := str(bindings[property_v])
			if not binding_specs.has(property_v):
				continue
			var field_spec := binding_specs[property_v] as Dictionary
			var value_contract := field_spec.duplicate(true)
			value_contract.erase("required")
			value_contract.erase("semantics")
			binding_contracts[state_key] = value_contract
	return binding_contracts


static func validate_bound_values(
	components: Array,
	values: Dictionary,
	compiled_contracts: Variant = null,
) -> Array[String]:
	var errors: Array[String] = []
	var binding_contracts: Dictionary = (
		compiled_contracts as Dictionary
		if compiled_contracts is Dictionary
		else compile_binding_contracts(components)
	)
	for state_key_v in values:
		var state_key := str(state_key_v)
		if not binding_contracts.has(state_key):
			errors.append("state value %s is not bound" % state_key)
			continue
		var value_error := _field_value_error(
			values[state_key_v], binding_contracts[state_key] as Dictionary
		)
		if not value_error.is_empty():
			errors.append(
				"state value %s has %s" % [state_key, value_error]
			)
	return errors


static func _validate_component(
	component: Dictionary,
	ids: Dictionary,
	singleton_types: Dictionary,
	binding_contracts: Dictionary,
	errors: Array[String],
) -> void:
	var component_id_v: Variant = component.get("id")
	var component_id := component_id_v as String if component_id_v is String else ""
	if not _is_nonempty_string(component_id_v):
		errors.append("component id must not be empty")
	elif ids.has(component_id):
		errors.append("duplicate component id: %s" % component_id)
	else:
		ids[component_id] = true
	var component_type_v: Variant = component.get("type")
	var component_type := component_type_v as String if component_type_v is String else ""
	var primitive_spec := primitive(component_type)
	if primitive_spec.is_empty():
		errors.append("unsupported component type: %s" % component_type)
		return
	if bool(primitive_spec.get("singleton", false)):
		if singleton_types.has(component_type):
			errors.append("duplicate singleton primitive type: %s" % component_type)
		else:
			singleton_types[component_type] = true
	var user_overridable_v: Variant = component.get(
		"user_overridable", primitive_spec.get("user_visibility_override", false)
	)
	if not user_overridable_v is bool:
		errors.append("component user_overridable must be boolean")
	elif bool(user_overridable_v) and not bool(
		primitive_spec.get("user_visibility_override", false)
	):
		errors.append("component type does not support headset visibility overrides")
	var anchor_v: Variant = component.get("anchor", primitive_spec.get("default_anchor", "world"))
	if not anchor_v is String:
		errors.append("component anchor must be a string")
	var anchors_v: Variant = primitive_spec.get("anchors", [])
	if not anchors_v is Array or not (anchors_v as Array).has(
		resolved_anchor(component)
	):
		errors.append("unsupported component anchor: %s" % str(component.get("anchor", "")))
	_validate_fields(component, primitive_spec, "properties", errors)
	_validate_bindings(component, primitive_spec, binding_contracts, errors)
	_validate_transform(component.get("transform", {}), component_id, errors)


static func _validate_fields(
	component: Dictionary,
	primitive_spec: Dictionary,
	field_name: String,
	errors: Array[String],
) -> void:
	var values_v: Variant = component.get(field_name, {})
	if not values_v is Dictionary:
		errors.append("component %s must be an object" % field_name)
		return
	var values := values_v as Dictionary
	var field_specs := primitive_spec.get(field_name, {}) as Dictionary
	for name_v in values:
		if not name_v is String or (name_v as String).strip_edges().is_empty():
			errors.append("%s names must be non-empty strings" % field_name.trim_suffix("s"))
			continue
		var name := name_v as String
		if not field_specs.has(name):
			errors.append("unsupported %s %s" % [field_name.trim_suffix("s"), name])
			continue
		var field_spec := field_specs[name] as Dictionary
		var value_error := _field_value_error(values[name_v], field_spec)
		if not value_error.is_empty():
			errors.append("%s %s has %s" % [field_name.trim_suffix("s"), name, value_error])
	for name_v in field_specs:
		var field_spec := field_specs[name_v] as Dictionary
		if bool(field_spec.get("required", false)) and not values.has(name_v):
			errors.append("required %s %s is missing" % [field_name.trim_suffix("s"), name_v])


static func _validate_bindings(
	component: Dictionary,
	primitive_spec: Dictionary,
	binding_contracts: Dictionary,
	errors: Array[String],
) -> void:
	var bindings_v: Variant = component.get("bindings", {})
	if not bindings_v is Dictionary:
		errors.append("component bindings must be an object")
		return
	var bindings := bindings_v as Dictionary
	var binding_specs := primitive_spec.get("bindings", {}) as Dictionary
	for name_v in bindings:
		if not name_v is String or (name_v as String).strip_edges().is_empty():
			errors.append("binding names must be non-empty strings")
			continue
		if not binding_specs.has(name_v):
			errors.append("unsupported binding %s" % name_v)
			continue
		if not _is_nonempty_string(bindings[name_v]):
			errors.append("binding %s must reference a non-empty state key" % name_v)
			continue
		var state_key := bindings[name_v] as String
		var value_contract := (binding_specs[name_v] as Dictionary).duplicate(true)
		value_contract.erase("required")
		value_contract.erase("semantics")
		if binding_contracts.has(state_key) and binding_contracts[state_key] != value_contract:
			errors.append("state key %s has conflicting contracts" % state_key)
		else:
			binding_contracts[state_key] = value_contract
	for name_v in binding_specs:
		var field_spec := binding_specs[name_v] as Dictionary
		if bool(field_spec.get("required", false)) and not bindings.has(name_v):
			errors.append("required binding %s is missing" % name_v)
	var complete_groups := 0
	var groups_v: Variant = primitive_spec.get("binding_groups", {})
	if groups_v is Dictionary:
		for group_name_v in (groups_v as Dictionary):
			var members := (groups_v as Dictionary)[group_name_v] as Array
			var present := members.filter(func(member: Variant) -> bool: return bindings.has(member))
			if not present.is_empty() and present.size() != members.size():
				errors.append("binding group %s must be complete" % group_name_v)
			elif present.size() == members.size():
				complete_groups += 1
	if (
		bool((primitive_spec.get("constraints", {}) as Dictionary).get(
			"at_least_one_complete_binding_group", false
		))
		and complete_groups == 0
	):
		errors.append("at least one complete binding group is required")


static func _validate_transform(
	transform_v: Variant,
	component_id: String,
	errors: Array[String],
) -> void:
	if not transform_v is Dictionary:
		errors.append("component %s transform must be an object" % component_id)
		return
	var transform := transform_v as Dictionary
	var parsed: Dictionary = {}
	for field in ["position", "rotation", "scale"]:
		if not transform.has(field):
			continue
		var values_v: Variant = transform[field]
		var expected_size := 4 if field == "rotation" else 3
		if not values_v is Array or (values_v as Array).size() != expected_size:
			errors.append("component %s transform %s has invalid dimensions" % [component_id, field])
			continue
		var values := values_v as Array
		parsed[field] = values
		var numbers_valid := true
		for number_v in values:
			if not _is_finite_number(number_v):
				errors.append("component %s transform %s must contain numbers" % [component_id, field])
				numbers_valid = false
		if numbers_valid and field == "scale" and values.any(
			func(number_v: Variant) -> bool: return float(number_v) <= 0.0
		):
			errors.append("component %s transform scale must be positive" % component_id)
	if parsed.has("rotation") and (parsed["rotation"] as Array).all(
		func(number_v: Variant) -> bool: return _is_finite_number(number_v)
	):
		var rotation_norm_squared := 0.0
		for number_v in parsed["rotation"] as Array:
			rotation_norm_squared += float(number_v) * float(number_v)
		if rotation_norm_squared <= 0.000000000001:
			errors.append("component %s transform rotation must be non-zero" % component_id)
