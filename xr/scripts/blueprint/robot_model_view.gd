extends Node3D
## Render-only, robot-owned articulated GLB. No Inside Robot dependency.

signal warning_raised(message: String)
signal asset_loaded(from_cache: bool)

const AssetCache := preload("res://scripts/blueprint/robot_asset_cache.gd")
const AssetProfile := preload("res://scripts/blueprint/robot_asset_profile.gd")
const ModelLighting := preload("res://scripts/blueprint/model_lighting.gd")

var _instance: Node3D
var _root: Node3D
var _properties: Dictionary = {}
var _asset_host := ""
var _joint_names: Array = []
var asset_source := ""
var _joints: Array[Dictionary] = []
var _shown: PackedFloat64Array = PackedFloat64Array()
var _target: PackedFloat64Array = PackedFloat64Array()
var _target_base := Transform3D.IDENTITY
var _last_sample: Variant = null
var _received_us := 0
var _smoothing_s := 0.04
var _stale_us := 500000
var _error := ""


func configure(properties: Dictionary, asset_host: String = "") -> bool:
	if not AssetCache.valid_hash(str(properties.get("asset_sha256", ""))):
		return _reject("Invalid robot asset SHA-256")
	if asset_host.is_empty():
		return _reject("Robot asset requires a connected host")
	var names: Array = properties.get("joint_names", [])
	var unique := {}
	for name_v in names:
		var joint_name := str(name_v)
		if not name_v is String or joint_name.is_empty() or unique.has(joint_name):
			return _reject("Duplicate or empty joint name")
		unique[joint_name] = true
	if names.is_empty() or names.size() > 256:
		return _reject("Robot must declare 1..256 joints")
	_joint_names = names.duplicate()
	_properties = properties.duplicate(true)
	_asset_host = asset_host
	_smoothing_s = float(properties.get("smoothing_ms", 40)) / 1000.0
	_stale_us = int(float(properties.get("stale_after_ms", 500)) * 1000.0)
	return true


func _ready() -> void:
	if not _error.is_empty() or _properties.is_empty():
		return
	var cache := AssetCache.new()
	add_child(cache)
	cache.loaded.connect(_on_asset_loaded)
	cache.failed.connect(_reject)
	cache.fetch(_asset_host, int(_properties["asset_port"]), str(_properties["asset_sha256"]), int(_properties["asset_size"]))


func is_asset_ready() -> bool:
	return is_instance_valid(_root) and _error.is_empty()


func asset_error() -> String:
	return _error


func sample_is_fresh() -> bool:
	return _received_us > 0 and Time.get_ticks_usec() - _received_us <= _stale_us


func base_world_position() -> Vector3:
	return _root.global_position if is_instance_valid(_root) else global_position


func _on_asset_loaded(bytes: PackedByteArray, from_cache: bool) -> void:
	var document := AssetProfile.parse(bytes)
	if document.is_empty():
		_reject("Robot GLB rejected: %s" % AssetProfile.last_error)
		return
	var rig: Dictionary = document["extras"]["operator_robot"]
	var table := {}
	for joint in rig["joints"]:
		table[joint["name"]] = joint
	if table.size() != _joint_names.size():
		_reject("Robot asset joint set does not match Blueprint")
		return
	for name_v in _joint_names:
		if not table.has(name_v):
			_reject("Robot asset is missing joint %s" % name_v)
			return
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	if gltf.append_from_buffer(bytes, "", state) != OK:
		_reject("Robot GLB importer failed")
		return
	var instance := gltf.generate_scene(state) as Node3D
	if instance == null:
		_reject("Robot GLB did not produce a scene")
		return
	var root := state.get_scene_node(int(rig["root"])) as Node3D
	if root == null:
		instance.free()
		_reject("Robot GLB root was not imported")
		return
	for name_v in _joint_names:
		var joint: Dictionary = table[name_v].duplicate(true)
		var node := state.get_scene_node(int(joint["node"])) as Node3D
		if node == null or not node.transform.is_finite():
			instance.free()
			_joints.clear()
			_reject("Robot GLB joint node was not imported")
			return
		joint["node"] = node
		joint["rest"] = node.transform
		joint["axis"] = Vector3(joint["axis"][0], joint["axis"][1], joint["axis"][2])
		joint["pivot"] = Vector3(joint["pivot"][0], joint["pivot"][1], joint["pivot"][2])
		_joints.append(joint)
	_instance = instance
	_root = root
	_configure_visuals(instance)
	_instance.visible = false
	add_child(instance)
	if not _target.is_empty():
		_shown = _target.duplicate()
		_apply(1.0)
	asset_source = "cache" if from_cache else "network"
	asset_loaded.emit(from_cache)


func update_sample(positions: Variant, base_pose: Variant, sample: Variant) -> bool:
	if not _error.is_empty():
		return false
	if positions == null or base_pose == null or sample == null:
		if _instance != null:
			_instance.visible = false
		_received_us = 0
		return false
	if sample == _last_sample:
		return false # Other UI updates must not revive a stale robot.
	if not BlueprintContract.value_matches_type(positions, "number_array") \
			or not BlueprintContract.value_matches_type(base_pose, "number_array") \
			or not BlueprintContract.value_matches_type(sample, "integer"):
		return false
	var values: Array = positions
	var pose: Array = base_pose
	if values.size() != _joint_names.size() or pose.size() != 7:
		warning_raised.emit("Robot sample has incorrect joint/base dimensions")
		return false
	# Godot may store Vector3/Basis as float32; finite JSON doubles can overflow.
	for value in values + pose:
		if absf(float(value)) > 100000.0:
			return false
	var rotation := Quaternion(float(pose[3]), float(pose[4]), float(pose[5]), float(pose[6]))
	if rotation.length_squared() < 1e-12 or not is_finite(rotation.length_squared()):
		return false
	_target = PackedFloat64Array(values)
	_target_base = Transform3D(
		Basis(rotation.normalized()), Vector3(float(pose[0]), float(pose[1]), float(pose[2]))
	)
	var now := Time.get_ticks_usec()
	if _received_us == 0 or now - _received_us > _stale_us:
		_shown = _target.duplicate()
		if _root != null:
			_root.transform = _target_base
	_last_sample = sample
	_received_us = now
	if _root != null:
		_apply(1.0 if _smoothing_s <= 0 else 0.0)
	return true


func _process(delta: float) -> void:
	if _instance == null or _root == null or not _error.is_empty():
		return
	_instance.visible = _received_us > 0 and Time.get_ticks_usec() - _received_us <= _stale_us
	if _instance.visible:
		_apply(1.0 if _smoothing_s <= 0 else 1.0 - exp(-delta / _smoothing_s))


func _apply(alpha: float) -> void:
	_root.transform = _root.transform.interpolate_with(_target_base, alpha)
	for i in range(_joints.size()):
		_shown[i] = lerpf(_shown[i], _target[i], alpha)
		var joint: Dictionary = _joints[i]
		var link: Node3D = joint["node"]
		var rest: Transform3D = joint["rest"]
		var axis: Vector3 = joint["axis"]
		var value := _shown[i] - float(joint["reference"])
		if str(joint["type"]) == "slide":
			link.transform = rest * Transform3D(Basis.IDENTITY, axis * value)
		else:
			var basis := Basis(axis, value)
			var pivot: Vector3 = joint["pivot"]
			link.transform = rest * Transform3D(basis, pivot - basis * pivot)


func _configure_visuals(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(node as GeometryInstance3D).layers |= ModelLighting.MODEL_LIGHT_MASK
	for child in node.get_children():
		_configure_visuals(child)


func _reject(message: String) -> bool:
	_error = message
	warning_raised.emit(message)
	return false
