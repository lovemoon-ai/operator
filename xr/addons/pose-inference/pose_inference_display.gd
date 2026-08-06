class_name PoseInferenceDisplay
extends Node3D
## A monoscopic RGB screen deliberately fixed in front of the HMD.

@export var display_distance_m := 1.25
@export var display_size_m := Vector2(1.6, 0.9)

var head_lock_target: XRCamera3D
var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _texture: ImageTexture


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = display_size_m
	_mesh_instance.mesh = mesh
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mesh_instance.material_override = _material
	add_child(_mesh_instance)


func _process(_delta: float) -> void:
	if head_lock_target == null:
		return
	global_transform = head_lock_target.global_transform
	global_position += -head_lock_target.global_transform.basis.z * display_distance_m


func show_jpeg(_frame_id: int, _capture_time_ns: int, jpeg: PackedByteArray) -> void:
	var image := Image.new()
	if image.load_jpg_from_buffer(jpeg) != OK:
		return
	if _texture == null:
		_texture = ImageTexture.create_from_image(image)
		_material.albedo_texture = _texture
	else:
		_texture.update(image)
