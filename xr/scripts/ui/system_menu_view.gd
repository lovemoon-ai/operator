extends "res://scripts/ui/hand_unlock_button.gd"
## One panel, two input presenters. Robot declarations never instantiate this.
signal item_activated(item: Dictionary)
const MENU_ACTION := &"menu_button"
const HEIGHT_ABOVE_CONTROLLER_M := 0.24
const PAGE_SIZE := 2
var _groups := {"system": [], "robot": []}
var _rows: Dictionary = {}
var _page := 0
var _detail_label: Label
var _anchor_controller: XRController3D
var _pointer_tracker: StringName
var _head: XRCamera3D
var _mode := "head"
var _enabled := false
var _menu_open := false
var _toggle_initialized := false
var _toggle_down := false
var _source: Array = []
var _ray_pressed_action := &""


func _ready() -> void:
	add_to_group(TARGET_GROUP)
	sort_order = 1
	interaction_priority = 40
	_build_slots()
	visibility_changed.connect(func() -> void:
		if not is_visible_in_tree():
			cancel_interaction())


func configure_controller(left: XRController3D, right_tracker: StringName, head: XRCamera3D) -> void:
	_anchor_controller = left
	_pointer_tracker = right_tracker
	_head = head
	close_menu()


func set_content(groups: Dictionary, detail: String) -> void:
	if groups != _groups:
		cancel_interaction()
		var needs_layout: bool = (_groups["robot"].is_empty() != groups["robot"].is_empty())
		_groups = groups.duplicate(true)
		_page = mini(_page, maxi(0, ceili(float(_groups["robot"].size()) / PAGE_SIZE) - 1))
		if needs_layout and is_inside_tree():
			_build_slots()
		_assign_rows()
	if _detail_label != null:
		_detail_label.text = detail


func _build_slots() -> void:
	# Shared visual vocabulary with the former palm menu; fixed system rows
	# and paged robot rows avoid a panel that grows beyond the user's reach.
	_title.get_parent().free()
	_buttons.clear()
	_glows.clear()
	_flashes.clear()
	_action_rects.clear()
	var expanded: bool = not _groups["robot"].is_empty()
	# Robot rows can arrive while the menu is open; resizing through the
	# rebinding path keeps the panel from being drawn into its old swapchain.
	set_viewport_size(Vector2i(360, 500 if expanded else 280))
	var root := Control.new()
	_viewport.add_child(root)
	_title = _label(root, tr("UI_CONTROLLER_SESSION_MENU"), Rect2(18, 8, 324, 34), 25)
	_add_action_button(root, &"system_0", Rect2(18, 48, 324, 64))
	_add_action_button(root, &"system_1", Rect2(18, 122, 324, 64))
	if expanded:
		_label(root, tr("UI_MENU_ROBOT_ACTIONS"), Rect2(18, 190, 324, 26), 18)
		_add_action_button(root, &"robot_0", Rect2(18, 220, 324, 70))
		_add_action_button(root, &"robot_1", Rect2(18, 300, 324, 70))
		_add_action_button(root, &"previous", Rect2(18, 380, 156, 44))
		_add_action_button(root, &"next", Rect2(186, 380, 156, 44))
	_detail_label = _label(root, "", Rect2(18, 430 if expanded else 196, 324, 74), 17)
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for button_v in _buttons.values():
		var button: Button = button_v
		button.add_theme_font_size_override("font_size", 22)
		button.clip_text = true
	_assign_rows()
	_update_size()


func _label(root: Node, text_value: String, rect: Rect2, font_size: int) -> Label:
	var label := Label.new()
	label.text = text_value
	label.position = rect.position
	label.size = rect.size
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(label)
	return label


func _assign_rows() -> void:
	_rows.clear()
	for index in range(mini(2, _groups["system"].size())):
		_rows[StringName("system_%d" % index)] = _groups["system"][index]
	for index in range(PAGE_SIZE):
		var remote_index := _page * PAGE_SIZE + index
		if remote_index < _groups["robot"].size():
			_rows[StringName("robot_%d" % index)] = _groups["robot"][remote_index]
	_refresh()


func _update_size() -> void:
	var width := 0.18 if _mode == "hands" else 0.27
	quad_size = Vector2(width, width * float(_viewport_size.y) / float(_viewport_size.x))


func update_presentation(mode: String, enabled: bool, palm: Dictionary, head_local: Transform3D,
		tip: Variant, delta: float) -> void:
	if mode != _mode or enabled != _enabled:
		close_menu()
		_mode = mode
		_enabled = enabled
		_update_size()
	if not enabled:
		close_menu()
		return
	if mode == "hands":
		set_feedback_input_mode("hands")
		update_palm_menu(palm, head_local, tip, false, true, true, delta)
		return
	if mode != "controllers" or not _anchor_ready():
		close_menu()
		return
	var source: Array = []
	for name_v in [_anchor_controller.tracker, _pointer_tracker]:
		var tracker := XRServer.get_tracker(name_v)
		source.append(tracker.get_instance_id() if tracker != null else 0)
	if source != _source:
		close_menu()
		_source = source
	var down := _anchor_controller.is_button_pressed(MENU_ACTION)
	if _toggle_initialized and down and not _toggle_down:
		_menu_open = not _menu_open
		cancel_interaction()
	_toggle_initialized = true
	_toggle_down = down
	if not _menu_open:
		visible = false
		_has_smoothed_transform = false
		return
	var target := face_head_transform(_anchor_controller.global_position + Vector3.UP * HEIGHT_ABOVE_CONTROLLER_M, _head.global_transform)
	var parent := get_parent() as Node3D
	_update_smoothed_transform(parent.global_transform.affine_inverse() * target if parent != null else target, delta)
	visible = true
	_flash_remaining = maxf(0.0, _flash_remaining - delta)
	_refresh_pointer_feedback()


func _anchor_ready() -> bool:
	if not is_instance_valid(_anchor_controller) or not is_instance_valid(_head):
		return false
	if not transform_is_safe(_anchor_controller.global_transform) or not transform_is_safe(_head.global_transform):
		return false
	var interaction := get_node_or_null("/root/OperatorInteraction")
	return interaction != null and bool(interaction.call("is_controller_source_active", _anchor_controller))


func close_menu() -> void:
	_menu_open = false
	_toggle_initialized = false
	_toggle_down = false
	_visibility_state.reset()
	_has_smoothed_transform = false
	cancel_interaction()
	visible = false


func cancel_interaction() -> void:
	clear_pointer()
	cancel_touch()
	_clear_trigger_feedback()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_RESUMED:
		close_menu()


func _action_available(action: StringName) -> bool:
	if action == &"previous":
		return _page > 0
	if action == &"next":
		return (_page + 1) * PAGE_SIZE < _groups["robot"].size()
	return bool((_rows.get(action, {}) as Dictionary).get("available", false))


func _action_status_text(action: StringName) -> String:
	if action == &"previous":
		return "<"
	if action == &"next":
		return "%d / %d  >" % [_page + 1, maxi(1, ceili(float(_groups["robot"].size()) / PAGE_SIZE))]
	var row: Dictionary = _rows.get(action, {})
	var title := str(row.get("title", ""))
	var text_value := str(row.get("text", "")) if bool(row.get("available", false)) else str(row.get("unavailable_text", ""))
	return (title + "\n" if not title.is_empty() else "") + text_value


func _trigger_action(action: StringName) -> void:
	if not _enabled or not is_visible_in_tree() or not _action_available(action):
		return
	if action in [&"previous", &"next"]:
		cancel_interaction()
		_page += -1 if action == &"previous" else 1
		_assign_rows()
	elif _rows.has(action):
		item_activated.emit((_rows[action] as Dictionary).duplicate(true))
	_play_feedback("click", 0.0, self)


func _touch_state(local_tip: Vector3) -> Dictionary:
	var pixel := Vector2((local_tip.x / quad_size.x + 0.5) * _viewport_size.x,
		(0.5 - local_tip.y / quad_size.y) * _viewport_size.y)
	for action in _action_rects:
		var rect: Rect2 = _action_rects[action]
		if rect.has_point(pixel) and _action_available(action):
			if absf(local_tip.z) <= PRESS_DISTANCE_M:
				return {"action": action, "phase": "press"}
			if absf(local_tip.z) <= ARM_MAX_DISTANCE_M:
				return {"action": action, "phase": "arm"}
	return {"action": &"", "phase": "idle"}


func _action_touch_released(action: StringName, local_tip: Vector3) -> bool:
	return absf(local_tip.z) >= RELEASE_DISTANCE_M or _touch_state(local_tip)["action"] != action


func is_interaction_target_visible() -> bool:
	return _enabled and _mode == "controllers" and _menu_open and is_visible_in_tree()


func captures_teleop_input() -> bool:
	return true


func captures_teleop_scroll() -> bool:
	return false


func _accepts_pointer() -> bool:
	if _feedback_input_mode != "controllers" or not is_instance_valid(_feedback_controller) or not _anchor_ready():
		return false
	var interaction := get_node_or_null("/root/OperatorInteraction")
	return _feedback_controller.tracker == _pointer_tracker \
		and transform_is_safe(_feedback_controller.global_transform) \
		and bool(interaction.call("is_controller_source_active", _feedback_controller))


func update_pointer_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	if not is_interaction_target_visible() or not _accepts_pointer() or not ray_origin.is_finite() \
			or not ray_direction.is_finite() or ray_direction.length_squared() < 0.000001:
		clear_pointer()
		return false
	var hit := super.update_pointer_from_ray(ray_origin, ray_direction)
	if _pointer_pressed and _action_at_pointer() != _ray_pressed_action:
		clear_pointer()
	_refresh_pointer_feedback()
	return hit


func _action_at_pointer() -> StringName:
	if _pointer_position != NO_POINTER:
		for action in _action_rects:
			var rect: Rect2 = _action_rects[action]
			if rect.has_point(_pointer_position):
				return StringName(action)
	return &""


func set_pointer_pressed(pressed: bool) -> void:
	if pressed == _pointer_pressed:
		return
	var action := _action_at_pointer()
	var eligible := action != &"" and _action_available(action) and is_interaction_target_visible() and _accepts_pointer()
	var activate := _pointer_pressed and not pressed and eligible and action == _ray_pressed_action
	_pointer_pressed = pressed and eligible
	_ray_pressed_action = action if _pointer_pressed else &""
	if activate:
		_trigger_action(action)
	_refresh_pointer_feedback()


func clear_pointer() -> void:
	_pointer_pressed = false
	_ray_pressed_action = &""
	super.clear_pointer()
	_refresh_pointer_feedback()


func _refresh_pointer_feedback() -> void:
	_refresh("press" if _pointer_pressed else "arm", _ray_pressed_action if _pointer_pressed else _action_at_pointer())
