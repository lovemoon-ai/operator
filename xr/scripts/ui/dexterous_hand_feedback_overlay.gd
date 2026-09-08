class_name DexterousHandFeedbackOverlay
extends Node3D
## Compact, head-locked Revo2 feedback. Each row shows actual position, a cyan
## target marker, their displacement, filtered motor-current color, and STALL.

const SIDES := ["left", "right"]
const CHANNEL_LABELS := ["OP", "TF", "I", "M", "R", "P"]
const VALUE_MIN_X := -0.052
const VALUE_MAX_X := 0.052
const ROW_SPACING := 0.021
const STALE_AFTER_USEC := 800_000
const HIDE_AFTER_USEC := 3_000_000

const TARGET_COLOR := Color(0.15, 0.78, 1.0, 0.55)
const RAIL_COLOR := Color(0.18, 0.22, 0.28, 0.75)
const CURRENT_LOW := Color(0.22, 0.9, 0.38, 0.95)
const CURRENT_MID := Color(1.0, 0.78, 0.12, 0.98)
const CURRENT_HIGH := Color(1.0, 0.18, 0.10, 1.0)
const STALE_COLOR := Color(0.45, 0.48, 0.52, 0.7)

var _enabled := true
var _suspended := false
var _last_update_usec := 0
var _panels: Dictionary = {}


func _ready() -> void:
	_build_panel("left", Vector3(-0.18, -0.17, -0.58))
	_build_panel("right", Vector3(0.18, -0.17, -0.58))
	visible = false


func _process(_delta: float) -> void:
	if not _enabled or _suspended or _last_update_usec <= 0:
		visible = false
		return
	var age_usec := Time.get_ticks_usec() - _last_update_usec
	if age_usec >= HIDE_AFTER_USEC:
		visible = false
		return
	visible = true
	if age_usec >= STALE_AFTER_USEC:
		_set_stale(true)


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value and not _suspended and _last_update_usec > 0


func set_suspended(value: bool) -> void:
	_suspended = value
	visible = _enabled and not value and _last_update_usec > 0


func clear() -> void:
	_last_update_usec = 0
	visible = false
	for panel_v in _panels.values():
		var panel := panel_v as Dictionary
		var panel_node := panel.get("node") as Node3D
		if panel_node != null:
			panel_node.visible = false


func update_telemetry(telemetry: Dictionary) -> void:
	var parsed := parse_telemetry(telemetry)
	var updated := false
	for side in SIDES:
		var hand_v: Variant = parsed.get(side, {})
		var panel: Dictionary = _panels.get(side, {})
		var panel_node := panel.get("node") as Node3D
		if not hand_v is Dictionary:
			if panel_node != null:
				panel_node.visible = false
			continue
		var hand := hand_v as Dictionary
		if not bool(hand.get("valid", false)):
			if panel_node != null:
				panel_node.visible = false
			continue
		if not _update_hand(side, hand):
			if panel_node != null:
				panel_node.visible = false
			continue
		if panel_node != null:
			panel_node.visible = true
		updated = true
	if not updated:
		return
	_last_update_usec = Time.get_ticks_usec()
	_set_stale(false)
	visible = _enabled and not _suspended


static func parse_telemetry(telemetry: Dictionary) -> Dictionary:
	var values_v: Variant = telemetry.get("values", telemetry)
	if not values_v is Dictionary:
		return {}
	var values := values_v as Dictionary
	var parsed := {}
	for side in SIDES:
		var actual := _array6(values.get("revo2_%s_position" % side, []))
		if actual.size() != 6:
			parsed[side] = {"valid": false}
			continue
		var target := _array6(values.get("revo2_%s_target" % side, actual))
		var current := _array6(values.get("revo2_%s_current" % side, []), 0.0)
		var stall := _array6(values.get("revo2_%s_stall" % side, []), 0.0)
		if target.size() != 6 or current.size() != 6 or stall.size() != 6:
			parsed[side] = {"valid": false}
			continue
		parsed[side] = {
			"valid": true,
			"actual": actual,
			"target": target,
			"current": current,
			"stall": stall,
		}
	return parsed


static func current_color(current_value: float, stalled: bool = false) -> Color:
	if stalled:
		return CURRENT_HIGH
	if not is_finite(current_value):
		return CURRENT_LOW
	var load := clampf(absf(current_value) / 1000.0, 0.0, 1.0)
	if load <= 0.5:
		return CURRENT_LOW.lerp(CURRENT_MID, load / 0.5)
	return CURRENT_MID.lerp(CURRENT_HIGH, (load - 0.5) / 0.5)


static func _array6(value: Variant, fill := NAN) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	if value is PackedFloat64Array:
		result = value as PackedFloat64Array
	elif value is PackedFloat32Array:
		for item in value as PackedFloat32Array:
			result.append(float(item))
	elif value is Array:
		for item in value as Array:
			if typeof(item) != TYPE_INT and typeof(item) != TYPE_FLOAT:
				return PackedFloat64Array()
			var numeric_item := float(item)
			if not is_finite(numeric_item):
				return PackedFloat64Array()
			result.append(numeric_item)
	for item in result:
		if not is_finite(item):
			return PackedFloat64Array()
	if result.size() == 6:
		return result
	if not is_finite(fill):
		return PackedFloat64Array()
	result = PackedFloat64Array()
	for _i in range(6):
		result.append(fill)
	return result


func _build_panel(side: String, panel_position: Vector3) -> void:
	var panel := Node3D.new()
	panel.name = "%sHandFeedback" % side.capitalize()
	panel.position = panel_position
	panel.visible = false
	add_child(panel)

	var title := Label3D.new()
	title.name = "Title"
	title.position = Vector3(0.0, 0.018, 0.0)
	title.text = "L HAND" if side == "left" else "R HAND"
	title.font_size = 24
	title.pixel_size = 0.001
	title.outline_size = 4
	title.modulate = Color(0.88, 0.94, 1.0, 0.95)
	title.no_depth_test = true
	panel.add_child(title)

	var rows: Array = []
	for i in range(6):
		var row_y := -float(i) * ROW_SPACING
		var label := Label3D.new()
		label.position = Vector3(-0.071, row_y, 0.0)
		label.text = CHANNEL_LABELS[i]
		label.font_size = 18
		label.pixel_size = 0.0008
		label.no_depth_test = true
		label.modulate = Color(0.86, 0.9, 0.95, 0.9)
		panel.add_child(label)

		var rail := MeshInstance3D.new()
		var rail_mesh := BoxMesh.new()
		rail_mesh.size = Vector3(VALUE_MAX_X - VALUE_MIN_X, 0.002, 0.002)
		rail.mesh = rail_mesh
		rail.position = Vector3(0.0, row_y, 0.0)
		rail.material_override = _material(RAIL_COLOR, false)
		rail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		panel.add_child(rail)

		var load_bar := MeshInstance3D.new()
		var load_mesh := BoxMesh.new()
		load_mesh.size = Vector3(VALUE_MAX_X - VALUE_MIN_X, 0.004, 0.0025)
		load_bar.mesh = load_mesh
		load_bar.position = Vector3(VALUE_MIN_X, row_y - 0.006, 0.0)
		load_bar.scale.x = 0.001
		var load_material := _material(CURRENT_LOW, true)
		load_bar.material_override = load_material
		load_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		panel.add_child(load_bar)

		var line := MeshInstance3D.new()
		var line_mesh := CylinderMesh.new()
		line_mesh.top_radius = 0.0012
		line_mesh.bottom_radius = 0.0012
		line_mesh.height = 1.0
		line.mesh = line_mesh
		line.material_override = _material(TARGET_COLOR, true)
		line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		panel.add_child(line)

		var target := MeshInstance3D.new()
		var target_mesh := SphereMesh.new()
		target_mesh.radius = 0.0042
		target_mesh.height = 0.0084
		target.mesh = target_mesh
		target.material_override = _material(TARGET_COLOR, true)
		target.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		panel.add_child(target)

		var actual := MeshInstance3D.new()
		var actual_mesh := SphereMesh.new()
		actual_mesh.radius = 0.0048
		actual_mesh.height = 0.0096
		actual.mesh = actual_mesh
		var actual_material := _material(CURRENT_LOW, true)
		actual.material_override = actual_material
		actual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		panel.add_child(actual)

		rows.append({
			"row_y": row_y,
			"target": target,
			"actual": actual,
			"actual_material": actual_material,
			"line": line,
			"line_mesh": line_mesh,
			"load": load_bar,
			"load_material": load_material,
		})
	_panels[side] = {"node": panel, "title": title, "rows": rows}


func _update_hand(side: String, hand: Dictionary) -> bool:
	var panel: Dictionary = _panels.get(side, {})
	if panel.is_empty():
		return false
	var actual: PackedFloat64Array = hand.get("actual", PackedFloat64Array())
	var target: PackedFloat64Array = hand.get("target", PackedFloat64Array())
	var current: PackedFloat64Array = hand.get("current", PackedFloat64Array())
	var stall: PackedFloat64Array = hand.get("stall", PackedFloat64Array())
	if actual.size() != 6 or target.size() != 6 or current.size() != 6 or stall.size() != 6:
		return false
	var rows: Array = panel.get("rows", [])
	if rows.size() < 6:
		return false
	var stalled_count := 0
	var max_load := 0.0
	for i in range(6):
		var actual_value := float(actual[i])
		var target_value := float(target[i])
		var current_value := float(current[i])
		var stall_value := float(stall[i])
		if not is_finite(actual_value) \
			or not is_finite(target_value) \
			or not is_finite(current_value) \
			or not is_finite(stall_value):
			return false
		var stalled := stall_value >= 0.5
		if stalled:
			stalled_count += 1
		var load := clampf(absf(current_value) / 1000.0, 0.0, 1.0)
		if not is_finite(load):
			return false
		max_load = maxf(max_load, load)
		if not _update_row(rows[i] as Dictionary, target_value, actual_value, load, stalled):
			return false
	var title: Label3D = panel.get("title")
	var prefix := "L" if side == "left" else "R"
	title.text = "%s HAND  load %d%%  contact %d" % [prefix, int(round(max_load * 100.0)), stalled_count]
	return true


func _update_row(row: Dictionary, target_raw: float, actual_raw: float, load: float, stalled: bool) -> bool:
	if not is_finite(target_raw) or not is_finite(actual_raw) or not is_finite(load):
		return false
	var row_y := float(row.get("row_y", 0.0))
	var target_x := lerpf(VALUE_MIN_X, VALUE_MAX_X, clampf(target_raw / 1000.0, 0.0, 1.0))
	var actual_x := lerpf(VALUE_MIN_X, VALUE_MAX_X, clampf(actual_raw / 1000.0, 0.0, 1.0))
	if not is_finite(row_y) or not is_finite(target_x) or not is_finite(actual_x):
		return false
	var target: MeshInstance3D = row.get("target")
	var actual: MeshInstance3D = row.get("actual")
	var line: MeshInstance3D = row.get("line")
	var line_mesh: CylinderMesh = row.get("line_mesh")
	var load_bar: MeshInstance3D = row.get("load")
	var color := current_color(load * 1000.0, stalled)
	if not _color_is_finite(color):
		return false

	var start := Vector3(actual_x, row_y, 0.0)
	var finish := Vector3(target_x, row_y, 0.0)
	var delta := finish - start
	var delta_length := delta.length()
	if not _vector3_is_finite(start) \
		or not _vector3_is_finite(finish) \
		or not _vector3_is_finite(delta) \
		or not is_finite(delta_length):
		return false
	var line_direction := delta.normalized() if delta_length > 0.00001 else Vector3.RIGHT
	var line_rotation := Quaternion(Vector3.UP, line_direction)
	var length := maxf(delta_length, 0.0005)
	var load_scale := maxf(load, 0.001)
	var load_position_x := VALUE_MIN_X + (VALUE_MAX_X - VALUE_MIN_X) * load * 0.5
	if not _vector3_is_finite(line_direction) \
		or not _quaternion_is_valid(line_rotation) \
		or not is_finite(length) \
		or not is_finite(load_scale) \
		or not is_finite(load_position_x):
		return false

	target.position = Vector3(target_x, row_y, 0.001)
	actual.position = Vector3(actual_x, row_y, 0.002)
	actual.scale = Vector3.ONE * (1.45 if stalled else 1.0)
	_set_material_color(row.get("actual_material"), color)
	_set_material_color(row.get("load_material"), color)

	line.position = (start + finish) * 0.5
	line.quaternion = line_rotation
	line.scale = Vector3(1.0, length, 1.0)

	load_bar.scale = Vector3(load_scale, 1.0, 1.0)
	load_bar.position = Vector3(load_position_x, row_y - 0.006, 0.0)
	return true


static func _vector3_is_finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _quaternion_is_valid(value: Quaternion) -> bool:
	if not is_finite(value.x) \
		or not is_finite(value.y) \
		or not is_finite(value.z) \
		or not is_finite(value.w):
		return false
	var length_squared := value.length_squared()
	return is_finite(length_squared) and length_squared > 0.000001


static func _color_is_finite(value: Color) -> bool:
	return is_finite(value.r) \
		and is_finite(value.g) \
		and is_finite(value.b) \
		and is_finite(value.a)


func _set_stale(stale: bool) -> void:
	for side in SIDES:
		var panel: Dictionary = _panels.get(side, {})
		if panel.is_empty():
			continue
		var title: Label3D = panel.get("title")
		if stale:
			title.text = ("L HAND" if side == "left" else "R HAND") + "  STALE"
		for row_v in panel.get("rows", []):
			var row := row_v as Dictionary
			if stale:
				_set_material_color(row.get("actual_material"), STALE_COLOR)
				_set_material_color(row.get("load_material"), STALE_COLOR)


func _material(color: Color, emissive: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.albedo_color = color
	material.emission_enabled = emissive
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = 0.65 if emissive else 0.0
	return material


func _set_material_color(material_v: Variant, color: Color) -> void:
	if not material_v is StandardMaterial3D or not _color_is_finite(color):
		return
	var material := material_v as StandardMaterial3D
	material.albedo_color = color
	material.emission = Color(color.r, color.g, color.b, 1.0)
