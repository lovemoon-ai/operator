class_name MjBodyTracker
extends Node3D

@export var simulation_path: NodePath
@export var body_name := ""
@export var create_proxy_mesh := true
@export var proxy_radius := 0.025

var _simulation: MjSimulation
var _proxy: MeshInstance3D


func _ready() -> void:
	if not simulation_path.is_empty():
		_simulation = get_node_or_null(simulation_path) as MjSimulation
	if create_proxy_mesh:
		_proxy = MeshInstance3D.new()
		_proxy.name = "ProxyMesh"
		var mesh := SphereMesh.new()
		mesh.radius = proxy_radius
		mesh.height = proxy_radius * 2.0
		_proxy.mesh = mesh
		add_child(_proxy)


func _process(_delta: float) -> void:
	if _simulation == null and not simulation_path.is_empty():
		_simulation = get_node_or_null(simulation_path) as MjSimulation
	if _simulation == null or body_name.is_empty():
		return
	global_transform = _simulation.get_body_transform(body_name)
