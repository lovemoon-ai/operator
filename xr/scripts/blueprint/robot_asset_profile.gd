extends RefCounted
## Restricted data-only GLB profile. Validate before invoking any GLTF importer.
## No URIs, textures, extensions, cameras, skins, animations, or Godot resources.
const SCHEMA := "operator.robot_asset.v1"
const MAX_JSON_BYTES := 2 * 1024 * 1024
const MAX_VERTICES := 3_000_000
const MAX_INDICES := 9_000_000
static var last_error := ""


static func parse(bytes: PackedByteArray) -> Dictionary:
	last_error = ""
	if bytes.size() < 28 or bytes.size() > 64 * 1024 * 1024:
		return _invalid("GLB header, check 11")
	if bytes.decode_u32(0) != 0x46546c67 or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != bytes.size():
		return _invalid("GLB header, check 13")
	var json_size := bytes.decode_u32(12)
	if json_size < 2 or json_size > MAX_JSON_BYTES or json_size % 4 != 0 or 28 + json_size > bytes.size() or bytes.decode_u32(16) != 0x4e4f534a:
		return _invalid("GLB header, check 16")
	var binary_start := 28 + json_size
	var binary_size := bytes.decode_u32(20 + json_size)
	if bytes.decode_u32(24 + json_size) != 0x004e4942 or binary_start + binary_size != bytes.size():
		return _invalid("GLB header, check 20")
	var raw: Variant = JSON.parse_string(bytes.slice(20, 20 + json_size).get_string_from_utf8())
	if not raw is Dictionary:
		return _invalid("GLB header, check 23")
	var doc := raw as Dictionary
	if not _keys(doc, ["asset", "scene", "scenes", "nodes", "meshes", "materials", "buffers", "bufferViews", "accessors", "extras"]):
		return _invalid("document fields, check 26")
	if not doc.get("asset") is Dictionary or not _keys(doc["asset"], ["version", "generator"]) or doc["asset"].get("version") != "2.0":
		return _invalid("document fields, check 28")
	for field in ["nodes", "meshes", "materials", "buffers", "bufferViews", "accessors", "scenes"]:
		if not doc.get(field) is Array or (doc[field] as Array).size() > 2048:
			return _invalid("document fields, check 31")
	var nodes: Array = doc["nodes"]
	if nodes.is_empty() or nodes.size() > 512 or (doc["materials"] as Array).size() > 128:
		return _invalid("nodes/buffers, check 34")
	if (doc["buffers"] as Array).size() != 1 or not doc["buffers"][0] is Dictionary:
		return _invalid("nodes/buffers, check 36")
	var buffer: Dictionary = doc["buffers"][0]
	if not _keys(buffer, ["byteLength"]) or not _integer(buffer.get("byteLength"), 1, binary_size) or binary_size - int(buffer["byteLength"]) > 3:
		return _invalid("nodes/buffers, check 39")
	var views: Array = doc["bufferViews"]
	for view in views:
		if not view is Dictionary or not _keys(view, ["buffer", "byteOffset", "byteLength"]):
			return _invalid("buffer views, check 43")
		if view.get("buffer") != 0 or not _integer(view.get("byteOffset", 0), 0, binary_size) or not _integer(view.get("byteLength"), 1, binary_size):
			return _invalid("buffer views, check 45")
		if int(view.get("byteOffset", 0)) + int(view["byteLength"]) > int(buffer["byteLength"]):
			return _invalid("buffer views, check 47")
	var accessors: Array = doc["accessors"]
	for accessor in accessors:
		if not accessor is Dictionary or not _keys(accessor, ["bufferView", "byteOffset", "componentType", "count", "type", "min", "max"]):
			return _invalid("accessors, check 51")
		if not _integer(accessor.get("bufferView"), 0, views.size() - 1) or not _integer(accessor.get("count"), 1, MAX_VERTICES):
			return _invalid("accessors, check 53")
		var width := 0
		if accessor.get("type") == "VEC3" and accessor.get("componentType") == 5126:
			width = 12
		elif accessor.get("type") == "SCALAR" and (accessor.get("componentType") == 5123 or accessor.get("componentType") == 5125):
			width = 2 if accessor.get("componentType") == 5123 else 4
		if width == 0 or not _integer(accessor.get("byteOffset", 0), 0, binary_size):
			return _invalid("accessors, check 60")
		var view: Dictionary = views[int(accessor["bufferView"])]
		if int(accessor.get("byteOffset", 0)) + int(accessor["count"]) * width > int(view["byteLength"]):
			return _invalid("accessors, check 63")
		for bound in ["min", "max"]:
			if accessor.has(bound) and not _vector(accessor[bound], 3 if width == 12 else 1):
				return _invalid("accessors, check 66")
	var vertices := 0
	var indices := 0
	var mesh_costs: Array[Vector2i] = []
	for mesh in doc["meshes"]:
		var mesh_cost := Vector2i.ZERO
		if not mesh is Dictionary or not _keys(mesh, ["primitives", "name"]) or not mesh.get("primitives") is Array or mesh["primitives"].size() > 128:
			return _invalid("meshes/materials, check 70")
		for primitive in mesh["primitives"]:
			if not primitive is Dictionary or not _keys(primitive, ["attributes", "indices", "material", "mode"]):
				return _invalid("meshes/materials, check 73")
			var attributes: Variant = primitive.get("attributes")
			if primitive.get("mode", 4) != 4 or not attributes is Dictionary or not _keys(attributes, ["POSITION", "NORMAL"]):
				return _invalid("meshes/materials, check 76")
			if not _integer(attributes.get("POSITION"), 0, accessors.size() - 1):
				return _invalid("meshes/materials, check 78")
			var position: Dictionary = accessors[int(attributes["POSITION"])]
			if position["type"] != "VEC3":
				return _invalid("meshes/materials, check 81")
			vertices += int(position["count"])
			mesh_cost.x += int(position["count"])
			if vertices > MAX_VERTICES:
				return _invalid("meshes/materials, check 84")
			if attributes.has("NORMAL"):
				if not _integer(attributes["NORMAL"], 0, accessors.size() - 1):
					return _invalid("meshes/materials, check 87")
				var normal: Dictionary = accessors[int(attributes["NORMAL"])]
				if normal["type"] != "VEC3" or normal["count"] != position["count"]:
					return _invalid("meshes/materials, check 90")
			if primitive.has("indices"):
				if not _integer(primitive["indices"], 0, accessors.size() - 1) or accessors[int(primitive["indices"])]["type"] != "SCALAR":
					return _invalid("meshes/materials, check 93")
				mesh_cost.y += int(accessors[int(primitive["indices"])]["count"])
			else:
				mesh_cost.y += int(position["count"])
			if primitive.has("material") and not _integer(primitive["material"], 0, doc["materials"].size() - 1):
				return _invalid("meshes/materials, check 95")
		# GLTF imports each primitive separately, even when accessors alias.
		indices += mesh_cost.y
		if indices > MAX_INDICES:
			return _invalid("mesh index budget exceeded")
		mesh_costs.append(mesh_cost)
	for material in doc["materials"]:
		if not material is Dictionary or not _keys(material, ["name", "pbrMetallicRoughness", "doubleSided"]):
			return _invalid("meshes/materials, check 98")
		var pbr: Variant = material.get("pbrMetallicRoughness", {})
		if not pbr is Dictionary or not _keys(pbr, ["baseColorFactor", "metallicFactor", "roughnessFactor"]):
			return _invalid("meshes/materials, check 101")
		if not _vector(pbr.get("baseColorFactor", [1, 1, 1, 1]), 4):
			return _invalid("meshes/materials, check 103")
		for field in ["metallicFactor", "roughnessFactor"]:
			if pbr.has(field) and not _number(pbr[field]):
				return _invalid("meshes/materials, check 106")
	var parents := {}
	var instance_cost := Vector2i.ZERO
	for index in range(nodes.size()):
		var node: Variant = nodes[index]
		if not node is Dictionary or not _keys(node, ["name", "children", "matrix", "translation", "rotation", "scale", "mesh"]):
			return _invalid("node hierarchy, check 111")
		if node.has("mesh") and not _integer(node["mesh"], 0, doc["meshes"].size() - 1):
			return _invalid("node hierarchy, check 113")
		if node.has("mesh"):
			instance_cost += mesh_costs[int(node["mesh"])]
			if instance_cost.x > MAX_VERTICES or instance_cost.y > MAX_INDICES:
				return _invalid("mesh instance budget exceeded")
		for field in ["matrix", "translation", "rotation", "scale"]:
			if node.has(field) and not _vector(node[field], 16 if field == "matrix" else (4 if field == "rotation" else 3)):
				return _invalid("node hierarchy, check 116")
		if not node.get("children", []) is Array:
			return _invalid("node hierarchy, check 118")
		for child in node.get("children", []):
			if not _integer(child, 0, nodes.size() - 1) or parents.has(int(child)) or int(child) == index:
				return _invalid("node hierarchy, check 121")
			parents[int(child)] = index
	var extras: Variant = doc.get("extras")
	if not extras is Dictionary or not _keys(extras, ["operator_robot"]) or not extras.get("operator_robot") is Dictionary:
		return _invalid("articulation, check 125")
	var rig: Dictionary = extras["operator_robot"]
	if rig.get("schema") != SCHEMA or rig.get("coordinate_space") != "xr_y_up" or not _integer(rig.get("root"), 0, nodes.size() - 1):
		return _invalid("articulation, check 128")
	var root := int(rig["root"])
	if parents.has(root) or parents.size() != nodes.size() - 1 or doc.get("scene", 0) != 0 or doc["scenes"].size() != 1:
		return _invalid("articulation, check 131")
	var scene: Variant = doc["scenes"][0]
	if not scene is Dictionary or not _keys(scene, ["nodes"]) or not scene.get("nodes") is Array or scene["nodes"].size() != 1 or not _integer(scene["nodes"][0], root, root):
		return _invalid("articulation, check 134")
	# Every node must reach the one root; bounded walk rejects cycles.
	for index in range(nodes.size()):
		var current := index
		for _step in range(nodes.size()):
			if current == root:
				break
			current = int(parents.get(current, -1))
		if current != root:
			return _invalid("articulation, check 143")
	if not rig.get("joints") is Array or rig["joints"].size() > 256:
		return _invalid("articulation, check 145")
	var names := {}
	var joint_nodes := {}
	for joint in rig["joints"]:
		if not joint is Dictionary or not joint.get("name") is String or str(joint["name"]).is_empty():
			return _invalid("articulation, check 150")
		if names.has(joint["name"]) or not _integer(joint.get("node"), 0, nodes.size() - 1):
			return _invalid("articulation, check 152")
		var node := int(joint["node"])
		if node == root or joint_nodes.has(node) or joint.get("type") not in ["hinge", "slide"]:
			return _invalid("articulation, check 155")
		if not _vector(joint.get("axis"), 3) or not _vector(joint.get("pivot"), 3) or not _number(joint.get("reference")):
			return _invalid("articulation, check 157")
		var axis: Array = joint["axis"]
		if not is_equal_approx(Vector3(axis[0], axis[1], axis[2]).length(), 1.0):
			return _invalid("articulation, check 160")
		names[joint["name"]] = true
		joint_nodes[node] = true
	return doc


static func _keys(value: Dictionary, allowed: Array) -> bool:
	for key in value:
		if key not in allowed:
			return false
	return true


static func _number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and absf(float(value)) <= 100000.0


static func _integer(value: Variant, low: int, high: int) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) == floor(float(value)) and float(value) >= low and float(value) <= high


static func _vector(value: Variant, size: int) -> bool:
	if not value is Array or value.size() != size:
		return false
	for entry in value:
		if not _number(entry):
			return false
	return true


static func _invalid(reason: String) -> Dictionary:
	last_error = reason
	return {}
