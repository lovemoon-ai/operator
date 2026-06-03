extends XRToolsFunctionPointer
class_name OperatorFunctionPointer

const MIN_LASER_LENGTH_M := 0.001
const HIT_CORE_COLOR := Color(1.0, 0.647, 0.169, 0.46)
const HIT_TIP_COLOR := Color(0.949, 0.420, 0.114, 0.10)
const IDLE_CORE_COLOR := Color(0.72, 0.74, 0.76, 0.24)
const IDLE_TIP_COLOR := Color(0.72, 0.74, 0.76, 0.04)
const HIT_FADE_START := 0.58
const IDLE_FADE_START := 0.24


func _enter_tree() -> void:
	super._enter_tree()
	_sync_laser_shader_length()


func _process(delta: float) -> void:
	_mark_feedback_target_from_raycast()
	super._process(delta)


func _button_pressed() -> void:
	_mark_feedback_target_from_raycast()
	super._button_pressed()


func _button_released() -> void:
	_mark_feedback_target_from_raycast()
	super._button_released()


func _visible_hit(at: Vector3) -> void:
	super._visible_hit(at)
	_apply_ray_style(HIT_CORE_COLOR, HIT_TIP_COLOR, HIT_FADE_START, 1.0)
	_sync_laser_shader_length()


func _visible_move(at: Vector3) -> void:
	super._visible_move(at)
	_apply_ray_style(HIT_CORE_COLOR, HIT_TIP_COLOR, HIT_FADE_START, 1.0)
	_sync_laser_shader_length()


func _visible_miss() -> void:
	super._visible_miss()
	_apply_ray_style(IDLE_CORE_COLOR, IDLE_TIP_COLOR, IDLE_FADE_START, 1.0)
	if has_node("Laser"):
		$Laser.visible = enabled and show_laser != LaserShow.HIDE
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


func _apply_ray_style(core_color: Color, tip_color: Color, fade_start: float, alpha_multiplier: float) -> void:
	var laser := get_node_or_null("Laser") as MeshInstance3D
	if laser == null:
		return
	var material := laser.get_surface_override_material(0)
	var box := laser.mesh as BoxMesh
	if material == null and box:
		material = box.material
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		shader_material.set_shader_parameter("core_color", core_color)
		shader_material.set_shader_parameter("tip_color", tip_color)
		shader_material.set_shader_parameter("fade_start", fade_start)
		shader_material.set_shader_parameter("alpha_multiplier", alpha_multiplier)


func _mark_feedback_target_from_raycast() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return

	var collider: Object = target
	if collider == null:
		var raycast := get_node_or_null("RayCast") as RayCast3D
		if raycast == null or not raycast.is_colliding():
			return
		collider = raycast.get_collider()

	var scene := _scene_instance_for_collider(collider)
	if scene != null and scene.has_method("set_feedback_input_mode"):
		var controller := _feedback_controller()
		var feedback_mode := _feedback_mode_for_controller(controller)
		scene.set_feedback_input_mode(feedback_mode, controller if feedback_mode == "controllers" else null)


func _scene_instance_for_collider(collider: Object) -> Node:
	var node := collider as Node
	while node != null:
		if node.has_method("get_scene_instance"):
			var scene_candidate: Variant = node.call("get_scene_instance")
			if scene_candidate is Node:
				return scene_candidate as Node
		node = node.get_parent()
	return null


func _feedback_controller() -> XRController3D:
	var node: Node = self
	while node != null:
		if node is XRController3D:
			return node as XRController3D
		node = node.get_parent()

	var active_controller: Variant = get("_active_controller")
	if active_controller is XRController3D:
		return active_controller as XRController3D
	return null


func _feedback_mode_for_controller(controller: XRController3D) -> String:
	var haptics := _get_haptics_bus()
	if haptics != null and haptics.has_method("should_use_controller_feedback"):
		if not bool(haptics.call("should_use_controller_feedback", controller)):
			return "hands"
	return "controllers"


func _get_haptics_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Haptics")
