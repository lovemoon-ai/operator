extends Node3D

@export var hand := "right"
@export var show_only_on_pico := true
@export var hide_when_untracked := true

var _enabled := false
var _body_material: StandardMaterial3D
var _face_material: StandardMaterial3D
var _dark_material: StandardMaterial3D
var _accent_material: StandardMaterial3D
var _button_material: StandardMaterial3D


func _ready() -> void:
	_enabled = _should_enable()
	visible = _enabled
	if not _enabled:
		set_process(false)
		return

	_create_materials()
	_build_visual()
	set_process(true)
	print("[Operator] PICO controller visual replacement enabled: %s" % hand)


func _process(_delta: float) -> void:
	if not _enabled:
		return
	if not hide_when_untracked:
		visible = true
		return

	var controller := get_parent() as XRController3D
	if controller == null:
		visible = true
		return
	visible = controller.get_is_active() or controller.get_has_tracking_data()


func _should_enable() -> bool:
	if not show_only_on_pico:
		return true
	if PicoPlatformAdapter.is_pico_build():
		return true

	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface:
		var runtime := str(xr_interface.get("XRRuntimeName")).to_lower()
		if PicoPlatformAdapter.is_pico_openxr_runtime_name(runtime):
			return true
	return false


func _create_materials() -> void:
	_body_material = _material(Color(0.86, 0.88, 0.90, 1.0), 0.62, 0.0)
	_face_material = _material(Color(0.045, 0.050, 0.060, 1.0), 0.48, 0.0)
	_dark_material = _material(Color(0.10, 0.105, 0.115, 1.0), 0.55, 0.0)
	_accent_material = _material(Color(0.00, 0.72, 0.48, 1.0), 0.35, 0.15)
	_button_material = _material(Color(0.22, 0.23, 0.25, 1.0), 0.42, 0.0)


func _material(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material


func _build_visual() -> void:
	var side := -1.0 if hand.to_lower() == "left" else 1.0

	_add_box("Body", Vector3(0.054, 0.040, 0.160), Vector3(0.0, -0.030, -0.030), Vector3(7.0, 0.0, 0.0), _body_material)
	_add_box("Faceplate", Vector3(0.058, 0.010, 0.064), Vector3(0.0, 0.004, -0.096), Vector3(7.0, 0.0, 0.0), _face_material)
	_add_box("Trigger", Vector3(0.036, 0.012, 0.044), Vector3(0.0, -0.012, -0.127), Vector3(13.0, 0.0, 0.0), _dark_material)
	_add_box("GripAccent", Vector3(0.006, 0.014, 0.100), Vector3(side * 0.030, -0.032, -0.028), Vector3(6.0, 0.0, side * 5.0), _accent_material)
	_add_box("StatusLed", Vector3(0.006, 0.006, 0.028), Vector3(side * 0.020, -0.008, 0.040), Vector3(5.0, 0.0, side * 8.0), _accent_material)

	_add_cylinder("Thumbstick", 0.014, 0.010, Vector3(side * 0.012, 0.013, -0.102), Vector3.ZERO, _button_material)
	_add_cylinder("SystemButton", 0.007, 0.007, Vector3(-side * 0.014, 0.012, -0.086), Vector3.ZERO, _button_material)
	_add_cylinder("PrimaryButton", 0.008, 0.007, Vector3(side * 0.021, 0.012, -0.070), Vector3.ZERO, _button_material)
	_add_cylinder("SecondaryButton", 0.008, 0.007, Vector3(side * 0.001, 0.012, -0.064), Vector3.ZERO, _button_material)
	_add_sphere("HandleCap", 0.028, Vector3(0.82, 0.72, 0.90), Vector3(0.0, -0.038, 0.060), _body_material)


func _add_box(name: String, size: Vector3, position: Vector3, rotation_degrees_value: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size

	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	instance.position = position
	instance.rotation_degrees = rotation_degrees_value
	instance.material_override = material
	add_child(instance)
	return instance


func _add_cylinder(name: String, radius: float, height: float, position: Vector3, rotation_degrees_value: Vector3, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 24

	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	instance.position = position
	instance.rotation_degrees = rotation_degrees_value
	instance.material_override = material
	add_child(instance)
	return instance


func _add_sphere(name: String, radius: float, scale_value: Vector3, position: Vector3, material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 24
	mesh.rings = 12

	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	instance.position = position
	instance.scale = scale_value
	instance.material_override = material
	add_child(instance)
	return instance
