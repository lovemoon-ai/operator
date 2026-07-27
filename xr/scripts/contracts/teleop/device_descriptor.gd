class_name DeviceDescriptorContract
extends RefCounted
## v2 contracts: validation/normalization for the v2 DeviceDescriptor payload
## received during the teleop handshake. Pure validation — the returned
## descriptor dict is the input dict (shape preserved) so existing consumers
## see exactly the bytes the robot sent.


## Returns {"descriptor": Dictionary, "errors": Array[String]}.
## `descriptor` is always the input dictionary unmodified (callers must keep
## emitting the original payload to stay wire-compatible); `errors` lists any
## contract violations for logging/diagnostics.
static func parse(d: Dictionary) -> Dictionary:
	var errors: Array[String] = []

	if d.has("descriptor_version"):
		var version: Variant = d.get("descriptor_version")
		if typeof(version) != TYPE_INT or int(version) < 1:
			errors.append("'descriptor_version' must be an integer >= 1")

	if d.has("execution"):
		var execution_v: Variant = d.get("execution")
		if typeof(execution_v) != TYPE_DICTIONARY:
			errors.append("'execution' must be an object")
		else:
			var execution := execution_v as Dictionary
			if str(execution.get("kind", "")) != "outside":
				errors.append("'execution.kind' from robot-service must be 'outside'")
			if not ["real", "simulation", "unknown"].has(
				str(execution.get("environment", "unknown"))
			):
				errors.append("'execution.environment' must be real, simulation, or unknown")

	var device_v: Variant = d.get("device")
	if typeof(device_v) != TYPE_DICTIONARY:
		errors.append("missing or invalid 'device' object")
	else:
		var device := device_v as Dictionary
		if str(device.get("name", "")).is_empty():
			errors.append("missing 'device.name'")

	var schema_v: Variant = d.get("control_schema")
	if typeof(schema_v) == TYPE_DICTIONARY:
		var schema := schema_v as Dictionary
		if schema.has("axes") and typeof(schema.get("axes")) != TYPE_ARRAY:
			errors.append("'control_schema.axes' must be an array")
		if schema.has("buttons") and typeof(schema.get("buttons")) != TYPE_ARRAY:
			errors.append("'control_schema.buttons' must be an array")
	elif d.has("control_schema"):
		errors.append("'control_schema' must be an object")

	var mapping_v: Variant = d.get("input_mapping")
	if typeof(mapping_v) == TYPE_ARRAY:
		var index := 0
		for entry_v in mapping_v as Array:
			if typeof(entry_v) != TYPE_DICTIONARY:
				errors.append("input_mapping[%d] must be an object" % index)
				index += 1
				continue
			var entry := entry_v as Dictionary
			if str(entry.get("source", "")).is_empty():
				errors.append("input_mapping[%d] missing 'source'" % index)
			if str(entry.get("target", "")).is_empty():
				errors.append("input_mapping[%d] missing 'target'" % index)
			for numeric_key in ["scale", "offset"]:
				if entry.has(numeric_key):
					var value: Variant = entry.get(numeric_key)
					if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
						errors.append(
							"input_mapping[%d].%s must be a number" % [index, numeric_key]
						)
			if entry.has("invert") and typeof(entry.get("invert")) != TYPE_BOOL:
				errors.append("input_mapping[%d].invert must be a bool" % index)
			index += 1
	elif d.has("input_mapping"):
		errors.append("'input_mapping' must be an array")

	var input_contract_v: Variant = d.get("input_contract")
	if typeof(input_contract_v) == TYPE_DICTIONARY:
		var channels_v: Variant = (input_contract_v as Dictionary).get("channels", [])
		if typeof(channels_v) != TYPE_ARRAY:
			errors.append("'input_contract.channels' must be an array")
		else:
			var channel_index := 0
			for channel_v in channels_v as Array:
				if typeof(channel_v) != TYPE_DICTIONARY:
					errors.append("input_contract.channels[%d] must be an object" % channel_index)
				else:
					var channel := channel_v as Dictionary
					if str(channel.get("name", "")).is_empty():
						errors.append("input_contract.channels[%d] missing 'name'" % channel_index)
					if str(channel.get("type", "")).is_empty():
						errors.append("input_contract.channels[%d] missing 'type'" % channel_index)
				channel_index += 1
	elif d.has("input_contract"):
		errors.append("'input_contract' must be an object")

	return {"descriptor": d, "errors": errors}
