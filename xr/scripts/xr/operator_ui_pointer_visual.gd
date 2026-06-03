extends Node3D
class_name OperatorUIPointerVisual

const RayShader := preload("res://scenes/ui/operator_ui_ray.gdshader")

const RAY_THICKNESS_M := 0.0012
const IDLE_RAY_THICKNESS_M := 0.0009
const TARGET_RADIUS_M := 0.012
const TARGET_PRESSED_RADIUS_M := 0.0075
const PULSE_RADIUS_M := 0.022
const MIN_LASER_LENGTH_M := 0.001
const MAX_DISTANCE_M := 4.0
const IDLE_RAY_LENGTH_M := 3.4
const HIT_CORE_COLOR := Color(1.0, 0.647, 0.169, 0.46)
const HIT_TIP_COLOR := Color(0.949, 0.420, 0.114, 0.10)
const IDLE_CORE_COLOR := Color(0.72, 0.74, 0.76, 0.24)
const IDLE_TIP_COLOR := Color(0.72, 0.74, 0.76, 0.04)
const HIT_FADE_START := 0.58
const IDLE_FADE_START := 0.24

var _laser: MeshInstance3D
var _target: MeshInstance3D
var _pulse: MeshInstance3D
var _ray_mesh: BoxMesh
var _target_mesh: SphereMesh
var _pulse_mesh: SphereMesh
var _ray_material: ShaderMaterial
var _target_material: StandardMaterial3D
var _pulse_material: StandardMaterial3D
var _pressed := false
var _pulse_phase := 0.0


func _ready() -> void:
	_build_visuals()
	clear()


func _process(delta: float) -> void:
	if not visible or not _pressed or _pulse == null:
		return
	_pulse_phase = fmod(_pulse_phase + delta * 3.4, TAU)
	var pulse := 0.5 + 0.5 * sin(_pulse_phase)
	var radius := PULSE_RADIUS_M + pulse * 0.012
	_pulse_mesh.radius = radius
	_pulse_mesh.height = radius * 2.0
	_pulse_material.albedo_color = Color(1.0, 0.647, 0.169, 0.18 - pulse * 0.08)


func show_ray(ray_origin: Vector3, ray_direction: Vector3, hit_point: Vector3, pressed: bool = false) -> void:
	_build_visuals()

	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		clear()
		return

	var length_m := clampf(ray_origin.distance_to(hit_point), MIN_LASER_LENGTH_M, MAX_DISTANCE_M)
	_place_ray(ray_origin, direction, length_m, RAY_THICKNESS_M)
	_apply_ray_style(HIT_CORE_COLOR, HIT_TIP_COLOR, HIT_FADE_START, 1.18 if pressed else 1.0)

	_target_mesh.radius = TARGET_PRESSED_RADIUS_M if pressed else TARGET_RADIUS_M
	_target_mesh.height = _target_mesh.radius * 2.0
	_pressed = pressed
	_target_material.albedo_color = Color(1.0, 0.647, 0.169, 0.72 if pressed else 0.50)
	_target.global_position = hit_point
	_pulse.global_position = hit_point
	_pulse.visible = pressed

	visible = true
	_laser.visible = true
	_target.visible = true


func show_idle_ray(ray_origin: Vector3, ray_direction: Vector3) -> void:
	_build_visuals()

	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		clear()
		return

	_place_ray(ray_origin, direction, IDLE_RAY_LENGTH_M, IDLE_RAY_THICKNESS_M)
	_apply_ray_style(IDLE_CORE_COLOR, IDLE_TIP_COLOR, IDLE_FADE_START, 1.0)
	_pressed = false
	if _target:
		_target.visible = false
	if _pulse:
		_pulse.visible = false
	visible = true
	_laser.visible = true


func clear() -> void:
	visible = false
	_pressed = false
	if _laser:
		_laser.visible = false
	if _target:
		_target.visible = false
	if _pulse:
		_pulse.visible = false


func _build_visuals() -> void:
	if _laser != null:
		return

	_ray_material = ShaderMaterial.new()
	_ray_material.shader = RayShader
	_apply_ray_style(HIT_CORE_COLOR, HIT_TIP_COLOR, HIT_FADE_START, 1.0)

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
	_target_material.albedo_color = Color(1.0, 0.647, 0.169, 0.50)

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

	_pulse_material = StandardMaterial3D.new()
	_pulse_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pulse_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_pulse_material.albedo_color = Color(1.0, 0.647, 0.169, 0.16)

	_pulse_mesh = SphereMesh.new()
	_pulse_mesh.radius = PULSE_RADIUS_M
	_pulse_mesh.height = PULSE_RADIUS_M * 2.0
	_pulse_mesh.radial_segments = 16
	_pulse_mesh.rings = 8
	_pulse_mesh.material = _pulse_material

	_pulse = MeshInstance3D.new()
	_pulse.name = "PinchPulse"
	_pulse.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pulse.mesh = _pulse_mesh
	add_child(_pulse)


func _place_ray(ray_origin: Vector3, direction: Vector3, length_m: float, thickness_m: float) -> void:
	global_position = ray_origin
	look_at(ray_origin + direction, _safe_up(direction))
	_ray_mesh.size = Vector3(thickness_m, thickness_m, maxf(length_m, MIN_LASER_LENGTH_M))
	_laser.position = Vector3(0.0, 0.0, -_ray_mesh.size.z * 0.5)
	_ray_material.set_shader_parameter("laser_length_m", _ray_mesh.size.z)


func _apply_ray_style(core_color: Color, tip_color: Color, fade_start: float, alpha_multiplier: float) -> void:
	if _ray_material == null:
		return
	_ray_material.set_shader_parameter("core_color", core_color)
	_ray_material.set_shader_parameter("tip_color", tip_color)
	_ray_material.set_shader_parameter("fade_start", fade_start)
	_ray_material.set_shader_parameter("alpha_multiplier", alpha_multiplier)


func _safe_up(direction: Vector3) -> Vector3:
	if absf(direction.dot(Vector3.UP)) > 0.96:
		return Vector3.RIGHT
	return Vector3.UP
