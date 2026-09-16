extends Node3D
## Two bounded, shadow-free lights. No WorldEnvironment or mode-scene mutation.
## Layer 20 is reserved for robot_model meshes; app/Inside geometry stays unlit
## by this rig. Keep the mesh's normal layers so existing cameras still see it.
const MODEL_LIGHT_MASK := 1 << 19
var key_light: DirectionalLight3D
var fill_light: DirectionalLight3D


func _init() -> void:
	key_light = _light("Key", Vector3(-45, -30, 0), 0.25)
	fill_light = _light("Fill", Vector3(-25, 150, 0), 0.0)


func _light(light_name: String, angles: Vector3, specular: float) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = light_name
	light.rotation_degrees = angles
	light.light_cull_mask = MODEL_LIGHT_MASK
	light.shadow_enabled = false
	light.light_specular = specular
	add_child(light)
	return light


func update_lighting(key_energy: float, fill_energy: float, key_color: Color, fill_color: Color) -> void:
	key_light.light_energy = key_energy
	fill_light.light_energy = fill_energy
	key_light.light_color = key_color
	fill_light.light_color = fill_color
