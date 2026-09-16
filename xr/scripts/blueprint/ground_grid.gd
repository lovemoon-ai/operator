extends MeshInstance3D
## Finite transparent XZ grid. The shader is client-owned, never downloaded.
const GridShader := preload("res://scripts/blueprint/ground_grid.gdshader")


func configure(properties: Dictionary, color: Color, major_color: Color) -> void:
	var plane := PlaneMesh.new()
	var size_m := float(properties["size"])
	plane.size = Vector2(size_m, size_m)
	mesh = plane
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = GridShader
	material.set_shader_parameter("grid_size", size_m)
	for key in ["spacing", "major_every", "line_width"]:
		material.set_shader_parameter(key, float(properties[key]))
	material.set_shader_parameter("line_color", color)
	material.set_shader_parameter("major_color", major_color)
	material_override = material
