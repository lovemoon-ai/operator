class_name BlueprintRuntime
extends Node3D

signal event_emitted(event: Dictionary)
signal warning_raised(message: String)
signal menu_changed
signal external_view_changed(
	component_id: String,
	component_type: String,
	visible: bool,
	properties: Dictionary,
)

const RobotModelScript := preload("res://scripts/blueprint/robot_model_view.gd")
const GroundGridScript := preload("res://scripts/blueprint/ground_grid.gd")
const ModelLightingScript := preload("res://scripts/blueprint/model_lighting.gd")
const MenuDeclarations := preload("res://scripts/contracts/blueprint/menu_declarations.gd")
const InputBindingScript := preload("res://scripts/blueprint/controller_input_binding.gd")
const FingertipTactileScript := preload(
	"res://scripts/ui/dexterous_hand_tactile_overlay.gd"
)
const OVERRIDES_PATH := "user://blueprint_overrides.cfg"
const HAND_LEFT := 0
const HAND_RIGHT := 1
const PALM_JOINT := 0
const ANCHOR_IMPLEMENTATIONS := {
	"world": "origin",
	"head": "head",
	"left_controller": "controller",
	"right_controller": "controller",
	"left_palm": "hand",
	"right_palm": "hand",
}
const NODE_IMPLEMENTATIONS := {
	"ground_grid": {
		"properties": ["visible", "settings_label", "size", "spacing", "major_every", "line_width", "color", "major_color", "placement_target"],
		"bindings": ["visible"],
		"events": [],
	},
	"model_lighting": {
		"properties": ["visible", "settings_label", "key_energy", "fill_energy", "key_color", "fill_color"],
		"bindings": ["visible", "key_energy", "fill_energy"],
		"events": [],
	},
	"robot_model": {
		"properties": ["visible", "settings_label", "asset_sha256", "asset_size", "asset_port", "joint_names", "smoothing_ms", "stale_after_ms"],
		"bindings": ["visible", "joint_positions", "base_pose", "sample"],
		"events": [],
	},
	"label": {
		"properties": [
			"visible", "settings_label", "text", "font_size", "pixel_size",
			"outline_size", "no_depth_test", "color",
		],
		"bindings": ["visible", "text", "color"],
		"events": [],
	},
	"status_lamp": {
		"properties": [
			"visible", "settings_label", "text", "font_size", "pixel_size", "radius", "colors", "pulse_states", "pulse_hz",
		],
		"bindings": ["visible", "state", "text"],
		"events": [],
	},
	"input_binding": {
		"properties": ["visible", "settings_label", "gesture", "action", "hold_seconds", "ack_timeout_seconds", "target_component"],
		"bindings": ["visible", "available", "required", "acknowledged_request", "success", "message"],
		"events": ["action"],
	},
	"fingertip_tactile": {
		"properties": ["visible", "settings_label"],
		"bindings": [
			"visible", "left_normal", "left_tangential", "left_direction",
			"left_proximity", "left_status", "right_normal", "right_tangential",
			"right_direction", "right_proximity", "right_status", "sample",
		],
		"events": [],
	},
}
const EVENT_IMPLEMENTATIONS := ["action", "secondary_action"]
const MENU_IMPLEMENTATIONS := {
	"menu_item": {
		"properties": ["visible", "settings_label", "title", "action", "item_key", "locked_text", "unlocked_text", "unavailable_text"],
		"bindings": ["visible", "value", "available"], "events": ["action"],
	},
	"palm_menu": {
		"properties": ["visible", "settings_label", "title", "action", "item_key", "locked_text", "unlocked_text", "unavailable_text"],
		"bindings": ["visible", "value", "available"], "events": ["action"],
	},
	"controller_menu": {
		"properties": ["visible", "settings_label", "title", "action", "item_key", "locked_text", "unlocked_text", "unavailable_text", "secondary_action", "secondary_text", "secondary_item_key"],
		"bindings": ["visible", "value", "available", "secondary_available", "detail"], "events": ["action", "secondary_action"],
	},
}
const RUNTIME_REVISION := 2

var _origin: XROrigin3D
var asset_host := "" # Supplied by the connected transport, never by Blueprint.
var _camera: XRCamera3D
var _left_controller: XRController3D
var _right_controller: XRController3D
var _tracking_provider: Node
var _external_view_implementations: Array[String] = []
var _blueprint_id := ""
var _blueprint_revision := 0
var _last_state_sequence := 0
var _last_state_received_us := 0
var _local_view_offsets: Dictionary = {}
var _event_sequence := 0
var _state_values: Dictionary = {}
var _blueprint_components: Array = []
var _binding_contracts: Dictionary = {}
var _components: Dictionary = {}
var _component_order: Array[String] = []
var _dynamic_components: Array = []
var _frame_hand_joints: Dictionary = {}
var _user_visibility_overrides: Dictionary = {}
var _suspended := false
var _menu_generation := 0


func _init() -> void:
	set_process(false)


func configure(
	origin: XROrigin3D,
	camera: XRCamera3D,
	left_controller: XRController3D,
	right_controller: XRController3D,
	tracking_provider: Node,
	external_view_implementations: Array[String] = [],
) -> void:
	_origin = origin
	_camera = camera
	_left_controller = left_controller
	_right_controller = right_controller
	_tracking_provider = tracking_provider
	_external_view_implementations.clear()
	for implementation in external_view_implementations:
		_external_view_implementations.append(str(implementation))


func apply_blueprint(blueprint: Dictionary) -> bool:
	var parsed := BlueprintContract.parse_blueprint(blueprint)
	var errors: Array = parsed.get("errors", [])
	if not errors.is_empty():
		warning_raised.emit("Invalid Blueprint: %s" % str(errors))
		return false
	for component_v in blueprint.get("components", []):
		var component := component_v as Dictionary
		var primitive_spec := BlueprintContract.primitive(str(component.get("type", "")))
		if not ANCHOR_IMPLEMENTATIONS.has(BlueprintContract.resolved_anchor(component)):
			warning_raised.emit(
				"Unsupported Blueprint anchor implementation: %s"
				% BlueprintContract.resolved_anchor(component)
			)
			return false
		var host := str(primitive_spec.get("host", ""))
		var implementation := str(primitive_spec.get("implementation", ""))
		if host == "system_menu" and not MENU_IMPLEMENTATIONS.has(implementation):
			warning_raised.emit("Unsupported system menu declaration")
			return false
		if host == "node3d" and not NODE_IMPLEMENTATIONS.has(implementation):
			warning_raised.emit(
				"Unsupported Blueprint implementation: %s"
				% implementation
			)
			return false
		if host == "external_view" and implementation not in _external_view_implementations:
			warning_raised.emit(
				"Unsupported external Blueprint implementation: %s" % implementation
			)
			return false
		var events_v: Variant = primitive_spec.get("events", {})
		if events_v is Dictionary:
			for event_name_v in events_v as Dictionary:
				if str(event_name_v) not in EVENT_IMPLEMENTATIONS:
					warning_raised.emit(
						"Unsupported Blueprint event implementation: %s"
						% str(event_name_v)
					)
					return false
	clear()
	_blueprint_id = str(blueprint.get("blueprint_id", ""))
	_blueprint_revision = int(blueprint.get("revision", 0))
	_blueprint_components = (blueprint.get("components", []) as Array).duplicate(true)
	_binding_contracts = BlueprintContract.compile_binding_contracts(_blueprint_components)
	_load_user_overrides()
	for component_v in blueprint.get("components", []):
		var component := component_v as Dictionary
		var entry := _create_component(component)
		if not entry.is_empty():
			var component_id := str(component.get("id", ""))
			_components[component_id] = entry
			_component_order.append(component_id)
	_refresh_components()
	_refresh_dynamic_processing()
	print(
		"[Blueprint] Applied runtime=%d id=%s revision=%d declared=%d created=%d overrides=%s suspended=%s"
		% [
			RUNTIME_REVISION,
			_blueprint_id,
			_blueprint_revision,
			_blueprint_components.size(),
			_components.size(),
			JSON.stringify(_user_visibility_overrides),
			str(_suspended),
		]
	)
	return true


func apply_state(state: Dictionary) -> bool:
	var parsed := BlueprintContract.parse_state(state)
	var errors: Array = parsed.get("errors", [])
	if not errors.is_empty():
		warning_raised.emit("Invalid BlueprintState: %s" % str(errors))
		return false
	if str(state.get("blueprint_id", "")) != _blueprint_id \
			or int(state.get("blueprint_revision", 0)) != _blueprint_revision:
		warning_raised.emit(
			"Ignoring BlueprintState for id=%s revision=%d; active id=%s revision=%d"
			% [
				str(state.get("blueprint_id", "")),
				int(state.get("blueprint_revision", 0)),
				_blueprint_id,
				_blueprint_revision,
			]
		)
		return false
	var sequence := int(state.get("sequence", 0))
	if sequence <= _last_state_sequence:
		return false
	var values_v: Variant = state.get("values", {})
	if values_v is Dictionary:
		var value_errors := BlueprintContract.validate_bound_values(
			_blueprint_components,
			values_v as Dictionary,
			_binding_contracts,
		)
		if not value_errors.is_empty():
			warning_raised.emit("Invalid BlueprintState values: %s" % str(value_errors))
			return false
		# Session JSON parsing creates a fresh state dictionary and never mutates
		# it after emission. Retain that snapshot instead of recursively copying
		# every robot/scene joint array at Blueprint rate on the render thread.
		var next_values := values_v as Dictionary
		var changed_keys := _changed_state_keys(_state_values, next_values)
		_state_values = next_values
		_last_state_sequence = sequence
		_last_state_received_us = Time.get_ticks_usec()
		_refresh_components(changed_keys)
	else:
		_last_state_sequence = sequence
		_last_state_received_us = Time.get_ticks_usec()
	if sequence == 1:
		print(
			"[Blueprint] Initial state applied id=%s values=%d"
			% [_blueprint_id, _state_values.size()]
		)
	return true


func clear() -> void:
	_menu_generation += 1
	for entry_v in _components.values():
		var entry := entry_v as Dictionary
		if bool(entry.get("external_view", false)):
			var spec: Dictionary = entry.get("spec", {})
			external_view_changed.emit(
				str(spec.get("id", "")),
				str(entry.get("type", "")),
				false,
				{},
			)
		var node := entry.get("node") as Node
		if node != null:
			if str(entry.get("implementation", "")) == "input_binding":
				node.call("set_active", false)
			if node is Node3D:
				(node as Node3D).visible = false
			node.queue_free()
	_components.clear()
	_component_order.clear()
	_dynamic_components.clear()
	_frame_hand_joints.clear()
	_state_values.clear()
	_blueprint_components.clear()
	_binding_contracts.clear()
	_user_visibility_overrides.clear()
	_blueprint_id = ""
	_blueprint_revision = 0
	_last_state_sequence = 0
	_last_state_received_us = 0
	_local_view_offsets.clear()
	_event_sequence = 0
	set_process(false)
	menu_changed.emit()


func set_suspended(value: bool) -> void:
	if _suspended != value:
		_menu_generation += 1
	_suspended = value
	_refresh_components()
	_refresh_dynamic_processing()


func set_user_visibility_override(component_id: String, visible: Variant) -> void:
	var entry_v: Variant = _components.get(component_id, null)
	if not entry_v is Dictionary:
		return
	var entry := entry_v as Dictionary
	var spec: Dictionary = entry.get("spec", {})
	if not BlueprintContract.user_visibility_overridable(spec):
		return
	if visible == null:
		_user_visibility_overrides.erase(component_id)
	else:
		_user_visibility_overrides[component_id] = bool(visible)
	_save_user_overrides()
	_refresh_component(entry_v as Dictionary)
	menu_changed.emit()


func user_visibility_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	for component_id in _component_order:
		var entry_v: Variant = _components.get(component_id, null)
		if not entry_v is Dictionary:
			continue
		var spec: Dictionary = (entry_v as Dictionary).get("spec", {})
		if not BlueprintContract.user_visibility_overridable(spec):
			continue
		var properties := BlueprintContract.resolved_properties(spec)
		var label := str(
			properties.get(
				"settings_label",
				properties.get("title", properties.get("text", component_id)),
			)
		).strip_edges()
		if label.is_empty():
			label = component_id
		options.append({
			"id": component_id,
			"label": label,
			"override": _user_visibility_overrides.get(component_id, null),
		})
	return options


func component_count() -> int:
	return _components.size()


func has_blueprint() -> bool:
	return not _blueprint_id.is_empty()


func component_node(component_id: String) -> Node3D:
	var entry_v: Variant = _components.get(component_id, null)
	if not entry_v is Dictionary:
		return null
	return (entry_v as Dictionary).get("node") as Node3D


func component_visible(component_id: String) -> bool:
	var entry_v: Variant = _components.get(component_id, null)
	if not entry_v is Dictionary:
		return false
	var entry := entry_v as Dictionary
	if bool(entry.get("menu", false)):
		return not _suspended and bool(entry.get("requested_visible", true))
	if bool(entry.get("external_view", false)):
		return bool(entry.get("effective_visible", false))
	var node := entry.get("node") as Node3D
	return node != null and node.visible


func _process(delta: float) -> void:
	_frame_hand_joints.clear()
	for entry_v in _dynamic_components:
		var entry := entry_v as Dictionary
		_update_anchor(entry)
		if str(entry.get("implementation", "")) == "status_lamp":
			_update_lamp(entry)
	_frame_hand_joints.clear()


func _create_component(spec: Dictionary) -> Dictionary:
	var component_type := str(spec.get("type", ""))
	var primitive_spec := BlueprintContract.primitive(component_type)
	var implementation := str(primitive_spec.get("implementation", ""))
	var node: Node3D
	var properties := BlueprintContract.resolved_properties(spec)
	var binding_keys: Array[String] = []
	var bindings_v: Variant = spec.get("bindings", {})
	if bindings_v is Dictionary:
		for state_key_v: Variant in (bindings_v as Dictionary).values():
			var state_key := str(state_key_v)
			if not state_key.is_empty() and state_key not in binding_keys:
				binding_keys.append(state_key)
	var entry := {
		"type": component_type,
		"implementation": implementation,
		"spec": spec,
		"properties": properties,
		"binding_keys": binding_keys,
	}
	if str(primitive_spec.get("host", "")) == "external_view":
		entry["external_view"] = true
		entry["effective_visible"] = null
		entry["effective_properties"] = {}
		return entry
	if str(primitive_spec.get("host", "")) == "system_menu":
		entry["menu"] = true
		return entry # Declarations never allocate panels or input listeners.
	match implementation:
		"ground_grid":
			node = GroundGridScript.new()
			node.name = "BlueprintGroundGrid_%s" % str(spec.get("id", ""))
			node.call("configure", properties, _parse_color(properties["color"], Color.WHITE),
				_parse_color(properties["major_color"], Color.WHITE))
		"model_lighting":
			node = ModelLightingScript.new()
			node.name = "BlueprintModelLighting_%s" % str(spec.get("id", ""))
		"input_binding":
			node = InputBindingScript.new()
			var configured: bool = node.call("configure", properties, _left_controller, _right_controller)
			if not configured:
				warning_raised.emit("Unsupported Blueprint input gesture")
				node.free()
				return {}
			node.set("target_ready", Callable(self, "_input_target_ready"))
			node.connect("action_triggered", Callable(self, "_on_palm_menu_action").bind(str(spec.get("id", ""))))
		"robot_model":
			node = RobotModelScript.new()
			node.name = "BlueprintRobot_%s" % str(spec.get("id", ""))
			node.connect("warning_raised", func(message: String) -> void: warning_raised.emit(message))
			var configured: bool = node.call("configure", properties, asset_host)
			if not configured:
				node.free()
				return {}
		"label":
			node = _create_label(spec)
		"status_lamp":
			node = _create_status_lamp(spec, entry)
		"fingertip_tactile":
			node = FingertipTactileScript.new()
			node.name = "BlueprintFingertipTactile_%s" % str(spec.get("id", ""))
			node.call("set_tracking_provider", _tracking_provider)
		_:
			return {}
	add_child(node)
	entry["node"] = node
	entry["local_transform"] = _parse_transform(BlueprintContract.resolved_transform(spec))
	if implementation == "status_lamp" or BlueprintContract.resolved_anchor(spec) != "world":
		_dynamic_components.append(entry)
	elif implementation != "fingertip_tactile":
		_update_anchor(entry)
	return entry


func _create_label(spec: Dictionary) -> Label3D:
	var properties := BlueprintContract.resolved_properties(spec)
	var label := Label3D.new()
	label.name = "BlueprintLabel_%s" % str(spec.get("id", ""))
	label.text = str(properties.get("text", ""))
	label.font_size = int(properties["font_size"])
	label.pixel_size = float(properties["pixel_size"])
	label.outline_size = int(properties["outline_size"])
	label.no_depth_test = bool(properties["no_depth_test"])
	label.modulate = _parse_color(properties["color"], Color.WHITE)
	return label


func _create_status_lamp(spec: Dictionary, entry: Dictionary) -> Node3D:
	var properties := BlueprintContract.resolved_properties(spec)
	var root := Node3D.new()
	root.name = "BlueprintStatusLamp_%s" % str(spec.get("id", ""))
	var lamp := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	var radius := float(properties["radius"])
	sphere.radius = radius
	sphere.height = radius * 2.0
	lamp.mesh = sphere
	lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.emission_enabled = true
	lamp.material_override = material
	root.add_child(lamp)
	var label := Label3D.new()
	label.position = Vector3(radius * 1.8, radius * 0.4, 0.0)
	label.text = str(properties.get("text", ""))
	label.font_size = int(properties["font_size"])
	label.pixel_size = float(properties["pixel_size"])
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(label)
	entry["material"] = material
	entry["label"] = label
	return root


func _refresh_components(changed_keys: Variant = null) -> void:
	var filter_changes := changed_keys is Dictionary
	var menu_dirty := not filter_changes
	for entry_v in _components.values():
		var entry := entry_v as Dictionary
		var implementation := str(entry.get("implementation", ""))
		var affected := not filter_changes or implementation == "input_binding"
		if filter_changes and not affected:
			for state_key_v: Variant in entry.get("binding_keys", []):
				if (changed_keys as Dictionary).has(str(state_key_v)):
					affected = true
					break
		if not affected:
			continue
		_refresh_component(entry)
		menu_dirty = menu_dirty or bool(entry.get("menu", false))
	if menu_dirty:
		menu_changed.emit()


func _refresh_component(entry: Dictionary) -> void:
	var spec: Dictionary = entry.get("spec", {})
	var properties: Dictionary = entry.get("properties", {})
	var visible := bool(_bound_value(spec, "visible", properties["visible"]))
	var component_id := str(spec.get("id", ""))
	if BlueprintContract.user_visibility_overridable(spec) \
			and _user_visibility_overrides.has(component_id):
		visible = bool(_user_visibility_overrides[component_id])
	entry["requested_visible"] = visible
	var component_type := str(entry.get("type", ""))
	var implementation := str(entry.get("implementation", ""))
	if bool(entry.get("external_view", false)):
		var effective_visible := visible and not _suspended
		var effective_properties := _resolved_properties(entry)
		var previous_visible: Variant = entry.get("effective_visible", null)
		var previous_properties: Dictionary = entry.get("effective_properties", {})
		entry["effective_visible"] = effective_visible
		entry["effective_properties"] = effective_properties
		if (
			previous_visible == null
			or bool(previous_visible) != effective_visible
			or previous_properties != effective_properties
		):
			external_view_changed.emit(
				component_id,
				component_type,
				effective_visible,
				effective_properties,
			)
		return
	var node := entry.get("node") as Node3D
	if node == null:
		return
	if implementation == "input_binding":
		node.call("set_active", visible and not _suspended)
		node.call("set_bound_state", bool(_bound_value(spec, "available", false)),
			bool(_bound_value(spec, "required", true)), str(_bound_value(spec, "acknowledged_request", "")),
			bool(_bound_value(spec, "success", false)), str(_bound_value(spec, "message", "")), _last_state_received_us)
	elif implementation == "fingertip_tactile":
		node.call("set_suspended", _suspended)
		node.call("set_enabled", visible)
		if visible and not _suspended:
			node.call(
				"update_bound_values",
				_state_values,
				spec.get("bindings", {}),
				BlueprintContract.binding_with_semantics(
					component_type, "refresh_token"
				),
			)
	else:
		_update_anchor(entry)
	match implementation:
		"model_lighting":
			node.call("update_lighting", float(_bound_value(spec, "key_energy", properties["key_energy"])),
				float(_bound_value(spec, "fill_energy", properties["fill_energy"])),
				_parse_color(properties["key_color"], Color.WHITE), _parse_color(properties["fill_color"], Color.WHITE))
		"robot_model":
			node.call(
				"update_sample",
				_bound_value(spec, "joint_positions", null),
				_bound_value(spec, "base_pose", null),
				_bound_value(spec, "sample", null),
			)
		"label":
			var label := node as Label3D
			label.text = str(_bound_value(spec, "text", properties["text"]))
			label.modulate = _parse_color(
				_bound_value(spec, "color", properties["color"]),
				Color.WHITE,
			)
		"status_lamp":
			var label := entry.get("label") as Label3D
			if label != null:
				label.text = str(
					_bound_value(spec, "text", properties["text"])
				)
			var material := entry.get("material") as StandardMaterial3D
			if material != null:
				var color := _status_color(
					str(_bound_value(spec, "state", "inactive")),
					properties,
				)
				material.albedo_color = color
				material.emission = Color(color.r, color.g, color.b, 1.0)


func _update_anchor(entry: Dictionary) -> void:
	var node := entry.get("node") as Node3D
	if node == null:
		return
	if _suspended or not bool(entry.get("requested_visible", true)):
		node.visible = false
		return
	var spec: Dictionary = entry.get("spec", {})
	var local_transform: Transform3D = entry.get("local_transform", Transform3D.IDENTITY)
	var anchor_transform_v: Variant = _anchor_transform(BlueprintContract.resolved_anchor(spec))
	if anchor_transform_v is Transform3D:
		node.global_transform = (anchor_transform_v as Transform3D) * local_transform
		var placement_id := str(spec.get("id", ""))
		if str(entry.get("implementation", "")) == "ground_grid":
			var properties: Dictionary = entry.get("properties", {})
			placement_id = str(properties.get("placement_target", ""))
		node.global_position += Vector3(_local_view_offsets.get(placement_id, Vector3.ZERO))
		node.visible = true
	else:
		node.visible = false


func _refresh_dynamic_processing() -> void:
	set_process(not _suspended and not _dynamic_components.is_empty())


func menu_entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var shared := {}
	for id in _component_order:
		var entry: Dictionary = _components[id]
		if not bool(entry.get("menu", false)):
			continue
		var spec: Dictionary = entry["spec"]
		for declaration in MenuDeclarations.entries(spec, BlueprintContract.primitive(str(spec["type"]))):
			var contract: Dictionary = declaration["contract"]
			var value := bool(_state_values.get(contract["value_binding"], false))
			var available := bool(_state_values.get(contract["available_binding"], contract["available_default"])) and not _suspended
			var visible := bool(entry.get("requested_visible", true)) and not _suspended
			var key: String = declaration["item_key"]
			if not key.is_empty() and shared.has(key):
				# First declaration is canonical; hiding either alias hides the row.
				var row: Dictionary = result[int(shared[key])]
				row["visible"] = bool(row["visible"]) and visible
				row["available"] = bool(row["available"]) and available
				continue
			if not key.is_empty():
				shared[key] = result.size()
			result.append({
				"token": {"runtime": get_instance_id(), "generation": _menu_generation,
					"blueprint_id": _blueprint_id, "revision": _blueprint_revision,
					"component_id": id, "event": declaration["event"]},
				"title": contract["title"], "value": value, "available": available, "visible": visible,
				"text": contract["on"] if value else contract["off"],
				"unavailable_text": contract["unavailable"],
				"detail": str(_state_values.get(contract["detail_binding"], "")),
			})
	return result


func dispatch_menu(token: Dictionary, expected_value: bool) -> bool:
	# Check the current source generation and resolved item, never a remote
	# action name. A queued click cannot cross disconnect/replacement/suspension.
	for row in menu_entries():
		if row["token"] == token and bool(row["visible"]) and bool(row["available"]) \
				and bool(row["value"]) == expected_value:
			_on_palm_menu_action(StringName(token["event"]), not expected_value, str(token["component_id"]))
			return true
	return false


func _on_palm_menu_action(
	internal_action: StringName,
	proposed_value: Variant,
	component_id: String,
) -> void:
	var entry_v: Variant = _components.get(component_id, null)
	if not entry_v is Dictionary:
		return
	var entry := entry_v as Dictionary
	var spec: Dictionary = entry.get("spec", {})
	var primitive_spec := BlueprintContract.primitive(str(spec.get("type", "")))
	var events_v: Variant = primitive_spec.get("events", {})
	if not events_v is Dictionary:
		warning_raised.emit("Blueprint primitive has no event contract")
		return
	var event_name := "secondary_action" if internal_action == &"secondary_action" else "action"
	var event_spec_v: Variant = (events_v as Dictionary).get(event_name, null)
	if not event_spec_v is Dictionary:
		warning_raised.emit("Blueprint primitive does not support action events")
		return
	var event_spec := event_spec_v as Dictionary
	var action_property := str(event_spec.get("action_property", ""))
	var properties: Dictionary = entry.get("properties", {})
	var action := str(properties.get(action_property, ""))
	if action.is_empty():
		warning_raised.emit("Blueprint action property is empty")
		return
	var value: Variant = proposed_value
	if value == null:
		value = not bool(_bound_value(spec, "value", false))
	if not BlueprintContract.value_matches_type(value, str(event_spec.get("value_type", ""))):
		warning_raised.emit("Blueprint action value has invalid type")
		return
	_event_sequence += 1
	event_emitted.emit({
		"schema": BlueprintContract.EVENT_SCHEMA,
		"blueprint_id": _blueprint_id,
		"blueprint_revision": _blueprint_revision,
		"sequence": _event_sequence,
		"timestamp_ns": Time.get_ticks_usec() * 1000,
		"component_id": component_id,
		"action": action,
		"value": value,
	})


func _update_lamp(entry: Dictionary) -> void:
	var material := entry.get("material") as StandardMaterial3D
	if material == null:
		return
	var spec: Dictionary = entry.get("spec", {})
	var properties: Dictionary = entry.get("properties", {})
	var state := str(_bound_value(spec, "state", "inactive"))
	var color := _status_color(state, properties)
	if state in properties.get("pulse_states", []):
		var phase := float(Time.get_ticks_usec()) / 1000000.0 * TAU * float(properties.get("pulse_hz", 2.0))
		var brightness := 0.3 + 0.7 * (sin(phase) * 0.5 + 0.5)
		color = Color(color.r * brightness, color.g * brightness, color.b * brightness, color.a)
	material.albedo_color = color
	material.emission = Color(color.r, color.g, color.b, 1.0)


func _input_target_ready(component_id: String) -> bool:
	if component_id.is_empty():
		return true
	var node := component_node(component_id)
	return node != null and node.has_method("is_asset_ready") and bool(node.call("is_asset_ready"))


func controller_status() -> Dictionary:
	var status := {"present": false, "required": false, "pending": false, "available": false, "message": "", "target_component": ""}
	for entry_v in _components.values():
		var entry: Dictionary = entry_v
		if str(entry.get("implementation", "")) == "input_binding":
			var node := entry.get("node") as Node
			if node != null:
				status = node.call("ui_status")
	var target := recenter_target()
	if not target.is_empty():
		var model := component_node(target)
		if not bool(model.call("is_asset_ready")):
			status["required"] = true
			var error: String = model.call("asset_error")
			status["pending"] = error.is_empty()
			status["message"] = error if not error.is_empty() else tr("UI_ROBOT_MODEL_LOADING")
		elif not bool(model.call("sample_is_fresh")):
			status["required"] = true
	return status


func recenter_target() -> String:
	var models: Array[String] = []
	var target := ""
	for id in _component_order:
		var entry: Dictionary = _components[id]
		if str(entry.get("implementation", "")) == "robot_model":
			models.append(id)
		elif str(entry.get("implementation", "")) == "input_binding":
			var properties: Dictionary = entry.get("properties", {})
			target = str(properties.get("target_component", ""))
	if not target.is_empty():
		return target if target in models else ""
	return models[0] if models.size() == 1 else ""


func can_recenter() -> bool:
	var target := recenter_target()
	return not target.is_empty() and _input_target_ready(target)


func recenter_robot(distance: float = 2.0) -> bool:
	if _camera == null or not can_recenter() or not is_finite(distance) or distance <= 0:
		return false
	var target := recenter_target()
	var model := component_node(target)
	var current: Vector3 = model.call("base_world_position")
	var shift_v: Variant = front_translation(_camera.global_transform, current, distance)
	if not shift_v is Vector3:
		return false
	_local_view_offsets[target] = Vector3(_local_view_offsets.get(target, Vector3.ZERO)) + (shift_v as Vector3)
	_update_anchor(_components[target])
	for entry_v in _components.values():
		var entry: Dictionary = entry_v
		if str(entry.get("implementation", "")) == "ground_grid":
			_update_anchor(entry)
	return true


static func front_translation(head: Transform3D, current: Vector3, distance: float) -> Variant:
	if not head.is_finite() or not current.is_finite() or not is_finite(distance) or distance <= 0:
		return null
	var forward := -head.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		# Looking straight up/down still has a meaningful horizontal right axis.
		forward = Vector3.UP.cross(head.basis.x)
	if forward.length_squared() < 0.0001:
		return null
	var desired := head.origin + forward.normalized() * distance
	desired.y = current.y # Keep ground height; do not move/rotate the simulation.
	return desired - current


func _bound_value(spec: Dictionary, property: String, fallback: Variant) -> Variant:
	var bindings: Dictionary = spec.get("bindings", {})
	var key := str(bindings.get(property, ""))
	return _state_values.get(key, fallback) if not key.is_empty() else fallback


func _resolved_properties(entry: Dictionary) -> Dictionary:
	var spec: Dictionary = entry.get("spec", {})
	var properties: Dictionary = (entry.get("properties", {}) as Dictionary).duplicate()
	var bindings_v: Variant = spec.get("bindings", {})
	if not bindings_v is Dictionary:
		return properties
	for property_v in (bindings_v as Dictionary).keys():
		var property := str(property_v)
		if property == "visible":
			continue
		properties[property] = _bound_value(spec, property, properties.get(property))
	return properties


static func _changed_state_keys(previous: Dictionary, current: Dictionary) -> Dictionary:
	var changed := {}
	for key_v: Variant in previous:
		if not current.has(key_v) or previous[key_v] != current[key_v]:
			changed[str(key_v)] = true
	for key_v: Variant in current:
		if not previous.has(key_v):
			changed[str(key_v)] = true
	return changed


func _anchor_transform(anchor: String) -> Variant:
	match anchor:
		"world":
			return Transform3D.IDENTITY
		"head":
			return _camera.global_transform if _camera != null else null
		"left_controller":
			return _left_controller.global_transform if _left_controller != null else null
		"right_controller":
			return _right_controller.global_transform if _right_controller != null else null
		"left_palm":
			return _tracked_palm_transform(HAND_LEFT)
		"right_palm":
			return _tracked_palm_transform(HAND_RIGHT)
		_:
			return null


func _tracked_palm_transform(hand: int) -> Variant:
	if _tracking_provider == null or not _tracking_provider.has_method("get_hand_joints"):
		return null
	var joints := _hand_joints(hand)
	if joints.size() <= PALM_JOINT or not joints[PALM_JOINT] is Dictionary:
		return null
	var palm := joints[PALM_JOINT] as Dictionary
	if not bool(palm.get("tracked", false)):
		return null
	var position_v: Variant = palm.get("position", null)
	var rotation_v: Variant = palm.get("rotation", null)
	if not position_v is Vector3 or not rotation_v is Quaternion:
		return null
	var local_transform := Transform3D(Basis(rotation_v as Quaternion), position_v as Vector3)
	return (
		(_origin.global_transform if _origin != null else Transform3D.IDENTITY)
		* local_transform
	)


func _hand_joints(hand: int) -> Array:
	if _frame_hand_joints.has(hand):
		return _frame_hand_joints[hand] as Array
	var joints: Array = []
	if _tracking_provider != null and _tracking_provider.has_method("get_hand_joints"):
		joints = _tracking_provider.call("get_hand_joints", hand)
	_frame_hand_joints[hand] = joints
	return joints


static func _parse_transform(value: Variant) -> Transform3D:
	if not value is Dictionary:
		return Transform3D.IDENTITY
	var data := value as Dictionary
	var transform_spec: Dictionary = BlueprintPrimitiveSpec.TRANSFORM
	var position_default: Variant = (transform_spec["position"] as Dictionary)["default"]
	var rotation_default: Variant = (transform_spec["rotation"] as Dictionary)["default"]
	var scale_default: Variant = (transform_spec["scale"] as Dictionary)["default"]
	var position := _vector3(data.get("position", position_default), Vector3.ZERO)
	var rotation_values: Variant = data.get("rotation", rotation_default)
	var rotation := Quaternion.IDENTITY
	if rotation_values is Array and (rotation_values as Array).size() >= 4:
		var values := rotation_values as Array
		rotation = Quaternion(
			float(values[0]), float(values[1]), float(values[2]), float(values[3])
		).normalized()
	var scale := _vector3(data.get("scale", scale_default), Vector3.ONE)
	return Transform3D(Basis(rotation).scaled(scale), position)


static func _vector3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var values := value as Array
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return fallback


static func _parse_color(value: Variant, fallback: Color) -> Color:
	if value is Color:
		return value as Color
	if value is String and Color.html_is_valid(str(value)):
		return Color.from_string(str(value), fallback)
	if value is Array and (value as Array).size() >= 3:
		var values := value as Array
		return Color(
			float(values[0]),
			float(values[1]),
			float(values[2]),
			float(values[3]) if values.size() >= 4 else 1.0,
		)
	return fallback


static func _status_color(state: String, properties: Dictionary) -> Color:
	var defaults := {
		"active": Color(0.08, 1.0, 0.28, 1.0),
		"warning": Color(1.0, 0.72, 0.18, 1.0),
		"error": Color(1.0, 0.20, 0.16, 1.0),
		"inactive": Color(0.32, 0.34, 0.38, 0.95),
	}
	var colors_v: Variant = properties.get("colors", {})
	var colors: Dictionary = colors_v if colors_v is Dictionary else {}
	return _parse_color(colors.get(state, defaults.get(state, defaults["inactive"])), defaults["inactive"])


func _load_user_overrides() -> void:
	_user_visibility_overrides.clear()
	if _blueprint_id.is_empty():
		return
	var config := ConfigFile.new()
	if config.load(OVERRIDES_PATH) != OK:
		return
	for key in config.get_section_keys(_blueprint_id):
		_user_visibility_overrides[str(key)] = bool(
			config.get_value(_blueprint_id, key, true)
		)


func _save_user_overrides() -> void:
	if _blueprint_id.is_empty():
		return
	var config := ConfigFile.new()
	config.load(OVERRIDES_PATH)
	config.erase_section(_blueprint_id)
	for component_id in _user_visibility_overrides:
		config.set_value(
			_blueprint_id,
			str(component_id),
			bool(_user_visibility_overrides[component_id]),
		)
	config.save(OVERRIDES_PATH)
