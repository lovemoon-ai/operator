extends Node3D
class_name OperatorUIPointerVisual

const RayShader := preload("res://scenes/ui/operator_ui_ray.gdshader")

const RAY_THICKNESS_M := 0.0012
const TARGET_RADIUS_M := 0.018
const TARGET_PRESSED_RADIUS_M := 0.021
const MIN_LASER_LENGTH_M := 0.001
const MAX_DISTANCE_M := 4.0

var _laser: MeshInstance3D
var _target: MeshInstance3D
var _ray_mesh: BoxMesh
var _target_mesh: SphereMesh
var _ray_material: ShaderMaterial
var _target_material: StandardMaterial3D


func _ready() -> void:
	_build_visuals()
	clear()


func show_ray(ray_origin: Vector3, ray_direction: Vector3, hit_point: Vector3, pressed: bool = false) -> void:
	_build_visuals()

	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		clear()
		return

	var length_m := clampf(ray_origin.distance_to(hit_point), MIN_LASER_LENGTH_M, MAX_DISTANCE_M)
	global_position = ray_origin
	look_at(ray_origin + direction, _safe_up(direction))

	_ray_mesh.size = Vector3(RAY_THICKNESS_M, RAY_THICKNESS_M, length_m)
	_laser.position = Vector3(0.0, 0.0, -length_m * 0.5)
	_ray_material.set_shader_parameter("laser_length_m", length_m)
	_ray_material.set_shader_parameter("alpha_multiplier", 1.18 if pressed else 1.0)

	_target_mesh.radius = TARGET_PRESSED_RADIUS_M if pressed else TARGET_RADIUS_M
	_target_mesh.height = _target_mesh.radius * 2.0
	_target_material.albedo_color = (
		Color(0.64, 0.98, 1.0, 0.72) if pressed else Color(0.54, 0.94, 1.0, 0.52)
	)
	_target.global_position = hit_point

	visible = true
	_laser.visible = true
	_target.visible = true


func clear() -> void:
	visible = false
	if _laser:
		_laser.visible = false
	if _target:
		_target.visible = false


func _build_visuals() -> void:
	if _laser != null:
		return

	_ray_material = ShaderMaterial.new()
	_ray_material.shader = RayShader
	_ray_material.set_shader_parameter("core_color", Color(0.34, 0.88, 1.0, 0.48))
	_ray_material.set_shader_parameter("tip_color", Color(0.78, 0.98, 1.0, 0.10))
	_ray_material.set_shader_parameter("fade_start", 0.58)

	_ray_mesh = BoxMesh.new()
	_ray_mesh.size = Vector3(RAY_THICKNESS_M, RAY_THICKNESS_M, 1.0)
	_ray_mesh.subdivide_depth = 20
	_ray_mesh.material = _ray_material

	_laser = MeshInstance3D.new()
	_laser.name = "Laser"
	_laser.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_laser.mesh = _ray_mesh
	add_child(_laser)

	_target_material = StandardMaterial3D.new()
	_target_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_target_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_target_material.albedo_color = Color(0.54, 0.94, 1.0, 0.52)

	_target_mesh = SphereMesh.new()
	_target_mesh.radius = TARGET_RADIUS_M
	_target_mesh.height = TARGET_RADIUS_M * 2.0
	_target_mesh.radial_segments = 12
	_target_mesh.rings = 6
	_target_mesh.material = _target_material

	_target = MeshInstance3D.new()
	_target.name = "Target"
	_target.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_target.mesh = _target_mesh
	add_child(_target)


func _safe_up(direction: Vector3) -> Vector3:
	if absf(direction.dot(Vector3.UP)) > 0.96:
		return Vector3.RIGHT
	return Vector3.UP
