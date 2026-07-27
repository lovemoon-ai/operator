extends Node3D
## Renders a robot's real meshes, driven by MuJoCo body transforms.
##
## Model-agnostic: any profile that ships a `visual_model` GLB whose node names
## match its simulation model's bodies is rendered as the actual robot instead
## of the debug spheres in `mujoco_skeleton_view.gd`. Robots with a bespoke
## overlay (the humanoids) keep it — this covers everything else, so adding a
## robot does not require writing a renderer for it.
##
## URDF-derived GLBs name their nodes `<body>_link`; that suffix is normalised
## away so the same bundle works against a hand-written kinematic model.

## Below this many matched links the GLB does not describe this model, and the
## caller should fall back rather than show a robot frozen in its rest pose.
const MIN_MATCHED_LINKS := 3

var simulation: Node
var head_camera: Node3D

var _instance: Node3D
var _links: Dictionary = {}
var _ordered: Array[String] = []
var _locked := false


## Load the GLB and bind its nodes to simulation bodies. False when the pairing
## is too weak to drive, leaving the caller free to use the skeleton view.
func configure(value: Node, camera: Node3D, glb_path: String) -> bool:
	simulation = value
	head_camera = camera
	if simulation == null or simulation.model == null:
		push_warning("[MujocoMeshView] simulation model is not ready")
		return false
	if glb_path.is_empty() or not ResourceLoader.exists(glb_path):
		return false
	var packed: PackedScene = load(glb_path)
	if packed == null:
		push_warning("[MujocoMeshView] cannot load %s" % glb_path)
		return false
	_instance = packed.instantiate()
	if _instance == null:
		return false
	add_child(_instance)
	# The caller adds MjSimulation to the live tree first, so its synchronous
	# _ready() has already published the model. Validate the pairing before
	# claiming success; otherwise the caller must create the skeleton fallback.
	return bind_now() >= MIN_MATCHED_LINKS


func matched_link_count() -> int:
	return _links.size()


## Bind GLB nodes to simulation bodies. Returns how many links were paired.
func bind_now() -> int:
	if simulation == null or simulation.model == null:
		return 0
	var by_name := {}
	_collect(_instance, by_name)
	_links.clear()
	_ordered.clear()
	# MuJoCo lists bodies parent-first, so driving them in this order lets a
	# child's global transform survive its parent being moved in the same frame.
	for body_name in simulation.model.body_names:
		var key := _normalize(str(body_name))
		if by_name.has(key):
			_links[str(body_name)] = by_name[key]
			_ordered.append(str(body_name))
	_lock_in_front()
	if _links.size() < MIN_MATCHED_LINKS:
		push_warning(
			"[MujocoMeshView] only %d links matched; visual model does not fit this robot"
			% _links.size()
		)
	else:
		print(
			"[MujocoMeshView] bound %d links of %d simulation bodies"
			% [_links.size(), simulation.model.body_names.size()]
		)
	return _links.size()


func _collect(node: Node, out: Dictionary) -> void:
	if node is Node3D:
		var key := _normalize(node.name)
		if not out.has(key):
			out[key] = node
	for child in node.get_children():
		_collect(child, out)


func _normalize(name: String) -> String:
	var key := name.to_lower()
	# Godot uniquifies duplicate node names as `foo2`; the URDF suffix and the
	# separator style are the only differences that matter here.
	key = key.replace("-", "_")
	if key.ends_with("_link"):
		key = key.substr(0, key.length() - "_link".length())
	return key


func _process(_delta: float) -> void:
	if simulation == null or _links.is_empty():
		return
	if not _locked:
		_lock_in_front()
	var root := global_transform
	for body_name in _ordered:
		var node: Node3D = _links[body_name]
		if node == null:
			continue
		var body_transform: Transform3D = simulation.call("get_body_transform", body_name)
		node.global_transform = root * body_transform


func _lock_in_front() -> void:
	if head_camera == null:
		return
	var camera_xf := head_camera.global_transform
	var forward := -camera_xf.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var origin := camera_xf.origin + forward * 0.9
	origin.y = maxf(camera_xf.origin.y - 0.75, 0.05)
	global_transform = Transform3D(Basis.looking_at(-forward, Vector3.UP), origin)
	_locked = true
