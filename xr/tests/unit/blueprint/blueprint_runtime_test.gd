extends RefCounted

const CASE_ID := "blueprint.runtime"
const RuntimeScript = preload(
	"res://scripts/blueprint/blueprint_runtime.gd"
)
const RobotModelScript = preload("res://scripts/blueprint/robot_model_view.gd")
const PathScript = preload("res://scripts/blueprint/path_view.gd")
const MarkerScript = preload("res://scripts/blueprint/marker_view.gd")
const TeleopControllerScript = preload(
	"res://scripts/app/modes/teleop_controller.gd"
)
const SessionScript = preload("res://scripts/network/session.gd")


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var rigid_view := RobotModelScript.new()
	t.is_true(
		rigid_view.configure(
			{
				"asset_sha256": "a".repeat(64),
				"asset_size": 100,
				"asset_port": 63904,
				"joint_names": [],
			},
			"127.0.0.1",
		),
		"zero-joint rigid model is accepted",
	)
	t.is_true(
		rigid_view.update_sample([], [0, 0, 0, 0, 0, 0, 1], 1),
		"zero-joint rigid model accepts a base-pose sample",
	)
	rigid_view.free()
	var path_view := PathScript.new()
	path_view.configure(BlueprintContract.resolved_properties({"type": "path"}))
	t.is_true(
		path_view.update_path([0, 0, 0, 0, 0, 0, 1, 0, 0], Color.WHITE),
		"path accepts finite points",
	)
	var path_mesh := path_view.mesh as ArrayMesh
	t.eq(path_mesh.surface_get_array_len(0), 8, "path drops repeated points")
	t.eq(path_mesh.surface_get_array_index_len(0), 36, "open path has one segment and two caps")
	t.is_false(
		path_view.update_path([0, 0, 0, NAN, 0, 0], Color.WHITE),
		"path rejects non-finite points",
	)
	t.eq(path_mesh.surface_get_array_len(0), 8, "rejected points keep the previous path")
	path_view.free()
	var closed_path := PathScript.new()
	closed_path.configure(
		BlueprintContract.resolved_properties({"type": "path", "properties": {"closed": true}})
	)
	t.is_true(
		closed_path.update_path([0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0], Color.WHITE),
		"closed path accepts a loop that repeats its first point",
	)
	t.eq(
		(closed_path.mesh as ArrayMesh).surface_get_array_index_len(0),
		72,
		"closed path joins its last point to the first without a duplicate",
	)
	closed_path.free()
	var marker_warnings: Array[String] = []
	var fallback_marker := MarkerScript.new()
	fallback_marker.warning_raised.connect(
		func(message: String) -> void: marker_warnings.append(message)
	)
	fallback_marker.configure(
		BlueprintContract.resolved_properties({"type": "marker", "properties": {"shape": "cube"}})
	)
	t.eq(marker_warnings.size(), 1, "an unknown marker shape raises one warning")
	var fallback_part := (
		(fallback_marker.get_child(0) as Node3D).get_child(0) as Node3D
	).get_child(0) as MeshInstance3D
	t.is_true(fallback_part.mesh is SphereMesh, "an unknown marker shape falls back to a sphere")
	t.is_false(
		fallback_marker.update_marker([0, 0], Color.WHITE, ""),
		"marker rejects a malformed position",
	)
	fallback_marker.free()
	t.is_true(
		SessionScript.descriptor_supports_blueprint({
			"capabilities": {
				BlueprintPrimitiveSpec.CAPABILITY: true,
				BlueprintPrimitiveSpec.SPEC_HASH_CAPABILITY: BlueprintPrimitiveSpec.SPEC_SHA256,
			},
		}),
		"headset accepts only the exact generated descriptor spec hash",
	)
	t.is_false(
		SessionScript.descriptor_supports_blueprint({
			"capabilities": {
				BlueprintPrimitiveSpec.CAPABILITY: true,
				BlueprintPrimitiveSpec.SPEC_HASH_CAPABILITY: "stale",
			},
		}),
		"headset rejects a stale descriptor spec hash",
	)
	t.is_true(
		SessionScript.DEDICATED_TELEMETRY_CAPABILITY \
			in (SessionScript.hello_payload().get("capabilities", []) as Array),
		"headset negotiates the dedicated telemetry channel in Hello",
	)
	var json_envelope := {
		"revision": 2.0,
		"sequence": 3.0,
		"timestamp_ns": 4.0,
		"fraction": 1.5,
	}
	SessionScript._normalize_json_wire_integers(
		json_envelope, ["revision", "sequence", "timestamp_ns", "fraction"]
	)
	t.is_true(json_envelope["revision"] is int, "JSON revision is normalized to int")
	t.is_true(json_envelope["sequence"] is int, "JSON sequence is normalized to int")
	t.is_true(json_envelope["timestamp_ns"] is int, "JSON timestamp is normalized to int")
	t.is_true(json_envelope["fraction"] is float, "fractional JSON numbers stay floats")
	for value_type_v in BlueprintPrimitiveSpec.VALUE_TYPE_CONFORMANCE:
		var value_type := str(value_type_v)
		var cases := BlueprintPrimitiveSpec.VALUE_TYPE_CONFORMANCE[value_type_v] as Dictionary
		for value_v in cases.get("valid", []) as Array:
			t.is_true(
				BlueprintContract.value_matches_type(value_v, value_type),
				"generated %s valid case is accepted" % value_type,
			)
		for value_v in cases.get("invalid", []) as Array:
			t.is_false(
				BlueprintContract.value_matches_type(value_v, value_type),
				"generated %s invalid case is rejected" % value_type,
				)
	for value_v in BlueprintPrimitiveSpec.WIRE_INTEGER_CONFORMANCE.get("valid", []) as Array:
		t.is_true(
			BlueprintContract.wire_integer_matches_type(value_v),
			"generated valid wire integer is accepted",
		)
	for value_v in BlueprintPrimitiveSpec.WIRE_INTEGER_CONFORMANCE.get("invalid", []) as Array:
		t.is_false(
			BlueprintContract.wire_integer_matches_type(value_v),
			"generated invalid wire integer is rejected",
		)
	for anchor_v in BlueprintPrimitiveSpec.ANCHORS:
		t.is_true(
			str(anchor_v) in RuntimeScript.ANCHOR_IMPLEMENTATIONS,
			"every generated anchor is registered by BlueprintRuntime",
		)
		t.eq(
			RuntimeScript.ANCHOR_IMPLEMENTATIONS.get(str(anchor_v)),
			(BlueprintPrimitiveSpec.ANCHOR_SPECS[anchor_v] as Dictionary).get("tracking"),
			"every registered anchor keeps the generated tracking contract",
		)
	for primitive_name_v in BlueprintPrimitiveSpec.PRIMITIVES:
		var primitive := BlueprintPrimitiveSpec.PRIMITIVES[primitive_name_v] as Dictionary
		var implementation := str(primitive.get("implementation", ""))
		var implementation_contract: Dictionary = {}
		if str(primitive.get("host", "")) == "node3d":
			t.is_true(
				implementation in RuntimeScript.NODE_IMPLEMENTATIONS,
				"every generated node implementation is registered by BlueprintRuntime",
			)
			implementation_contract = RuntimeScript.NODE_IMPLEMENTATIONS.get(
				implementation, {}
			) as Dictionary
		elif str(primitive.get("host", "")) == "system_menu":
			implementation_contract = RuntimeScript.MENU_IMPLEMENTATIONS.get(implementation, {})
		elif str(primitive.get("host", "")) == "external_view":
			t.is_true(
				implementation \
					in TeleopControllerScript.BLUEPRINT_EXTERNAL_VIEW_IMPLEMENTATIONS,
				"every generated external view implementation is registered by its host",
			)
			implementation_contract = TeleopControllerScript.BLUEPRINT_EXTERNAL_VIEW_CONTRACTS.get(
				implementation, {}
			) as Dictionary
		t.eq(
			_sorted_strings(implementation_contract.get("properties", [])),
			_sorted_strings((primitive.get("properties", {}) as Dictionary).keys()),
			"the implementation consumes every generated property",
		)
		t.eq(
			_sorted_strings(implementation_contract.get("bindings", [])),
			_sorted_strings((primitive.get("bindings", {}) as Dictionary).keys()),
			"the implementation consumes every generated binding",
		)
		t.eq(
			_sorted_strings(implementation_contract.get("events", [])),
			_sorted_strings((primitive.get("events", {}) as Dictionary).keys()),
			"the implementation consumes every generated event",
		)
		for event_name_v in (primitive.get("events", {}) as Dictionary):
			t.is_true(
				str(event_name_v) in RuntimeScript.EVENT_IMPLEMENTATIONS,
				"every generated event implementation is registered by BlueprintRuntime",
			)

	var compatible_bindings := {
		"schema": BlueprintContract.BLUEPRINT_SCHEMA,
		"blueprint_id": "compatible-bindings",
		"revision": 1,
		"components": [
			{"id": "label", "type": "label", "bindings": {"text": "shared"}},
			{"id": "status", "type": "status_lamp", "bindings": {"state": "shared"}},
		],
	}
	t.is_true(
		(BlueprintContract.parse_blueprint(compatible_bindings).get("errors", []) as Array).is_empty(),
		"binding requiredness does not change the shared state value contract",
	)
	var conflicting_bindings := compatible_bindings.duplicate(true)
	conflicting_bindings["blueprint_id"] = "conflicting-bindings"
	(conflicting_bindings["components"] as Array).append({
		"id": "menu",
		"type": "palm_menu",
		"properties": {"title": "Menu", "action": "toggle"},
		"bindings": {"value": "shared"},
	})
	t.is_false(
		(BlueprintContract.parse_blueprint(conflicting_bindings).get("errors", []) as Array).is_empty(),
		"one state key cannot have conflicting generated value contracts",
	)
	t.is_false(
		BlueprintContract.validate_bound_values(
			(compatible_bindings.get("components", []) as Array),
			{"shared_typo": "ready"},
		).is_empty(),
		"state keys not declared by any binding are rejected",
	)
	var invalid_transform := compatible_bindings.duplicate(true)
	invalid_transform["blueprint_id"] = "invalid-transform"
	((invalid_transform["components"] as Array)[0] as Dictionary)["transform"] = "identity"
	t.is_false(
		(BlueprintContract.parse_blueprint(invalid_transform).get("errors", []) as Array).is_empty(),
		"a non-object transform cannot be replaced silently by generated defaults",
	)
	var origin := XROrigin3D.new()
	var camera := XRCamera3D.new()
	var left_controller := XRController3D.new()
	var right_controller := XRController3D.new()
	var tracking_provider := Node.new()
	var runtime := RuntimeScript.new()
	var runtime_warnings: Array[String] = []
	var menu_change_count := 0
	runtime.warning_raised.connect(func(message: String) -> void: runtime_warnings.append(message))
	runtime.menu_changed.connect(func() -> void: menu_change_count += 1)
	origin.add_child(camera)
	origin.add_child(left_controller)
	origin.add_child(right_controller)
	origin.add_child(tracking_provider)
	origin.add_child(runtime)
	var external_views: Array[String] = []
	external_views.assign(TeleopControllerScript.BLUEPRINT_EXTERNAL_VIEW_IMPLEMENTATIONS)
	runtime.configure(
		origin,
		camera,
		left_controller,
		right_controller,
		tracking_provider,
		external_views,
	)
	var builtin_changes: Array[Dictionary] = []
	runtime.external_view_changed.connect(
		func(
			component_id: String,
			component_type: String,
			visible: bool,
			properties: Dictionary,
		) -> void:
			builtin_changes.append({
				"id": component_id,
				"type": component_type,
				"visible": visible,
				"properties": properties.duplicate(true),
			})
	)

	var blueprint_id := "unit.blueprint.%d" % Time.get_ticks_usec()
	# Contract-only case: the separate device case loads an actual robot-hosted
	# G1. This fixture must not depend on any Inside Robot bundle.
	var robot_joint_names: Array = ["left_knee_joint"]
	runtime.asset_host = "127.0.0.1"
	var blueprint := {
		"schema": BlueprintContract.BLUEPRINT_SCHEMA,
		"blueprint_id": blueprint_id,
		"revision": 2,
		"components": [
			{
				"id": "message",
				"type": "label",
				"anchor": "world",
				"properties": {"text": "Waiting", "visible": true, "font_size": 28},
				"bindings": {"text": "robot.message", "visible": "ui.message_visible"},
				"user_overridable": true,
			},
			{
				"id": "status",
				"type": "status_lamp",
				"anchor": "right_controller",
				"properties": {"text": "Robot"},
				"bindings": {"state": "robot.state", "text": "robot.name"},
				"user_overridable": false,
			},
			{
				"id": "hand_control",
				"type": "palm_menu",
				"properties": {"title": "Hand control", "action": "toggle_unlock"},
				"bindings": {"value": "hand.unlocked", "available": "hand.available"},
				"user_overridable": true,
			},
			{
				"id": "touch",
				"type": "fingertip_tactile",
				"anchor": "world",
				"properties": {"settings_label": "Fingertip touch"},
				"bindings": {
					"left_normal": "left.touch.normal",
					"left_tangential": "left.touch.tangential",
					"left_direction": "left.touch.direction",
					"left_proximity": "left.touch.proximity",
					"left_status": "left.touch.status",
					"sample": "touch.sample_ns",
				},
				"user_overridable": true,
			},
			{
				"id": "fpv",
				"type": "video_panel",
				"anchor": "world",
				"properties": {
					"follow_camera": true,
					"settings_label": "First-person video",
				},
				"bindings": {
					"visible": "video.visible",
					"follow_camera": "video.follow_camera",
				},
				"user_overridable": true,
			},
			{
				"id": "controller_help",
				"type": "controller_help",
				"anchor": "world",
				"properties": {"settings_label": "Controller help"},
				"bindings": {},
				"user_overridable": true,
			},
			{
				"id": "control_frame",
				"type": "control_frame",
				"anchor": "world",
				"properties": {"settings_label": "Control frame"},
				"bindings": {},
				"user_overridable": true,
			},
			{
				"id": "trajectory",
				"type": "operation_trajectory",
				"anchor": "world",
				"properties": {"settings_label": "Operation trajectory"},
				"bindings": {},
				"user_overridable": true,
			},
			{
				"id": "robot_model",
				"type": "robot_model",
				"properties": {"asset_sha256": "a".repeat(64), "asset_size": 100, "asset_port": 63904, "joint_names": robot_joint_names, "smoothing_ms": 0},
				"bindings": {"joint_positions": "g1.joints", "base_pose": "g1.base", "sample": "g1.sample"},
			},
			{
				"id": "controller_menu", "type": "controller_menu",
				"properties": {"title": "Controller", "action": "toggle_unlock"},
				"bindings": {"value": "hand.unlocked", "available": "hand.available"},
			},
			{
				"id": "reset", "type": "input_binding", "properties": {"action": "reset"},
				"bindings": {"available": "hand.available", "required": "reset.required", "acknowledged_request": "reset.ack", "success": "reset.ok"},
			},
			{"id": "ground", "type": "ground_grid", "properties": {"placement_target": "robot_model"}},
			{"id": "lighting", "type": "model_lighting", "bindings": {"key_energy": "lighting.key"}},
			{"id": "item", "type": "menu_item", "properties": {"title": "Item", "action": "toggle"}, "bindings": {"value": "hand.unlocked"}},
			{
				"id": "route", "type": "path", "properties": {"points": [0, 0, 0, 1, 0, 0], "width": 0.04},
				"bindings": {"points": "nav.path", "color": "nav.path_color"},
			},
			{
				"id": "goal", "type": "marker", "properties": {"shape": "ring", "text": "Goal"},
				"bindings": {"position": "nav.goal", "text": "nav.goal_text"},
			},
			{
				"id": "map", "type": "dense_map", "properties": {"display": "minimap"},
				"bindings": {"display": "map.display"},
			},
		],
	}
	var wire_blueprint_v: Variant = JSON.parse_string(JSON.stringify(blueprint))
	t.is_true(wire_blueprint_v is Dictionary, "wire Blueprint JSON decodes to an object")
	var wire_blueprint := wire_blueprint_v as Dictionary
	# Match the network boundary: Godot JSON decodes envelope integers as floats.
	SessionScript._normalize_json_wire_integers(wire_blueprint, ["revision"])
	var declared_types: Array[String] = []
	for component_v in wire_blueprint.get("components", []) as Array:
		declared_types.append(str((component_v as Dictionary).get("type", "")))
	declared_types.sort()
	var spec_types: Array[String] = []
	for primitive_name_v in BlueprintPrimitiveSpec.PRIMITIVES:
		spec_types.append(str(primitive_name_v))
	spec_types.sort()
	t.eq(declared_types, spec_types, "runtime fixture covers every generated primitive")
	if not t.is_true(
		runtime.apply_blueprint(wire_blueprint),
		"wire Blueprint accepts integral JSON numbers for integer properties",
		{"warnings": runtime_warnings, "parsed": BlueprintContract.parse_blueprint(wire_blueprint)},
	):
		origin.free()
		return
	t.eq(
		BlueprintContract.resolved_anchor(wire_blueprint["components"][2]),
		"left_palm",
		"palm menu anchor default comes from the generated spec",
	)
	t.eq(runtime.component_count(), 17, "blueprint registers rendered and XR-owned components")
	t.is_true(runtime.has_blueprint(), "runtime records the active blueprint")
	t.eq(builtin_changes.size(), 5, "XR-owned views emit one initial gate update each")
	t.is_true(runtime.component_visible("fpv"), "declared video view is initially visible")
	t.eq(runtime.component_node("fpv"), null, "XR-owned views reuse existing scene nodes")
	var visibility_options := runtime.user_visibility_options()
	t.eq(visibility_options.size(), 15, "all overridable components reach user settings")
	t.eq(visibility_options[0].get("id"), "message", "visibility options preserve blueprint order")
	t.eq(visibility_options[1].get("id"), "hand_control", "non-overridable UI is omitted")
	t.eq(visibility_options[2].get("id"), "touch", "tactile visibility is user-overridable")
	t.eq(visibility_options[3].get("id"), "fpv", "video visibility is user-overridable")

	var wrong_revision := _state(blueprint_id, 1, 1, {"robot.message": "wrong"})
	t.is_false(runtime.apply_state(wrong_revision), "state for another revision is rejected")
	t.is_false(
		runtime.apply_state(_state(blueprint_id, 2, 0, {"robot.message": "zero"})),
		"zero state sequence is rejected",
	)
	var current := _state(
		blueprint_id,
		2,
		1,
		{
			"robot.message": "Ready",
			"ui.message_visible": true,
			"robot.state": "active",
			"robot.name": "Dexterous hand",
			"hand.unlocked": false,
			"hand.available": true,
			"left.touch.normal": [0, 10, 100, 1000, 10000],
			"left.touch.tangential": [0, 20, 200, 2000, 20000],
			"left.touch.direction": [0, 45, 90, 180, 270],
			"left.touch.proximity": [0, 100, 1000, 10000, 100000],
			"left.touch.status": [0, 0, 0, 0, 0],
			"touch.sample_ns": 123456,
			"video.visible": true,
			"video.follow_camera": false,
		},
	)
	var robot_q: Array = []
	robot_q.resize(robot_joint_names.size())
	robot_q.fill(0.0)
	current["values"]["g1.joints"] = robot_q
	current["values"]["g1.base"] = [0.2, 0.8, -2.0, 0.0, 0.0, 0.0, 1.0]
	current["values"]["g1.sample"] = 1
	current["values"]["lighting.key"] = 2.0
	current["values"]["nav.path"] = [0, 0, 0, 1, 0, 0, 1, 0, 1, 2, 0]
	current["values"]["nav.goal"] = [1.0, 0.0, -2.0]
	var wire_state_v: Variant = JSON.parse_string(JSON.stringify(current))
	t.is_true(wire_state_v is Dictionary, "wire BlueprintState JSON decodes to an object")
	SessionScript._normalize_json_wire_integers(
		wire_state_v as Dictionary, ["blueprint_revision", "sequence", "timestamp_ns"]
	)
	t.is_true(
		runtime.apply_state(wire_state_v as Dictionary),
		"wire BlueprintState accepts integral JSON numbers in integer arrays",
	)
	var menu_changes_after_initial_state := menu_change_count
	var robot_node := runtime.component_node("robot_model")
	var grid := runtime.component_node("ground") as MeshInstance3D
	t.is_true(grid.mesh is PlaneMesh, "ground uses a bounded two-triangle plane")
	t.is_true(grid.material_override is ShaderMaterial, "ground uses the client-owned antialiased grid shader")
	var lights := runtime.component_node("lighting")
	var key_light := lights.get_child(0) as DirectionalLight3D
	t.almost_eq(key_light.light_energy, 2.0, 0.001, "key intensity follows Blueprint state")
	t.eq(key_light.light_cull_mask, 1 << 19, "model lights cannot affect ordinary app geometry")
	t.is_false(key_light.shadow_enabled, "model lighting has no mobile shadow-map cost")
	if t.is_true(robot_node != null, "robot_model creates an asynchronous asset view"):
		t.is_false(robot_node.is_asset_ready(), "no APK bundle is substituted for the robot-owned asset")
		var base: Transform3D = robot_node.get("_target_base")
		t.is_true(base.origin.is_equal_approx(Vector3(0.2, 0.8, -2.0)), "latest base state is retained while the asset loads")
	var route := runtime.component_node("route") as MeshInstance3D
	t.eq(
		(route.mesh as ArrayMesh).surface_get_array_len(0),
		12,
		"path draws its bound points and ignores a trailing partial point",
	)
	t.is_true(
		runtime_warnings.any(
			func(message: Variant) -> bool: return str(message).contains("partial point")
		),
		"a trailing partial path point raises a warning",
	)
	var goal_content := runtime.component_node("goal").get_child(0) as Node3D
	t.is_true(
		goal_content.position.is_equal_approx(Vector3(1.0, 0.0, -2.0)),
		"marker position follows its bound offset",
	)
	var goal_part := (goal_content.get_child(0) as Node3D).get_child(0) as MeshInstance3D
	t.is_true(goal_part.mesh is TorusMesh, "ring marker uses a torus")
	t.eq((goal_content.get_child(1) as Label3D).text, "Goal", "marker text falls back to its property")
	t.eq(builtin_changes.size(), 6, "only the changed built-in view emits another gate update")
	var video_change := builtin_changes.back() as Dictionary
	t.eq(video_change.get("type"), "video_panel", "video gate identifies its built-in view")
	t.is_false(
		bool((video_change.get("properties", {}) as Dictionary).get("follow_camera", true)),
		"built-in properties follow blueprint state bindings",
	)
	var label := runtime.component_node("message") as Label3D
	t.eq(label.text, "Ready", "label text follows its state binding")
	var status := runtime.component_node("status")
	var status_label := status.get_child(1) as Label3D
	t.eq(status_label.text, "Dexterous hand", "status label follows its text binding")
	var status_mesh := status.get_child(0) as MeshInstance3D
	var status_material := status_mesh.material_override as StandardMaterial3D
	t.almost_eq(status_material.emission.g, 1.0, 0.001, "active state updates lamp color")
	var tactile := runtime.component_node("touch")
	var tactile_samples := tactile.get("_samples") as Dictionary
	t.is_true(
		bool((tactile_samples.get("left", {}) as Dictionary).get("valid", false)),
		"fingertip tactile component receives its bound five-finger sample",
	)
	(tactile.get("_last_update_usec") as Dictionary)["left"] = 123
	t.is_false(
		runtime.apply_state(_state(blueprint_id, 2, 2, {
			"left.touch.status": [0, 0, 0, 0],
		})),
		"fingertip arrays with the wrong length are rejected from the generated spec",
	)
	var unchanged_tactile := (current.get("values", {}) as Dictionary).duplicate(true)
	unchanged_tactile["robot.message"] = "Still ready"
	t.is_true(
		runtime.apply_state(_state(blueprint_id, 2, 2, unchanged_tactile)),
		"unrelated state changes with the same tactile sample remain valid",
	)
	t.eq(
		int((tactile.get("_last_update_usec") as Dictionary)["left"]),
		123,
		"an unchanged sample token does not refresh stale tactile data",
	)
	t.eq(
		menu_change_count,
		menu_changes_after_initial_state,
		"scene and status-only changes do not invalidate the controller menu",
	)
	var refreshed_tactile := unchanged_tactile.duplicate(true)
	refreshed_tactile["touch.sample_ns"] = 123457
	t.is_true(
		runtime.apply_state(_state(blueprint_id, 2, 3, refreshed_tactile)),
		"a new tactile sample token refreshes the bound sample",
	)
	t.is_true(
		int((tactile.get("_last_update_usec") as Dictionary)["left"]) > 123,
		"a changed sample token advances tactile freshness",
	)
	t.is_false(
		BlueprintContract.parse_state({
			"schema": BlueprintContract.STATE_SCHEMA,
			"blueprint_id": blueprint_id,
			"blueprint_revision": 2,
			"sequence": 2.0,
			"timestamp_ns": 2,
			"values": {},
		}).get("errors", []).is_empty(),
		"wire envelope integers reject integral JSON floats",
	)
	t.is_false(
		runtime.apply_state(_state(blueprint_id, 2, 3, {"robot.message": "stale"})),
		"duplicate state sequence is rejected",
	)
	t.eq(label.text, "Still ready", "rejected state cannot mutate component values")

	runtime.set_user_visibility_override("message", false)
	t.is_false(runtime.component_visible("message"), "user override hides an overridable component")
	t.eq(
		runtime.user_visibility_options()[0].get("override"),
		false,
		"visibility settings report the persisted local choice",
	)
	t.is_true(
		runtime.apply_state(_state(blueprint_id, 2, 4, {"ui.message_visible": true})),
		"newer state remains accepted while overridden",
	)
	t.is_false(runtime.component_visible("message"), "robot state cannot replace user visibility")
	runtime.set_user_visibility_override("message", null)
	t.is_true(runtime.component_visible("message"), "clearing the override restores robot visibility")
	runtime.set_user_visibility_override("status", false)
	t.is_true(runtime.component_visible("status"), "non-overridable components ignore user changes")
	var builtin_override_change_count := builtin_changes.size()
	runtime.set_user_visibility_override("fpv", false)
	t.is_false(runtime.component_visible("fpv"), "user override hides an XR-owned view")
	t.eq(
		builtin_changes.size(),
		builtin_override_change_count + 1,
		"an XR-owned visibility override emits exactly one gate update",
	)
	runtime.set_user_visibility_override("fpv", null)
	t.is_true(runtime.component_visible("fpv"), "clearing override restores the robot video gate")
	runtime.set_suspended(true)
	t.is_false(runtime.component_visible("message"), "suspending the host hides Blueprint UI")
	t.is_false(runtime.component_visible("fpv"), "suspending the host closes external views")
	runtime.set_suspended(false)
	t.is_true(runtime.component_visible("message"), "resuming the host restores visible components")
	t.is_true(runtime.component_visible("fpv"), "resuming the host restores declared external views")

	var events: Array = []
	runtime.event_emitted.connect(func(event: Dictionary) -> void: events.append(event))
	t.eq(runtime.component_node("hand_control"), null, "remote palm declaration never creates a panel")
	t.eq(runtime.component_node("controller_menu"), null, "remote controller declaration never creates a panel")
	var menu_row: Dictionary = runtime.menu_entries()[0]
	t.is_true(runtime.dispatch_menu(menu_row["token"], false), "system host dispatches the original menu declaration")
	t.eq(events.size(), 1, "palm menu action emits one blueprint event")
	var event := events[0] as Dictionary
	t.eq(event.get("component_id"), "hand_control", "event identifies its component")
	t.eq(event.get("action"), "toggle_unlock", "event uses the robot-authored action")
	t.eq(event.get("value"), true, "toggle event proposes the inverse bound value")
	t.is_false(
		bool(runtime.menu_entries()[0]["value"]),
		"remote-driven palm menu waits for authoritative BlueprintState",
	)
	t.is_true(
		runtime.apply_state(_state(blueprint_id, 2, 5, {
			"hand.unlocked": true,
			"hand.available": true,
		})),
		"authoritative state accepts the requested hand transition",
	)
	runtime._process(0.0)
	t.is_true(
		bool(runtime.menu_entries()[0]["value"]),
		"remote-driven palm menu updates after authoritative BlueprintState",
	)
	t.is_true(
		runtime.apply_state(_state(blueprint_id, 2, 6, {"map.display": "world"})),
		"dense map display accepts a bound string",
	)
	var map_change := builtin_changes.back() as Dictionary
	t.eq(map_change.get("type"), "dense_map", "dense map display changes reach its host view")
	t.eq(
		(map_change.get("properties", {}) as Dictionary).get("display"),
		"world",
		"dense map display follows its state binding",
	)
	var long_path: Array = []
	long_path.resize(int(
		(BlueprintContract.primitive("path")["bindings"] as Dictionary)["points"]["max_length"]
	) + 3)
	long_path.fill(0.0)
	t.is_false(
		runtime.apply_state(_state(blueprint_id, 2, 7, {"nav.path": long_path})),
		"path points beyond the generated max_length are rejected",
	)

	var duplicate_builtin := blueprint.duplicate(true)
	duplicate_builtin["blueprint_id"] = "%s.invalid" % blueprint_id
	var duplicate_components: Array = duplicate_builtin.get("components", [])
	duplicate_components.append({
		"id": "second_video",
		"type": "video_panel",
		"anchor": "world",
		"properties": {},
		"bindings": {},
		"user_overridable": true,
	})
	duplicate_builtin["components"] = duplicate_components
	t.is_false(
		runtime.apply_blueprint(duplicate_builtin),
		"a Blueprint cannot ambiguously declare the same XR-owned view twice",
	)
	t.eq(runtime.component_count(), 17, "invalid replacement leaves the active Blueprint intact")

	runtime.clear()
	t.is_false(bool((builtin_changes.back() as Dictionary).get("visible", true)),
		"clear closes every XR-owned view")
	t.eq(runtime.component_count(), 0, "clear removes all blueprint components")
	t.is_false(runtime.has_blueprint(), "clear removes active blueprint identity")
	origin.free()


func _state(
	blueprint_id: String,
	blueprint_revision: int,
	sequence: int,
	values: Dictionary,
) -> Dictionary:
	return {
		"schema": BlueprintContract.STATE_SCHEMA,
		"blueprint_id": blueprint_id,
		"blueprint_revision": blueprint_revision,
		"sequence": sequence,
		"timestamp_ns": sequence * 1000,
		"values": values,
	}


func _sorted_strings(values: Array) -> Array:
	var result := values.duplicate()
	result.sort()
	return result
