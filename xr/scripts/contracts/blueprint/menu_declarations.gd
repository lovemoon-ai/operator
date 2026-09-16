extends RefCounted
## Data only. Used both by validation and by the system-menu compositor.
static func entries(spec: Dictionary, primitive: Dictionary) -> Array[Dictionary]:
	if str(primitive.get("host", "")) != "system_menu":
		return []
	var properties := {}
	for key in primitive["properties"]:
		var field: Dictionary = primitive["properties"][key]
		if field.has("default"):
			properties[key] = field["default"]
	properties.merge(spec.get("properties", {}), true)
	var bindings: Dictionary = spec.get("bindings", {})
	var result: Array[Dictionary] = []
	for event in primitive["events"]:
		var secondary: bool = event == "secondary_action"
		var action := str(properties.get("secondary_action" if secondary else "action", ""))
		if action.is_empty():
			continue
		result.append({
			"event": event, "item_key": str(properties.get("secondary_item_key" if secondary else "item_key", "")),
			"contract": {
				"action": action, "title": properties.get("title", ""),
				"off": properties.get("secondary_text", "") if secondary else properties.get("locked_text", ""),
				"on": properties.get("secondary_text", "") if secondary else properties.get("unlocked_text", ""),
				"unavailable": properties.get("secondary_text", "") if secondary else properties.get("unavailable_text", ""),
				"value_binding": "" if secondary else bindings.get("value", ""),
				"available_binding": bindings.get("secondary_available" if secondary else "available", ""),
				"available_default": not secondary,
				"visible_binding": bindings.get("visible", ""), "visible_default": properties.get("visible", true),
				"detail_binding": bindings.get("detail", ""),
				"user_overridable": spec.get("user_overridable", primitive.get("user_visibility_override", true)),
			},
		})
	return result
