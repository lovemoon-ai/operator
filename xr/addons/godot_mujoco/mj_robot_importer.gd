class_name MjRobotImporter
extends RefCounted

const _XML_TAG_PATTERN := "<%s\\b[^>]*"


static func import_model(path: String) -> MjModelResource:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("[GodotMuJoCo] Failed to read model: %s" % path)
		return MjModelResource.new()
	var extension := path.get_extension().to_lower()
	if extension == "urdf":
		return import_urdf_text(text, path)
	return import_mjcf_text(text, path)


static func import_mjcf_text(text: String, path := "") -> MjModelResource:
	var model := MjModelResource.new()
	model.source_path = path
	model.source_format = "mjcf"
	model.robot_name = _first_attr(text, "mujoco", "model", path.get_file().get_basename())
	model.body_names = _names_for_tag(text, "body")
	if not model.body_names.has("world"):
		model.body_names.insert(0, "world")
	model.joint_names = _names_for_tag(text, "joint")
	for freejoint_name in _names_for_tag(text, "freejoint"):
		model.joint_names.append(freejoint_name)
	model.actuator_names = _actuator_names(text)
	model.geom_names = _names_for_tag(text, "geom")
	model.sensor_names = _sensor_names(text)
	model.stable_ids = _stable_ids(model)
	model.metadata = {"importer": "mjcf", "source_bytes": text.length()}
	return model


static func import_urdf_text(text: String, path := "") -> MjModelResource:
	var model := MjModelResource.new()
	model.source_path = path
	model.source_format = "urdf"
	model.robot_name = _first_attr(text, "robot", "name", path.get_file().get_basename())
	model.body_names = _names_for_tag(text, "link")
	model.joint_names = _names_for_tag(text, "joint")
	model.actuator_names = PackedStringArray()
	for joint_name in model.joint_names:
		model.actuator_names.append("%s_target" % joint_name)
	model.geom_names = PackedStringArray()
	for body_name in model.body_names:
		model.geom_names.append("%s_visual" % body_name)
	model.sensor_names = PackedStringArray(["joint_state", "contact", "force"])
	model.stable_ids = _stable_ids(model)
	model.metadata = {"importer": "urdf", "source_bytes": text.length(), "converted_to": "runtime_proxy"}
	return model


static func _names_for_tag(text: String, tag: String) -> PackedStringArray:
	var names := PackedStringArray()
	var regex := RegEx.new()
	regex.compile(_XML_TAG_PATTERN % tag)
	for result in regex.search_all(text):
		var fragment := result.get_string()
		var name := _attr(fragment, "name", "")
		if name.is_empty():
			name = "%s_%03d" % [tag, names.size()]
		if not names.has(name):
			names.append(name)
	return names


static func _actuator_names(text: String) -> PackedStringArray:
	var names := PackedStringArray()
	for tag in ["motor", "position", "velocity", "general"]:
		for actuator_name in _names_for_tag(text, tag):
			if not names.has(actuator_name):
				names.append(actuator_name)
	return names


static func _sensor_names(text: String) -> PackedStringArray:
	var names := PackedStringArray()
	for tag in ["sensor", "touch", "force", "torque", "framepos", "framequat", "jointpos", "jointvel"]:
		for sensor_name in _names_for_tag(text, tag):
			if not names.has(sensor_name):
				names.append(sensor_name)
	if names.is_empty():
		names = PackedStringArray(["joint_state", "contact", "force"])
	return names


static func _first_attr(text: String, tag: String, attr_name: String, fallback: String) -> String:
	var regex := RegEx.new()
	regex.compile(_XML_TAG_PATTERN % tag)
	var result := regex.search(text)
	if result == null:
		return fallback
	return _attr(result.get_string(), attr_name, fallback)


static func _attr(fragment: String, attr_name: String, fallback: String) -> String:
	var regex := RegEx.new()
	regex.compile("%s\\s*=\\s*['\"]([^'\"]+)['\"]" % attr_name)
	var result := regex.search(fragment)
	if result == null:
		return fallback
	return result.get_string(1)


static func _stable_ids(model: MjModelResource) -> Dictionary:
	var ids := {}
	for group in [
		["body", model.body_names],
		["joint", model.joint_names],
		["actuator", model.actuator_names],
		["geom", model.geom_names],
		["sensor", model.sensor_names],
	]:
		var prefix := String(group[0])
		var values: PackedStringArray = group[1]
		for i in range(values.size()):
			ids["%s:%s" % [prefix, values[i]]] = i
	return ids
