extends RefCounted
const CASE_ID := "blueprint.controller_menu"
const Runtime := preload("res://scripts/blueprint/blueprint_runtime.gd")
const Host := preload("res://scripts/blueprint/system_menu_host.gd")
const Router := preload("res://scripts/ui/settings_interaction_router.gd")
const Surface := preload("res://scripts/ui/composition_viewport_ui.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var origin := XROrigin3D.new()
	tree.root.add_child(origin)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	camera.position = Vector3(0, 1.6, 0)
	var trackers: Array[XRPositionalTracker] = []
	var controllers: Array[XRController3D] = []
	for side in ["left", "right"]:
		var tracker := XRPositionalTracker.new()
		tracker.name = "operator_system_menu_test_" + side
		tracker.type = XRServer.TRACKER_CONTROLLER
		tracker.profile = "/interaction_profiles/bytedance/pico4s_controller"
		XRServer.add_tracker(tracker)
		var controller := XRController3D.new()
		controller.tracker = StringName(tracker.name)
		controller.pose = &"default"
		origin.add_child(controller)
		_set_pose(tracker, Transform3D(Basis.IDENTITY, Vector3(-0.2 if side == "left" else 0.2, 1, -0.5)))
		trackers.append(tracker)
		controllers.append(controller)
	var remote := Runtime.new()
	origin.add_child(remote)
	remote.configure(origin, camera, controllers[0], controllers[1], null)
	var host := Host.new()
	origin.add_child(host)
	host.configure(origin, camera, controllers[0], controllers[1], null, remote)
	host.set_process(false)
	var menu: Node3D = host.menu
	var local_events: Array = []
	var remote_events: Array = []
	host.connection_requested.connect(func(wanted: bool) -> void: local_events.append(wanted))
	remote.event_emitted.connect(func(event: Dictionary) -> void: remote_events.append(event))
	host.update_context(true, false, true, true)
	var spec := _definition()
	t.is_true(remote.apply_blueprint(spec), "new and compatibility declarations coexist")
	_state(remote, 1, true)
	t.eq(remote.component_node("control"), null, "menu_item is data, not a panel")
	t.eq(remote.component_node("legacy"), null, "legacy palm declaration cannot create another panel")
	t.eq(remote.component_node("controller"), null, "legacy controller declaration cannot create another panel")
	t.eq(remote.menu_entries().size(), 5, "explicit shared identity merges only identical rows")
	var groups: Dictionary = menu.get("_groups")
	t.eq(groups["system"].size(), 2, "system controls are retained")
	t.eq(groups["robot"].size(), 5, "robot rows are appended separately")
	var bad := spec.duplicate(true)
	bad["components"][1]["bindings"]["value"] = "other_value"
	t.is_false(remote.apply_blueprint(bad), "conflicting shared bindings fail before replacing current menu")
	var router := Router.new()
	origin.add_child(router)
	router.configure(origin, camera, controllers[0], controllers[1], null)
	router.controller_source_filter = func(_pointer: XRController3D) -> bool: return true
	router.set_targets([menu])
	trackers[0].set_input(&"menu_button", true)
	_present(menu)
	t.is_false(menu.visible, "held Menu at startup does not open")
	_toggle(trackers[0], menu)
	t.is_true(menu.visible, "fresh left Menu opens the sole system panel")
	_aim(trackers[1], menu, &"robot_0")
	router._on_controller_button_pressed(&"trigger_click", controllers[1])
	t.eq(remote_events.size(), 0, "ray press alone cannot submit")
	router._on_controller_button_released(&"trigger_click", controllers[1])
	t.eq(remote_events.size(), 1, "ray release submits once")
	if not remote_events.is_empty():
		t.eq(remote_events[0]["component_id"], "control", "canonical original component owns event")
		t.eq(remote_events[0]["blueprint_id"], spec["blueprint_id"], "event does not use system Blueprint identity")
		t.eq(remote_events[0]["action"], "connection.toggle", "remote action may have a system-like name")
	t.eq(local_events.size(), 0, "remote action name cannot invoke local connection handling")
	await _capture_menu(menu, tree, t)
	var token: Dictionary = remote.menu_entries()[0]["token"]
	_aim(trackers[1], menu, &"robot_0")
	router._on_controller_button_pressed(&"trigger_click", controllers[1])
	_state(remote, 2, false)
	router._on_controller_button_released(&"trigger_click", controllers[1])
	t.eq(remote_events.size(), 1, "disabling a row cancels its pending click")
	_state(remote, 3, true)
	_aim(trackers[1], menu, &"robot_0")
	router._on_controller_button_pressed(&"trigger_click", controllers[1])
	menu.call("update_presentation", "hands", true, {}, camera.transform, null, 0.02)
	router._on_controller_button_released(&"trigger_click", controllers[1])
	t.eq(remote_events.size(), 1, "source switch cannot release a controller click into hand mode")
	# The hand presenter uses the same panel with its actual palm-sized quad.
	var palm := {"tracked": true, "facing": 1.0, "openness": 1.0, "anchor_position": Vector3(-0.2, 1, -0.5)}
	for _frame in range(12):
		menu.call("update_presentation", "hands", true, palm, camera.transform, null, 0.02)
	t.is_true(menu.visible, "palm pose opens the same panel")
	var point := _slot_local(menu, &"robot_0")
	var near_tip := menu.transform * (point + Vector3(0, 0, 0.003))
	menu.call("update_presentation", "hands", true, palm, camera.transform, near_tip, 0.02)
	t.eq(remote_events.size(), 1, "finger already touching at activation must first withdraw")
	var arm_tip := menu.transform * (point + Vector3(0, 0, 0.04))
	menu.call("update_presentation", "hands", true, palm, camera.transform, arm_tip, 0.02)
	menu.call("update_presentation", "hands", true, palm, camera.transform, near_tip, 0.02)
	t.eq(remote_events.size(), 2, "palm touch reaches the same canonical remote item")
	_present(menu)
	_toggle(trackers[0], menu)
	_aim(trackers[1], menu, &"robot_0")
	router._on_controller_button_pressed(&"trigger_click", controllers[1])
	menu.call("_trigger_action", &"next")
	router._on_controller_button_released(&"trigger_click", controllers[1])
	t.eq(remote_events.size(), 2, "page changes cannot transfer an old press to another item")
	t.eq(menu.get("_page"), 1, "remote actions are paged")
	remote.set_suspended(true)
	remote.set_suspended(false)
	t.is_false(remote.dispatch_menu(token, false), "suspension invalidates queued source tokens")
	var prior: Dictionary = remote.menu_entries()[0]["token"]
	remote.apply_blueprint(spec)
	_state(remote, 1, true)
	t.is_false(remote.dispatch_menu(prior, false), "same ID/revision replacement still invalidates old clicks")
	_aim(trackers[1], menu, &"system_0")
	router._on_controller_button_pressed(&"trigger_click", controllers[1])
	trackers[1].invalidate_pose(&"default")
	router.controller_source_filter = Callable()
	router._update_controller_pointer()
	t.eq(local_events.size(), 0, "tracking loss cannot activate disconnect")
	remote.clear()
	host.update_context(false, false, true, true)
	t.eq(host.menu, menu, "disconnect retains the same physical menu")
	groups = menu.get("_groups")
	t.eq(groups["robot"].size(), 0, "disconnect removes all robot contributions")
	t.eq(groups["system"].size(), 2, "connection controls remain after disconnect")
	t.is_false(remote.dispatch_menu(prior, false), "old robot token cannot affect the system after disconnect")
	await _ordinary_button_cancel(origin, tree, t)
	host.free()
	remote.free()
	router.free()
	origin.free()
	for tracker in trackers:
		XRServer.remove_tracker(tracker)
	t.log_line("Completed unified-menu ownership, ray, palm, pagination, cancellation and lifecycle checks")


func _definition() -> Dictionary:
	var primary := {"id": "control", "type": "menu_item",
		"properties": {"title": "Remote", "action": "connection.toggle", "item_key": "shared.control",
			"locked_text": "Enable", "unlocked_text": "Disable", "unavailable_text": "Unavailable"},
		"bindings": {"value": "value", "available": "ready"}}
	var legacy := primary.duplicate(true)
	legacy["id"] = "legacy"
	legacy["type"] = "palm_menu"
	var controller := primary.duplicate(true)
	controller["id"] = "controller"
	controller["type"] = "controller_menu"
	controller["properties"]["secondary_action"] = "view.recenter"
	controller["properties"]["secondary_text"] = "Remote recenter"
	controller["bindings"]["secondary_available"] = "ready"
	var components: Array = [primary, legacy, controller]
	for i in range(3):
		var item := primary.duplicate(true)
		item["id"] = "extra_%d" % i
		item["properties"]["item_key"] = ""
		components.append(item)
	return {"schema": BlueprintContract.BLUEPRINT_SCHEMA, "blueprint_id": "device.system_menu", "revision": 1, "components": components}


func _state(runtime: Node, sequence: int, ready: bool) -> void:
	runtime.apply_state({"schema": BlueprintContract.STATE_SCHEMA, "blueprint_id": "device.system_menu",
		"blueprint_revision": 1, "sequence": sequence, "timestamp_ns": sequence, "values": {"value": false, "ready": ready}})


func _present(menu: Node) -> void:
	menu.call("update_presentation", "controllers", true, {}, Transform3D.IDENTITY, null, 0.02)


func _toggle(tracker: XRPositionalTracker, menu: Node) -> void:
	tracker.set_input(&"menu_button", false)
	_present(menu)
	tracker.set_input(&"menu_button", true)
	_present(menu)


func _slot_local(menu: Node3D, slot: StringName) -> Vector3:
	var rects: Dictionary = menu.get("_action_rects")
	var rect: Rect2 = rects[slot]
	var size: Vector2i = menu.get("_viewport_size")
	var quad: Vector2 = menu.get("quad_size")
	return Vector3((rect.get_center().x / size.x - 0.5) * quad.x, (0.5 - rect.get_center().y / size.y) * quad.y, 0)


func _aim(tracker: XRPositionalTracker, menu: Node3D, slot: StringName) -> void:
	var point := menu.global_transform * _slot_local(menu, slot)
	_set_pose(tracker, Transform3D(menu.global_basis, point + menu.global_basis.z * 0.4))


func _set_pose(tracker: XRPositionalTracker, pose: Transform3D) -> void:
	tracker.set_pose(&"default", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _capture_menu(menu: Node3D, tree: SceneTree, t: OperatorTestAssertions) -> void:
	# Composition layers render directly into the OpenXR swapchain; their
	# SubViewport texture readback can be blank. Render the actual UI Control
	# subtree in an ordinary on-device viewport for a pixel-level assertion.
	var preview := SubViewport.new()
	preview.size = menu.get("_viewport_size")
	preview.transparent_bg = true
	preview.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var title: Node = menu.get("_title")
	preview.add_child(title.get_parent().duplicate())
	tree.root.add_child(preview)
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var picture := preview.get_texture().get_image()
	if t.is_true(picture != null and not picture.is_empty(), "system menu renders on the device GPU"):
		var foreground := 0
		for y in range(0, picture.get_height(), 8):
			for x in range(0, picture.get_width(), 8):
				var pixel := picture.get_pixel(x, y)
				if pixel.a > 0.1 and pixel.r + pixel.g + pixel.b > 0.1:
					foreground += 1
		t.is_true(foreground > 100, "system menu image contains real button/text pixels, not a blank texture")
		var directory := "/sdcard/Android/data/com.lovemoon.operator/files/test_results"
		DirAccess.make_dir_recursive_absolute(directory)
		t.eq(picture.save_png(directory.path_join("system_menu.png")), OK, "system menu screenshot saved")
	preview.free()


func _ordinary_button_cancel(origin: Node3D, tree: SceneTree, t: OperatorTestAssertions) -> void:
	var surface := Surface.new()
	var viewport: SubViewport = surface._setup_viewport_layer("CancelTest", Vector2i(200, 100), Vector2(0.2, 0.1), 1)
	var button := Button.new()
	button.position = Vector2(20, 20)
	button.size = Vector2(160, 60)
	viewport.add_child(button)
	origin.add_child(surface)
	var clicks: Array = []
	button.pressed.connect(func() -> void: clicks.append(true))
	await tree.process_frame
	for cancel in [false, true, true]:
		var motion := InputEventMouseMotion.new()
		motion.position = Vector2(100, 50)
		viewport.push_input(motion)
		surface.set("_pointer_position", motion.position)
		surface.set_pointer_pressed(true)
		if cancel:
			surface.cancel_pointer()
		else:
			surface.set_pointer_pressed(false)
	t.eq(clicks.size(), 1, "real Godot Button clicks on release but never on repeated cancellation")
	surface.free()
