extends Node3D
class_name TeleopControllerPanel

const GRIP_ACTIVE_THRESHOLD := 0.5
const GRIP_RELEASE_GRACE_MSEC := 100
const TRIGGER_ACTIVE_THRESHOLD := 0.08
const BUTTON_ACTIVE_THRESHOLD := 0.5
const A_TOGGLE_COOLDOWN_MSEC := 180

# Local positions are relative to the OpenXR right-hand grip pose.
# +Y is the controller top face, -Z is the trigger/front side.
const STATUS_LAMP_POS := Vector3(0.018, 0.023, -0.034)
const STATUS_LABEL_POS := Vector3(0.018, 0.043, -0.034)
const A_BUTTON_POS := Vector3(0.043, 0.026, -0.050)
const A_LABEL_POS := Vector3(0.075, 0.050, -0.050)
const B_BUTTON_POS := Vector3(0.044, 0.026, -0.014)
const B_LABEL_POS := Vector3(0.076, 0.050, -0.014)

const GRIP_ANCHOR_POS := Vector3(-0.044, -0.038, 0.000)
const GRIP_TIP_POS := Vector3(-0.132, 0.025, 0.012)
const TRIGGER_ANCHOR_POS := Vector3(0.002, -0.016, -0.074)
const TRIGGER_TIP_POS := Vector3(0.034, 0.066, -0.124)

const COL_ACTIVE := Color(0.14, 0.82, 0.45, 1.0)
const COL_WAITING := Color(1.0, 0.72, 0.18, 1.0)
const COL_DISCONNECTED := Color(0.43, 0.46, 0.50, 1.0)
const COL_HELP_TEXT := Color(0.92, 0.95, 0.98, 1.0)
const COL_HELP_LINE := Color(0.72, 0.84, 1.0, 0.92)
const COL_HELP_KEY := Color(1.0, 0.65, 0.18, 1.0)
const COL_TRIGGER := Color(0.28, 0.76, 1.0, 1.0)
const COL_BUTTON_A := Color(0.40, 0.64, 1.0, 1.0)
const COL_BUTTON_B := Color(1.0, 0.42, 0.30, 1.0)
const COL_DIM := Color(0.18, 0.20, 0.23, 0.86)

var _enabled_for_device := false
var _controller_active := false
var _bridge_connected := false
var _grip_pressed := false
var _trigger_pressed := false
var _help_visible := true
var _last_a_pressed := false
var _last_a_toggle_msec := 0
var _grip_hold_until_msec := 0

var _help_root: Node3D
var _status_lamp: MeshInstance3D
var _status_label: Label3D
var _grip_marker: MeshInstance3D
var _trigger_marker: MeshInstance3D
var _a_marker: MeshInstance3D
var _a_label: Label3D
var _b_marker: MeshInstance3D
var _b_label: Label3D

var _mat_active: StandardMaterial3D
var _mat_waiting: StandardMaterial3D
var _mat_disconnected: StandardMaterial3D
var _mat_help_line: StandardMaterial3D
var _mat_help_key: StandardMaterial3D
var _mat_help_text_back: StandardMaterial3D
var _mat_trigger: StandardMaterial3D
var _mat_trigger_idle: StandardMaterial3D
var _mat_button_a: StandardMaterial3D
var _mat_button_b: StandardMaterial3D
var _mat_dim: StandardMaterial3D


func _init() -> void:
	_build_overlay()
	visible = false


func configure_for_device(descriptor: Dictionary) -> void:
	_enabled_for_device = _has_controller_teleop_mapping(descriptor)
	var schema: Dictionary = descriptor.get("control_schema", {})
	print("[ControllerHelpTip] configured enabled=%s buttons=%d mappings=%d" % [
		str(_enabled_for_device),
		schema.get("buttons", []).size(),
		descriptor.get("input_mapping", []).size(),
	])
	_refresh()


func set_controller_active(active: bool) -> void:
	if _controller_active == active:
		return
	_controller_active = active
	_refresh()


func set_bridge_connected(connected: bool) -> void:
	if _bridge_connected == connected:
		return
	_bridge_connected = connected
	_refresh()


func set_grip_value(value: float) -> void:
	var now_msec := Time.get_ticks_msec()
	if value >= GRIP_ACTIVE_THRESHOLD:
		_grip_hold_until_msec = now_msec + GRIP_RELEASE_GRACE_MSEC
	var pressed := now_msec <= _grip_hold_until_msec
	if _grip_pressed == pressed:
		return
	_grip_pressed = pressed
	_refresh()


func set_trigger_value(value: float) -> void:
	var pressed := value >= TRIGGER_ACTIVE_THRESHOLD
	if _trigger_pressed == pressed:
		return
	_trigger_pressed = pressed
	_refresh()


func set_a_button_pressed(pressed: bool) -> void:
	if pressed and not _last_a_pressed:
		var now_msec := Time.get_ticks_msec()
		if now_msec - _last_a_toggle_msec >= A_TOGGLE_COOLDOWN_MSEC:
			_last_a_toggle_msec = now_msec
			_help_visible = not _help_visible
			print("[ControllerHelpTip] help_visible=%s" % str(_help_visible))
			_refresh()
	_last_a_pressed = pressed


func _build_overlay() -> void:
	_mat_active = _emissive_material(COL_ACTIVE, 1.8)
	_mat_waiting = _emissive_material(COL_WAITING, 1.45)
	_mat_disconnected = _material(COL_DISCONNECTED, true)
	_mat_help_line = _emissive_material(COL_HELP_LINE, 0.7)
	_mat_help_key = _emissive_material(COL_HELP_KEY, 0.8)
	_mat_help_text_back = _material(Color(0.02, 0.025, 0.03, 0.62), true)
	_mat_trigger = _emissive_material(COL_TRIGGER, 1.1)
	_mat_trigger_idle = _material(Color(COL_TRIGGER.r, COL_TRIGGER.g, COL_TRIGGER.b, 0.42), true)
	_mat_button_a = _emissive_material(COL_BUTTON_A, 0.85)
	_mat_button_b = _emissive_material(COL_BUTTON_B, 0.85)
	_mat_dim = _material(COL_DIM, true)

	_status_lamp = _sphere("StatusLamp", STATUS_LAMP_POS, 0.010, _mat_disconnected)
	add_child(_status_lamp)

	_status_label = _label("StatusLabel", "OFF", STATUS_LABEL_POS, 0.00105, 18, COL_HELP_TEXT)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_status_label)

	_a_marker = _sphere("AButtonMarker", A_BUTTON_POS, 0.0075, _mat_button_a)
	add_child(_a_marker)

	_a_label = _label("AHelpToggleLabel", tr("UI_TELEOP_A_HIDE_HELP"), A_LABEL_POS, 0.0010, 16, COL_HELP_TEXT)
	_a_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_a_label)

	_b_marker = _sphere("BResetMarker", B_BUTTON_POS, 0.0075, _mat_button_b)
	add_child(_b_marker)

	_b_label = _label("BResetLabel", tr("UI_TELEOP_B_RESET"), B_LABEL_POS, 0.0010, 16, COL_HELP_TEXT)
	_b_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_b_label)

	_help_root = Node3D.new()
	_help_root.name = "ControllerHelpTip"
	add_child(_help_root)

	_add_tip(
		"GripTip",
		GRIP_ANCHOR_POS,
		GRIP_TIP_POS,
		"GRIP\n%s" % tr("UI_TELEOP_GRIP_HINT"),
		COL_HELP_KEY
	)
	_add_tip(
		"TriggerTip",
		TRIGGER_ANCHOR_POS,
		TRIGGER_TIP_POS,
		"TRIGGER\n%s" % tr("UI_TELEOP_TRIGGER_HINT"),
		COL_TRIGGER
	)

	_grip_marker = _sphere("GripAnchor", GRIP_ANCHOR_POS, 0.0065, _mat_help_key)
	_help_root.add_child(_grip_marker)

	_trigger_marker = _sphere("TriggerAnchor", TRIGGER_ANCHOR_POS, 0.0065, _mat_trigger_idle)
	_help_root.add_child(_trigger_marker)


func _add_tip(node_name: String, anchor_pos: Vector3, tip_pos: Vector3, text: String, key_color: Color) -> void:
	var root := Node3D.new()
	root.name = node_name
	_help_root.add_child(root)

	var line := _dashed_line("%sLine" % node_name, anchor_pos, tip_pos, 10, 0.0032, _mat_help_line)
	root.add_child(line)

	var back := _label_backplate("%sBack" % node_name, tip_pos + Vector3(0.0, -0.002, 0.0), 0.074, 0.032)
	root.add_child(back)

	var label := _label("%sLabel" % node_name, text, tip_pos, 0.0011, 18, COL_HELP_TEXT)
	label.outline_modulate = Color(0, 0, 0, 0.85)
	root.add_child(label)

	var key_dot := _sphere("%sKeyDot" % node_name, tip_pos + Vector3(-0.046, 0.006, 0.0), 0.0045, _emissive_material(key_color, 0.95))
	root.add_child(key_dot)


func _dashed_line(node_name: String, start: Vector3, end: Vector3, dash_count: int, thickness: float, material: Material) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var dash_fraction := 0.58
	for i in dash_count:
		var t0 := float(i) / float(dash_count)
		var t1 := minf((float(i) + dash_fraction) / float(dash_count), 1.0)
		var a := start.lerp(end, t0)
		var b := start.lerp(end, t1)
		root.add_child(_box_segment("Dash%d" % i, a, b, thickness, material))
	return root


func _box_segment(node_name: String, start: Vector3, end: Vector3, thickness: float, material: Material) -> MeshInstance3D:
	var segment := MeshInstance3D.new()
	segment.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = Vector3(thickness, thickness, start.distance_to(end))
	segment.mesh = mesh
	segment.material_override = material
	var direction := (end - start).normalized()
	var up := Vector3.UP
	if absf(direction.dot(up)) > 0.96:
		up = Vector3.RIGHT
	segment.transform = Transform3D(Basis.looking_at(direction, up), start.lerp(end, 0.5))
	return segment


func _sphere(node_name: String, position: Vector3, radius: float, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 24
	mesh.rings = 12
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	return instance


func _label(node_name: String, text: String, position: Vector3, pixel_size: float, font_size: int, color: Color) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text
	label.position = position
	label.pixel_size = pixel_size
	label.font_size = font_size
	label.modulate = color
	label.outline_size = 7
	label.outline_modulate = Color(0, 0, 0, 0.78)
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	return label


func _label_backplate(node_name: String, position: Vector3, width: float, height: float) -> MeshInstance3D:
	var backplate := MeshInstance3D.new()
	backplate.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width, height, 0.002)
	backplate.mesh = mesh
	backplate.position = position
	backplate.material_override = _mat_help_text_back
	return backplate


func _refresh() -> void:
	if not _enabled_for_device or not _controller_active:
		visible = false
		return
	visible = true

	var lamp_material := _mat_disconnected
	var status_text := tr("UI_TELEOP_STATUS_OFF")
	if _bridge_connected and _grip_pressed:
		lamp_material = _mat_active
		status_text = tr("UI_TELEOP_STATUS_ON")
	elif _bridge_connected:
		lamp_material = _mat_waiting
		status_text = tr("UI_TELEOP_STATUS_WAIT")

	if _status_lamp:
		_status_lamp.material_override = lamp_material
	if _status_label:
		_status_label.text = status_text
		_status_label.modulate = _status_color()
	var controls_visible := _bridge_connected and _controller_active
	if _help_root:
		_help_root.visible = controls_visible and _help_visible
	if _grip_marker:
		_grip_marker.material_override = _mat_active if _grip_pressed else _mat_help_key
	if _trigger_marker:
		_trigger_marker.material_override = _mat_trigger if _trigger_pressed else _mat_trigger_idle
	if _a_marker:
		_a_marker.visible = controls_visible
	if _a_label:
		_a_label.visible = controls_visible
		_a_label.text = tr("UI_TELEOP_A_HIDE_HELP") if _help_visible else tr("UI_TELEOP_A_SHOW_HELP")
	if _b_marker:
		_b_marker.visible = controls_visible
	if _b_label:
		_b_label.visible = controls_visible


func _status_color() -> Color:
	if not _bridge_connected:
		return COL_DISCONNECTED
	if _grip_pressed:
		return COL_ACTIVE
	return COL_WAITING


func _has_controller_teleop_mapping(descriptor: Dictionary) -> bool:
	var has_enable_button := false
	var schema: Dictionary = descriptor.get("control_schema", {})
	for button_def in schema.get("buttons", []):
		if button_def is Dictionary and String(button_def.get("name", "")) == "enable":
			has_enable_button = true
			break
	if not has_enable_button:
		return false

	var has_enable_mapping := false
	for mapping in descriptor.get("input_mapping", []):
		if not mapping is Dictionary:
			continue
		if String(mapping.get("target", "")) == "enable":
			has_enable_mapping = true
			break
	return has_enable_mapping


func _material(color: Color, transparent: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if transparent or color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _emissive_material(color: Color, energy: float) -> StandardMaterial3D:
	var material := _material(color, color.a < 1.0)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	return material
