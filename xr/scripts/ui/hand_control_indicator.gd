class_name HandControlIndicator
extends Node3D
## Small wrist-mounted status lamp for bare-hand Revo2 control.

const DISCONNECTED_COLOR := Color(0.32, 0.34, 0.38, 0.95)
const CONNECTED_COLOR := Color(0.08, 1.0, 0.28, 1.0)
const CONTROL_ENABLED_COLOR := Color(1.0, 0.48, 0.06, 1.0)
const LAMP_RADIUS := 0.012

var _material: StandardMaterial3D


func _ready() -> void:
	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var mesh := SphereMesh.new()
	mesh.radius = LAMP_RADIUS
	mesh.height = LAMP_RADIUS * 2.0
	mesh.radial_segments = 20
	mesh.rings = 10
	lamp.mesh = mesh
	lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.no_depth_test = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.emission_enabled = true
	_material.emission_energy_multiplier = 1.4
	lamp.material_override = _material
	add_child(lamp)
	set_status(false, false)
	visible = false


func update_state(
	wrist_position: Variant,
	connected: bool,
	control_enabled: bool,
	shown: bool
) -> void:
	if not shown or not wrist_position is Vector3:
		visible = false
		return
	position = wrist_position as Vector3
	set_status(connected, control_enabled)
	visible = true


func set_status(connected: bool, control_enabled: bool) -> void:
	if _material == null:
		return
	var color := status_color(connected, control_enabled)
	_material.albedo_color = color
	_material.emission = Color(color.r, color.g, color.b, 1.0)


static func status_color(connected: bool, control_enabled: bool) -> Color:
	if not connected:
		return DISCONNECTED_COLOR
	return CONTROL_ENABLED_COLOR if control_enabled else CONNECTED_COLOR
