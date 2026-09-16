extends RefCounted
## Actual host G1 over HTTP, runtime GLTF import, animation, and content cache.
const CASE_ID := "blueprint.robot_model"
const View := preload("res://scripts/blueprint/robot_model_view.gd")
const Cache := preload("res://scripts/blueprint/robot_asset_cache.gd")
const Profile := preload("res://scripts/blueprint/robot_asset_profile.gd")
const Runtime := preload("res://scripts/blueprint/blueprint_runtime.gd")
const Shell := preload("res://scripts/blueprint/system_menu_host.gd")
const CONFIG_PATH := "/sdcard/Android/data/com.lovemoon.operator/files/robot_asset_test.json"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not t.is_true(raw is Dictionary, "host asset configuration exists (run cicd/09_blueprint_robot_assets.sh)"):
		return
	var config := raw as Dictionary
	var properties: Dictionary = config["properties"]
	var path := Cache.cache_path(str(properties["asset_sha256"]))
	if not t.is_true(not path.is_empty(), "cache key is a validated SHA-256"):
		return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var names: Array = properties["joint_names"]
	names.reverse()
	t.eq(names.size(), 29, "host model describes the real 29-DoF G1")
	properties["smoothing_ms"] = 0
	var tree := Engine.get_main_loop() as SceneTree
	var view := View.new()
	if not t.is_true(view.configure(properties, "127.0.0.1"), "robot-owned reference is accepted"):
		view.free()
		return
	var q: Array = []
	q.resize(29)
	q.fill(0.0)
	var knee := names.find("left_knee_joint")
	q[knee] = 0.6
	var base := [0.3, 0.8, -2.0, 0.0, sin(0.25), 0.0, cos(0.25)]
	t.is_true(view.update_sample(q, base, 1), "state is buffered before asset arrival")
	tree.root.add_child(view)
	await _wait_ready(view, tree)
	if not t.is_true(view.is_asset_ready(), "actual G1 downloads and imports on headset", {"error": view.get("_error")}):
		view.free()
		return
	t.eq(view.asset_source, "network", "first load uses robot asset service")
	var root: Node3D = view.get("_root")
	t.is_true(root.position.is_equal_approx(Vector3(0.3, 0.8, -2.0)), "buffered base translation applies")
	t.almost_eq(root.quaternion.angle_to(Quaternion(Vector3.UP, 0.5)), 0, 0.0001, "base quaternion uses xyzw")
	var joints: Array = view.get("_joints")
	var spec: Dictionary = joints[knee]
	var node: Node3D = spec["node"]
	var rest: Transform3D = spec["rest"]
	var axis: Vector3 = spec["axis"]
	t.is_true(node.transform.is_equal_approx(rest * Transform3D(Basis(axis, 0.6), Vector3.ZERO)), "joint names map to transmitted node indices/axes")
	view.update_sample(q, base, 2)
	view._process(0.02)
	var instance: Node3D = view.get("_instance")
	t.is_true(instance.visible, "fresh state renders downloaded robot")
	view.set("_received_us", Time.get_ticks_usec() - 600000)
	view._process(0.02)
	t.is_false(instance.visible, "stale robot is hidden")
	t.is_false(view.update_sample(q, base, 2), "unchanged token cannot revive stale data")
	var bad := q.duplicate()
	bad[0] = NAN
	t.is_false(view.update_sample(bad, base, 3), "NaN targets cannot corrupt transforms")
	t.is_true(view.update_sample(q, base, 3), "a fresh state resumes the stale model")
	var dark_render := await _render_snapshot(view, tree, "blueprint_robot_unlit.png", t, false, false)
	var lit_render := await _render_snapshot(view, tree, "blueprint_robot_lit.png", t, true, false)
	t.is_true(_brightness(lit_render) > _brightness(dark_render) + 0.003,
		"Blueprint lighting measurably brightens the real G1 on the headset GPU",
		{"unlit": _brightness(dark_render), "lit": _brightness(lit_render)})
	var first_render := await _render_snapshot(view, tree, "blueprint_robot_render.png", t)
	t.is_false(first_render == lit_render, "Blueprint ground grid changes the rendered scene")
	var moved := q.duplicate()
	moved[knee] = -0.5
	view.update_sample(moved, base, 4)
	var second_render := await _render_snapshot(view, tree, "blueprint_robot_moved.png", t)
	t.is_false(first_render == second_render, "joint motion changes the actual headset GPU image")
	view.free()
	await tree.process_frame
	var cached := View.new()
	cached.configure(properties, "127.0.0.1")
	tree.root.add_child(cached)
	await _wait_ready(cached, tree)
	t.is_true(cached.is_asset_ready(), "cached G1 imports on reconnect")
	t.eq(cached.asset_source, "cache", "second load verifies and reuses content cache")
	cached.free()
	await tree.process_frame
	var bytes := FileAccess.get_file_as_bytes(path)
	t.eq(Cache.digest(bytes), str(properties["asset_sha256"]), "cache matches published digest")
	var doc := Profile.parse(bytes)
	t.is_false(doc.is_empty(), "real asset satisfies safe GLB profile")
	_test_resource_budgets(bytes, doc, t)
	doc["buffers"][0]["uri"] = "file:///etc/passwd"
	t.is_true(Profile.parse(_with_document(bytes, doc)).is_empty(), "external buffer URIs rejected before import")
	doc["buffers"][0].erase("uri")
	doc["extensionsUsed"] = ["untrusted_extension"]
	t.is_true(Profile.parse(_with_document(bytes, doc)).is_empty(), "unapproved GLTF extensions rejected")
	t.eq(Cache.cache_path("../../elsewhere"), "", "hash cannot escape cache directory")
	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	corrupt.store_buffer(PackedByteArray([1, 2, 3]))
	corrupt.close()
	var repaired := View.new()
	repaired.configure(properties, "127.0.0.1")
	tree.root.add_child(repaired)
	await _wait_ready(repaired, tree)
	t.is_true(repaired.is_asset_ready(), "corrupt cache recovered through HTTP")
	t.eq(repaired.asset_source, "network", "corrupt content is never trusted")
	repaired.free()
	await tree.process_frame
	await _test_recenter(properties, q, base, tree, t)
	var missing := View.new()
	var missing_properties := properties.duplicate(true)
	missing_properties["asset_sha256"] = "0".repeat(64)
	missing.configure(missing_properties, "127.0.0.1")
	tree.root.add_child(missing)
	await _wait_ready(missing, tree)
	t.is_false(missing.is_asset_ready(), "HTTP failure never falls back to bundled robot")
	t.is_true(not str(missing.get("_error")).is_empty(), "download errors surfaced")
	missing.free()
	var cancelled := View.new()
	cancelled.configure(missing_properties, "127.0.0.1")
	tree.root.add_child(cancelled)
	cancelled.free()
	await tree.process_frame
	t.log_line("G1 validated: HTTP -> SHA-256 -> runtime GLTF -> joint/base animation -> cache")


func _render_snapshot(view: Node3D, tree: SceneTree, filename: String, t: OperatorTestAssertions,
		lit: bool = true, grid_visible: bool = true) -> PackedByteArray:
	# Render the downloaded model on the device GPU, not a desktop fixture or
	# a visibility-flag-only assertion. The dedicated viewport isolates the
	# test camera from the headset's live XR rig.
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 640)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(viewport)
	var stage := Node3D.new()
	viewport.add_child(stage)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(1.7, 1.25, -4.2)
	camera.look_at(Vector3(0.3, 0.8, -2.0))
	camera.fov = 45
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.04, 0.05, 0.065)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.2
	camera.environment = environment
	# Exercise the public Blueprint path, not a test-only Godot light/grid.
	var runtime := Runtime.new()
	stage.add_child(runtime)
	runtime.configure(null, null, null, null, null)
	t.is_true(runtime.apply_blueprint({
		"schema": BlueprintContract.BLUEPRINT_SCHEMA, "blueprint_id": "device.render_stage", "revision": 1,
		"components": [
			{"id": "ground", "type": "ground_grid", "transform": {"position": [0.3, 0.002, -2]},
				"properties": {"visible": grid_visible}},
			{"id": "lighting", "type": "model_lighting", "properties": {"visible": lit}},
		],
	}), "floor and light are created from a normal Blueprint")
	var previous_parent := view.get_parent()
	view.reparent(stage)
	view.set_process(false)
	# Hold the same fresh host pose across captures; shader compilation/readback
	# time must not turn this lighting comparison into another stale-data test.
	view.set("_received_us", Time.get_ticks_usec())
	view._process(0.02)
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var picture := viewport.get_texture().get_image()
	var result := PackedByteArray()
	if t.is_true(picture != null and not picture.is_empty(), "device GPU produced a robot image"):
		picture.convert(Image.FORMAT_RGBA8)
		var background := picture.get_pixel(0, 0)
		var foreground := 0
		for y in range(0, picture.get_height(), 8):
			for x in range(0, picture.get_width(), 8):
				var pixel := picture.get_pixel(x, y)
				if absf(pixel.r - background.r) + absf(pixel.g - background.g) + absf(pixel.b - background.b) > 0.12:
					foreground += 1
		t.is_true(foreground > 100, "rendered robot occupies more than a few pixels")
		var directory := "/sdcard/Android/data/com.lovemoon.operator/files/test_results"
		DirAccess.make_dir_recursive_absolute(directory)
		t.eq(picture.save_png(directory.path_join(filename)), OK, "device robot screenshot is saved")
		result = picture.get_data()
	view.reparent(previous_parent)
	view.set_process(true)
	viewport.free()
	return result


func _brightness(bytes: PackedByteArray) -> float:
	if bytes.is_empty():
		return 0.0
	var total := 0.0
	for offset in range(0, bytes.size(), 4):
		total += 0.2126 * bytes[offset] + 0.7152 * bytes[offset + 1] + 0.0722 * bytes[offset + 2]
	return total / (255.0 * float(bytes.size() / 4))


func _test_recenter(properties: Dictionary, q: Array, base: Array, tree: SceneTree, t: OperatorTestAssertions) -> void:
	var origin := XROrigin3D.new()
	tree.root.add_child(origin)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	camera.position = Vector3(1.4, 1.6, 2.0)
	camera.basis = Basis(Vector3.UP, 0.8) * Basis(Vector3.RIGHT, -0.9)
	var runtime := Runtime.new()
	origin.add_child(runtime)
	runtime.configure(origin, camera, null, null, null)
	runtime.asset_host = "127.0.0.1"
	var blueprint := {
		"schema": BlueprintContract.BLUEPRINT_SCHEMA, "blueprint_id": "device.recenter", "revision": 1,
		"components": [{"id": "robot", "type": "robot_model", "properties": properties,
			"transform": {"position": [0, 0, -2]},
			"bindings": {"joint_positions": "q", "base_pose": "base", "sample": "sample"}},
			{"id": "ground", "type": "ground_grid", "properties": {"placement_target": "robot"},
				"transform": {"position": [0, 0.002, -2]}},
			{"id": "lighting", "type": "model_lighting"}],
	}
	t.is_true(runtime.apply_blueprint(blueprint), "recenter target is a regular robot Blueprint component")
	var state := {"schema": BlueprintContract.STATE_SCHEMA, "blueprint_id": "device.recenter", "blueprint_revision": 1,
		"sequence": 1, "timestamp_ns": 1, "values": {"q": q, "base": base, "sample": 1}}
	runtime.apply_state(state)
	var model := runtime.component_node("robot")
	await _wait_ready(model, tree)
	if not t.is_true(model.is_asset_ready(), "recenter test uses the real downloaded rig"):
		origin.free()
		return
	var root: Node3D = model.get("_root")
	var before := root.global_transform
	var grid := runtime.component_node("ground")
	var grid_before := grid.global_position
	var source_before: Dictionary = (runtime.get("_state_values") as Dictionary).duplicate(true)
	var remote_events: Array = []
	runtime.event_emitted.connect(func(event: Dictionary) -> void: remote_events.append(event))
	var shell := Shell.new()
	origin.add_child(shell)
	shell.configure(origin, camera, null, null, null, runtime)
	shell.update_context(true, false, true, true)
	shell.runtime.dispatch_menu(shell.runtime.menu_entries()[1]["token"], false)
	var after := root.global_transform
	var forward := -camera.global_basis.z
	forward.y = 0
	var expected := camera.global_position + forward.normalized() * 2.0
	expected.y = before.origin.y
	t.is_true(after.origin.is_equal_approx(expected), "menu places actual robot root two metres horizontally ahead")
	t.is_true(after.basis.is_equal_approx(before.basis), "recenter preserves robot heading and pose")
	t.is_true(grid.global_position.is_equal_approx(grid_before + after.origin - before.origin),
		"linked grid shares the robot's recenter translation and keeps its floor height")
	var grid_after := grid.global_position
	t.eq(runtime.get("_state_values"), source_before, "recenter does not mutate host state/base_pose")
	t.eq(remote_events.size(), 0, "recenter never sends reset or pose commands to the host")
	camera.position.x += 1.0
	runtime._process(0.02)
	t.is_true(root.global_position.is_equal_approx(after.origin), "placement stays world locked after the head moves")
	var new_base := base.duplicate()
	new_base[0] = float(new_base[0]) + 0.25
	state["sequence"] = 2
	state["values"] = {"q": q, "base": new_base, "sample": 2}
	runtime.apply_state(state)
	t.is_true(root.global_position.is_equal_approx(after.origin + Vector3(0.25, 0, 0)), "new host base updates preserve the local placement offset")
	t.is_true(grid.global_position.is_equal_approx(grid_after), "walking base updates do not drag the ground grid")
	t.is_true(Runtime.front_translation(Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 1.6, 0)), before.origin, 2) is Vector3,
		"looking straight down still has a horizontal placement direction")
	shell.free()
	runtime.set_suspended(true)
	t.is_false(grid.visible, "suspension hides the grid")
	var lighting := runtime.component_node("lighting")
	t.is_false(lighting.is_visible_in_tree(), "suspension disables model lighting")
	runtime.set_suspended(false)
	t.is_true(grid.visible and lighting.is_visible_in_tree(), "resuming restores declared stage components")
	runtime.clear()
	t.is_false(grid.visible or lighting.visible, "disconnect immediately hides the floor and lights before deferred deletion")
	origin.free()
	await tree.process_frame


func _wait_ready(view: Node3D, tree: SceneTree) -> void:
	var deadline := Time.get_ticks_msec() + 40000
	while not view.is_asset_ready() and str(view.get("_error")).is_empty() and Time.get_ticks_msec() < deadline:
		await tree.process_frame


func _with_document(original: PackedByteArray, doc: Dictionary) -> PackedByteArray:
	var binary := original.slice(28 + original.decode_u32(12))
	var json := JSON.stringify(doc).to_utf8_buffer()
	while json.size() % 4 != 0:
		json.append(32)
	var bytes := PackedByteArray()
	bytes.resize(20)
	bytes.encode_u32(0, 0x46546c67)
	bytes.encode_u32(4, 2)
	bytes.encode_u32(8, 28 + json.size() + binary.size())
	bytes.encode_u32(12, json.size())
	bytes.encode_u32(16, 0x4e4f534a)
	bytes.append_array(json)
	var header := PackedByteArray()
	header.resize(8)
	header.encode_u32(0, binary.size())
	header.encode_u32(4, 0x004e4942)
	bytes.append_array(header)
	bytes.append_array(binary)
	return bytes


func _test_resource_budgets(bytes: PackedByteArray, doc: Dictionary, t: OperatorTestAssertions) -> void:
	var indexed := doc.duplicate(true)
	var view_index: int = indexed["bufferViews"].size()
	indexed["bufferViews"].append({"buffer": 0, "byteOffset": 0, "byteLength": 6_000_000})
	var accessor_index: int = indexed["accessors"].size()
	indexed["accessors"].append({"bufferView": view_index, "componentType": 5123, "type": "SCALAR", "count": 3_000_000})
	# Reuse the smallest real mesh so POSITION totals remain under budget.
	var smallest := 0
	var smallest_count := 3_000_000
	for i in range(indexed["meshes"].size()):
		var position: int = indexed["meshes"][i]["primitives"][0]["attributes"]["POSITION"]
		var count: int = indexed["accessors"][position]["count"]
		if count < smallest_count:
			smallest = i
			smallest_count = count
	var primitive: Dictionary = indexed["meshes"][smallest]["primitives"][0].duplicate(true)
	primitive["indices"] = accessor_index
	indexed["meshes"][smallest]["primitives"] = [primitive, primitive, primitive, primitive]
	t.is_true(Profile.parse(_with_document(bytes, indexed)).is_empty(), "aliased indices cannot bypass decoded-resource budget")
	t.eq(Profile.last_error, "mesh index budget exceeded", "index budget rejects before invoking GLTF")
	var instanced := doc.duplicate(true)
	var root: int = instanced["extras"]["operator_robot"]["root"]
	# Repeat every existing visual mesh four times without copying binary data.
	for mesh_index in range(instanced["meshes"].size()):
		for _copy in range(4):
			var node_index: int = instanced["nodes"].size()
			instanced["nodes"].append({"mesh": mesh_index})
			instanced["nodes"][root]["children"].append(node_index)
	t.is_true(Profile.parse(_with_document(bytes, instanced)).is_empty(), "instanced geometry is included in render budgets")
	t.eq(Profile.last_error, "mesh instance budget exceeded", "instance budget rejects before invoking GLTF")
