extends XRToolsFunctionPointer
class_name OperatorFunctionPointer

const MIN_LASER_LENGTH_M := 0.001


func _enter_tree() -> void:
	super._enter_tree()
	_sync_laser_shader_length()


func _visible_hit(at: Vector3) -> void:
	super._visible_hit(at)
	_sync_laser_shader_length()


func _visible_move(at: Vector3) -> void:
	super._visible_move(at)
	_sync_laser_shader_length()


func _visible_miss() -> void:
	super._visible_miss()
	_sync_laser_shader_length()


func _sync_laser_shader_length() -> void:
	var laser := get_node_or_null("Laser") as MeshInstance3D
	if laser == null:
		return

	var length_m := distance
	var box := laser.mesh as BoxMesh
	if box:
		length_m = box.size.z

	var material := laser.get_surface_override_material(0)
	if material == null and box:
		material = box.material
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter("laser_length_m", maxf(length_m, MIN_LASER_LENGTH_M))
