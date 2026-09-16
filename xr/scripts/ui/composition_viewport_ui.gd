extends OpenXRCompositionLayerQuad
class_name CompositionViewportUI

const NO_POINTER := Vector2(-1.0, -1.0)
const TARGET_GROUP := "operator_interaction_target"
const COL_ACCENT := Color(1.0, 0.647, 0.169, 0.98)
const COL_ACCENT_MUTED := Color(1.0, 0.647, 0.169, 0.78)

var interaction_priority := 50
var _viewport: SubViewport
var _viewport_size := Vector2i.ZERO
var _cursor: Panel
var _pointer_position := NO_POINTER
var _pointer_pressed := false
var _feedback_input_mode := "controllers"
var _feedback_controller: XRController3D


func _setup_viewport_layer(
		viewport_name: String,
		viewport_size: Vector2i,
		quad_size_m: Vector2,
		layer_sort_order: int,
		cursor_size: float = 18.0
) -> SubViewport:
	add_to_group(TARGET_GROUP)
	_viewport_size = viewport_size
	quad_size = quad_size_m
	alpha_blend = true
	sort_order = layer_sort_order

	_viewport = SubViewport.new()
	_viewport.name = viewport_name
	_viewport.size = _viewport_size
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	layer_viewport = _viewport

	_build_cursor(cursor_size)
	return _viewport


## Widen (or narrow) the layer without resizing what it renders: the
## viewport and the quad grow together, so a pixel keeps its metre scale and
## text stays the same physical size. Used by panels whose content is not
## length-bounded — a discovered robot's name and address, say — so a long
## row gets more room instead of being clipped.
func set_viewport_width(width_px: int) -> void:
	if _viewport == null or width_px <= 0 or width_px == _viewport_size.x:
		return
	var metres_per_px := quad_size.x / float(_viewport_size.x)
	quad_size = Vector2(width_px * metres_per_px, quad_size.y)
	set_viewport_size(Vector2i(width_px, _viewport_size.y))


## Resize what the layer renders. Godot 4.5's OpenXR layer provider records
## the viewport size only when a viewport is bound, and its swapchain keeps
## that size: a visible layer resized in place goes on rendering into the old
## swapchain, so the whole panel is stretched and cropped. Unbinding frees
## that swapchain and rebinding allocates one at the new size, so every
## runtime resize of a composition-layer panel must go through here.
func set_viewport_size(size_px: Vector2i) -> void:
	if _viewport == null or size_px.x <= 0 or size_px.y <= 0 or size_px == _viewport_size:
		return
	_viewport_size = size_px
	_viewport.size = size_px
	layer_viewport = null
	layer_viewport = _viewport


func update_pointer_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	if _viewport == null:
		return false
	var uv: Vector2 = intersects_ray(ray_origin, ray_direction)
	if uv.x < 0.0 or uv.y < 0.0:
		clear_pointer()
		return false

	var next_position := Vector2(uv.x * _viewport_size.x, uv.y * _viewport_size.y)
	if next_position != _pointer_position:
		var motion := InputEventMouseMotion.new()
		motion.position = next_position
		motion.global_position = next_position
		_viewport.push_input(motion)
	_pointer_position = next_position
	if _cursor:
		_cursor.position = next_position - (_cursor.size * 0.5)
		_cursor.visible = true
	return true


func set_pointer_pressed(pressed: bool) -> void:
	if pressed == _pointer_pressed:
		return
	if pressed and _pointer_position == NO_POINTER:
		return
	if _viewport == null:
		return

	_pointer_pressed = pressed
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = _pointer_position
	event.global_position = _pointer_position
	_viewport.push_input(event)


func set_feedback_input_mode(mode: String, controller: XRController3D = null) -> void:
	_feedback_input_mode = mode
	_feedback_controller = controller


func clear_pointer() -> void:
	if _pointer_pressed:
		# BaseButton tracks pressing_inside from motion, not release coordinates.
		# Send an outside motion while captured before releasing the button.
		var motion := InputEventMouseMotion.new()
		motion.position = NO_POINTER
		motion.global_position = NO_POINTER
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		_viewport.push_input(motion)
		_pointer_position = NO_POINTER
		set_pointer_pressed(false)
	_pointer_position = NO_POINTER
	if _cursor:
		_cursor.visible = false
	_on_pointer_cleared()


func cancel_pointer() -> void:
	clear_pointer()


func get_interaction_priority() -> int:
	return interaction_priority


func is_interaction_target_visible() -> bool:
	return is_inside_tree() and visible


func get_ray_hit_point(ray_origin: Vector3, ray_direction: Vector3) -> Vector3:
	var direction := ray_direction.normalized()
	if direction.length_squared() < 0.000001:
		return ray_origin
	var normal := global_transform.basis.z.normalized()
	var denominator := normal.dot(direction)
	if absf(denominator) < 0.0001:
		return ray_origin + direction * 0.25
	var distance_m := normal.dot(global_transform.origin - ray_origin) / denominator
	return ray_origin + direction * maxf(distance_m, 0.001)


func _on_pointer_cleared() -> void:
	pass


func _play_feedback(action: String, volume_db: float = 0.0, _spatial_node: Node3D = null) -> void:
	if _feedback_input_mode == "hands":
		var sound_bus := _get_ui_sound_bus()
		if sound_bus != null and sound_bus.has_method("play"):
			sound_bus.call("play", action, volume_db)
	elif _feedback_input_mode == "controllers":
		var haptics := _get_haptics_bus()
		var use_haptics := _feedback_controller != null
		if haptics != null and haptics.has_method("should_use_controller_feedback"):
			use_haptics = bool(haptics.call("should_use_controller_feedback", _feedback_controller))
		if use_haptics and haptics != null and haptics.has_method("fire_ui_event"):
			haptics.call("fire_ui_event", action, _feedback_controller)
		else:
			var sound_bus := _get_ui_sound_bus()
			if sound_bus != null and sound_bus.has_method("play"):
				sound_bus.call("play", action, volume_db)


func _get_ui_sound_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("UISoundBus")


func _get_haptics_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Haptics")


func _build_cursor(cursor_size: float) -> void:
	_cursor = Panel.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.size = Vector2(cursor_size, cursor_size)
	var cursor_style := StyleBoxFlat.new()
	cursor_style.bg_color = COL_ACCENT_MUTED
	cursor_style.set_corner_radius_all(int(cursor_size * 0.5))
	_cursor.add_theme_stylebox_override("panel", cursor_style)
	_viewport.add_child(_cursor)
