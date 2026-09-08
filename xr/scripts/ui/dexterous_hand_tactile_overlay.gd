class_name DexterousHandTactileOverlay
extends Node3D
## Revo2 TOUCH feedback attached to the operator's tracked fingertips.
## Raw sensor values stay raw on the wire; logarithmic display mapping avoids
## claiming calibrated force while preserving both light and strong contacts.

const SIDES := ["left", "right"]
const FINGERTIP_JOINTS := [5, 10, 15, 20, 25]
const FINGER_DISTAL_JOINTS := [4, 9, 14, 19, 24]
const STALE_AFTER_USEC := 800_000
const HIDE_AFTER_USEC := 3_000_000
const VISIBLE_INTENSITY := 0.08
const SHEAR_VISIBLE_INTENSITY := 0.10
const STRONG_CONTACT_INTENSITY := 0.55
const ONLINE_MARKER_ALPHA := 0.42
const FINGERTIP_SURFACE_OFFSET_M := 0.010
const MAX_TRACKED_POSITION_SQUARED := 1_000_000.0
const MAX_FINGER_SEGMENT_SQUARED := 0.25
const DOT_MIN_SCALE := 0.72
const DOT_MAX_SCALE := 1.65
const SHEAR_MIN_SCALE := 0.65
const SHEAR_MAX_SCALE := 2.25

const PROXIMITY_COLOR := Color(0.12, 0.72, 1.0, 1.0)
const CONTACT_LOW_COLOR := Color(1.0, 0.82, 0.08, 1.0)
const CONTACT_HIGH_COLOR := Color(1.0, 0.12, 0.04, 1.0)
const SHEAR_COLOR := Color(0.95, 1.0, 1.0, 1.0)
const SENSOR_ERROR_COLOR := Color(0.88, 0.18, 1.0, 1.0)
const STALE_COLOR := Color(0.42, 0.45, 0.50, 1.0)

const STATE_ONLINE := &"online"
const STATE_SHEAR := &"shear"
const STATE_CONTACT := &"contact"
const STATE_STRONG_CONTACT := &"strong_contact"
const STATE_ERROR := &"error"
const STATE_STALE := &"stale"

var _tracking_provider: Node = null
var _enabled := true
var _suspended := false
var _last_update_usec := {"left": 0, "right": 0}
var _samples := {"left": {}, "right": {}}
var _markers := {"left": [], "right": []}
var _tracked_joints := {"left": [], "right": []}
var _sample_reported := {"left": false, "right": false}
var _tracking_reported := {"left": false, "right": false}
var _visible_reported := {"left": false, "right": false}


func _ready() -> void:
	_build_markers()
	visible = false


func _process(_delta: float) -> void:
	if not _enabled or _suspended:
		visible = false
		_hide_all()
		return
	var now_usec := Time.get_ticks_usec()
	var any_recent := false
	for side in SIDES:
		var last_update_usec := int(_last_update_usec.get(side, 0))
		var age_usec := now_usec - last_update_usec
		if last_update_usec <= 0 or age_usec >= HIDE_AFTER_USEC:
			_hide_side(side)
			continue
		any_recent = true
		_update_hand(side, age_usec >= STALE_AFTER_USEC)
	visible = any_recent


func set_tracking_provider(provider: Node) -> void:
	_tracking_provider = provider


func update_hand_joints(side: String, joints: Array) -> void:
	if side not in SIDES:
		return
	_tracked_joints[side] = joints


func set_enabled(value: bool) -> void:
	_enabled = value
	if not value:
		visible = false
		_hide_all()


func set_suspended(value: bool) -> void:
	_suspended = value
	if value:
		visible = false
		_hide_all()


func clear() -> void:
	_last_update_usec = {"left": 0, "right": 0}
	_samples = {"left": {}, "right": {}}
	_tracked_joints = {"left": [], "right": []}
	visible = false
	_hide_all()


func update_telemetry(telemetry: Dictionary) -> void:
	var parsed := parse_telemetry(telemetry)
	var now_usec := Time.get_ticks_usec()
	for side in SIDES:
		var sample_v: Variant = parsed.get(side, {})
		if sample_v is Dictionary and bool((sample_v as Dictionary).get("valid", false)):
			_samples[side] = sample_v
			_last_update_usec[side] = now_usec
			if not bool(_sample_reported.get(side, false)):
				_sample_reported[side] = true
				print("[Revo2Tactile] %s telemetry received" % side)
		elif sample_v is Dictionary and bool((sample_v as Dictionary).get("present", false)):
			# A partial sample is malformed and must not be rendered. When all tactile
			# keys are absent, keep the last complete sample so _process() can render
			# the explicit stale state before hiding it at HIDE_AFTER_USEC.
			_samples[side] = {}
			_last_update_usec[side] = 0


static func parse_telemetry(telemetry: Dictionary) -> Dictionary:
	var values_v: Variant = telemetry.get("values", telemetry)
	if not values_v is Dictionary:
		return {}
	var values := values_v as Dictionary
	var parsed := {}
	for side in SIDES:
		var normal_key := "revo2_%s_touch_normal" % side
		var tangential_key := "revo2_%s_touch_tangential" % side
		var direction_key := "revo2_%s_touch_direction" % side
		var proximity_key := "revo2_%s_touch_proximity" % side
		var status_key := "revo2_%s_touch_status" % side
		var present := values.has(normal_key) \
			or values.has(tangential_key) \
			or values.has(direction_key) \
			or values.has(proximity_key) \
			or values.has(status_key)
		var normal := _array5(values.get(normal_key, []))
		var tangential := _array5(values.get(tangential_key, []))
		var direction := _array5(values.get(direction_key, []))
		var proximity := _array5(values.get(proximity_key, []))
		var status := _array5(values.get(status_key, []))
		if normal.size() != 5 \
			or tangential.size() != 5 \
			or direction.size() != 5 \
			or proximity.size() != 5 \
			or status.size() != 5:
			parsed[side] = {"valid": false, "present": present}
			continue
		parsed[side] = {
			"valid": true,
			"normal": normal,
			"tangential": tangential,
			"direction": direction,
			"proximity": proximity,
			"status": status,
		}
	return parsed


static func tactile_intensity(raw_value: float, value_bits := 16) -> float:
	if not is_finite(raw_value):
		return 0.0
	var value := maxf(absf(raw_value), 0.0)
	if value <= 0.0:
		return 0.0
	var safe_bits := clampi(value_bits, 1, 52)
	var raw_max := pow(2.0, float(safe_bits)) - 1.0
	var intensity := log(value + 1.0) / log(raw_max + 1.0)
	return clampf(intensity, 0.0, 1.0) if is_finite(intensity) else 0.0


static func direction_radians(raw_direction: float) -> float:
	if not direction_is_available(raw_direction):
		return 0.0
	return deg_to_rad(fmod(raw_direction, 360.0))


static func direction_is_available(raw_direction: float) -> bool:
	return is_finite(raw_direction) and raw_direction >= 0.0 and raw_direction <= 360.0


static func marker_position(tip_position: Vector3, distal_position: Variant) -> Vector3:
	if not vector3_is_finite(tip_position):
		return Vector3.ZERO
	if not distal_position is Vector3:
		return tip_position
	var distal := distal_position as Vector3
	if not vector3_is_finite(distal):
		return tip_position
	var outward := tip_position - distal
	var outward_length_squared := outward.length_squared()
	if not is_finite(outward_length_squared) or outward_length_squared <= 0.000001:
		return tip_position
	var result := tip_position + outward.normalized() * FINGERTIP_SURFACE_OFFSET_M
	return result if vector3_is_finite(result) else tip_position


static func vector3_is_finite(value: Vector3) -> bool:
	if not is_finite(value.x) or not is_finite(value.y) or not is_finite(value.z):
		return false
	var length_squared := value.length_squared()
	return is_finite(length_squared) and length_squared <= MAX_TRACKED_POSITION_SQUARED


static func quaternion_is_valid(value: Quaternion) -> bool:
	if not is_finite(value.x) \
		or not is_finite(value.y) \
		or not is_finite(value.z) \
		or not is_finite(value.w):
		return false
	var length_squared := value.length_squared()
	return is_finite(length_squared) and length_squared > 0.000001


static func color_is_finite(value: Color) -> bool:
	return is_finite(value.r) \
		and is_finite(value.g) \
		and is_finite(value.b) \
		and is_finite(value.a)


static func sensor_status_is_error(status: float) -> bool:
	if not is_finite(status):
		return true
	var code := int(round(status))
	return code == 1 or code == 2 or code == 255


static func tactile_color(
	normal_intensity: float,
	tangential_intensity: float,
	proximity_intensity: float,
	status: float
) -> Color:
	if not is_finite(normal_intensity) \
		or not is_finite(tangential_intensity) \
		or not is_finite(proximity_intensity) \
		or not is_finite(status):
		return SENSOR_ERROR_COLOR
	if sensor_status_is_error(status):
		return SENSOR_ERROR_COLOR
	if normal_intensity >= VISIBLE_INTENSITY:
		return CONTACT_LOW_COLOR.lerp(CONTACT_HIGH_COLOR, normal_intensity)
	if tangential_intensity >= SHEAR_VISIBLE_INTENSITY:
		return SHEAR_COLOR
	var proximity_color := PROXIMITY_COLOR
	proximity_color.a = lerpf(0.18, PROXIMITY_COLOR.a, proximity_intensity)
	return proximity_color


static func tactile_state(
	normal_intensity: float,
	tangential_intensity: float,
	status: float,
	stale: bool
) -> StringName:
	if stale:
		return STATE_STALE
	if not is_finite(normal_intensity) \
			or not is_finite(tangential_intensity) \
			or not is_finite(status) \
			or sensor_status_is_error(status):
		return STATE_ERROR
	if normal_intensity >= STRONG_CONTACT_INTENSITY:
		return STATE_STRONG_CONTACT
	if normal_intensity >= VISIBLE_INTENSITY:
		return STATE_CONTACT
	if tangential_intensity >= SHEAR_VISIBLE_INTENSITY:
		return STATE_SHEAR
	return STATE_ONLINE


static func tactile_state_color(state: StringName) -> Color:
	match state:
		STATE_SHEAR:
			return SHEAR_COLOR
		STATE_CONTACT:
			return CONTACT_LOW_COLOR
		STATE_STRONG_CONTACT:
			return CONTACT_HIGH_COLOR
		STATE_ERROR:
			return SENSOR_ERROR_COLOR
		STATE_STALE:
			return STALE_COLOR
		_:
			return PROXIMITY_COLOR


static func _array5(value: Variant) -> PackedFloat64Array:
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
	if result.size() == 5:
		return result
	return PackedFloat64Array()


func _build_markers() -> void:
	for side in SIDES:
		var side_node := Node3D.new()
		side_node.name = "%sTactile" % side.capitalize()
		add_child(side_node)
		var fingers: Array = []
		for finger_index in range(5):
			var marker := Node3D.new()
			marker.name = ["Thumb", "Index", "Middle", "Ring", "Pinky"][finger_index]
			marker.visible = false
			side_node.add_child(marker)

			var dot := Label3D.new()
			dot.name = "ContactDot"
			dot.text = "●"
			dot.font_size = 48
			dot.pixel_size = 0.00038
			dot.outline_size = 4
			dot.modulate = PROXIMITY_COLOR
			dot.outline_modulate = Color(0.01, 0.02, 0.03, 0.86)
			dot.no_depth_test = true
			dot.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			marker.add_child(dot)

			var shear := Label3D.new()
			shear.name = "ShearDirection"
			shear.text = "━"
			shear.font_size = 42
			shear.pixel_size = 0.00034
			shear.outline_size = 3
			shear.modulate = SHEAR_COLOR
			shear.outline_modulate = Color(0.01, 0.02, 0.03, 0.92)
			shear.no_depth_test = true
			shear.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			shear.position.z = 0.001
			shear.visible = false
			marker.add_child(shear)

			fingers.append({
				"node": marker,
				"dot": dot,
				"shear": shear,
				"state": STATE_ONLINE,
			})
		_markers[side] = fingers


func _update_hand(side: String, stale: bool) -> void:
	var sample_v: Variant = _samples.get(side, {})
	if not sample_v is Dictionary or not bool((sample_v as Dictionary).get("valid", false)):
		_hide_side(side)
		return
	var joints_v: Variant = _tracked_joints.get(side, [])
	if (not joints_v is Array or (joints_v as Array).is_empty()) \
		and _tracking_provider != null \
		and _tracking_provider.has_method("get_hand_joints"):
		var hand_index := 0 if side == "left" else 1
		joints_v = _tracking_provider.call("get_hand_joints", hand_index)
	if not joints_v is Array:
		_hide_side(side)
		return
	var joints := joints_v as Array
	if not bool(_tracking_reported.get(side, false)):
		_tracking_reported[side] = true
		print("[Revo2Tactile] %s tracking joints=%d" % [side, joints.size()])
	var sample := sample_v as Dictionary
	var normal: PackedFloat64Array = sample.get("normal", PackedFloat64Array())
	var tangential: PackedFloat64Array = sample.get("tangential", PackedFloat64Array())
	var direction: PackedFloat64Array = sample.get("direction", PackedFloat64Array())
	var proximity: PackedFloat64Array = sample.get("proximity", PackedFloat64Array())
	var status: PackedFloat64Array = sample.get("status", PackedFloat64Array())
	var fingers: Array = _markers.get(side, [])
	if normal.size() != 5 \
		or tangential.size() != 5 \
		or direction.size() != 5 \
		or proximity.size() != 5 \
		or status.size() != 5:
		_hide_side(side)
		return
	for finger_index in range(mini(5, fingers.size())):
		var marker := fingers[finger_index] as Dictionary
		var marker_node := marker.get("node") as Node3D
		var joint_index := int(FINGERTIP_JOINTS[finger_index])
		if joint_index >= joints.size() or not joints[joint_index] is Dictionary:
			marker_node.visible = false
			continue
		var joint := joints[joint_index] as Dictionary
		var position_v: Variant = joint.get("position", null)
		if not bool(joint.get("tracked", false)) \
			or not position_v is Vector3 \
			or not vector3_is_finite(position_v as Vector3):
			marker_node.visible = false
			continue
		var distal_position: Variant = null
		var distal_index := int(FINGER_DISTAL_JOINTS[finger_index])
		if distal_index < joints.size() and joints[distal_index] is Dictionary:
			var distal := joints[distal_index] as Dictionary
			if bool(distal.get("tracked", false)):
				distal_position = distal.get("position", null)
				if not distal_position is Vector3 \
					or not vector3_is_finite(distal_position as Vector3):
					marker_node.visible = false
					continue
				var finger_segment := (position_v as Vector3) - (distal_position as Vector3)
				var finger_segment_squared := finger_segment.length_squared()
				if not is_finite(finger_segment_squared) \
					or finger_segment_squared > MAX_FINGER_SEGMENT_SQUARED:
					marker_node.visible = false
					continue
		var marker_position_v := marker_position(position_v as Vector3, distal_position)
		if not vector3_is_finite(marker_position_v):
			marker_node.visible = false
			continue
		if not _update_marker(
			marker,
			float(normal[finger_index]),
			float(tangential[finger_index]),
			float(direction[finger_index]),
			float(proximity[finger_index]),
			float(status[finger_index]),
			stale,
		):
			marker_node.visible = false
			continue
		marker_node.position = marker_position_v
		if marker_node.visible and not bool(_visible_reported.get(side, false)):
			_visible_reported[side] = true
			print("[Revo2Tactile] %s fingertip markers visible" % side)


func _update_marker(
	marker: Dictionary,
	normal_raw: float,
	tangential_raw: float,
	direction_raw: float,
	proximity_raw: float,
	status: float,
	stale: bool
) -> bool:
	if not is_finite(normal_raw) \
		or not is_finite(tangential_raw) \
		or not is_finite(direction_raw) \
		or not is_finite(proximity_raw) \
		or not is_finite(status):
		return false
	var normal := tactile_intensity(normal_raw)
	var tangential := tactile_intensity(tangential_raw)
	var proximity := tactile_intensity(proximity_raw, 32)
	if not is_finite(normal) or not is_finite(tangential) or not is_finite(proximity):
		return false
	var marker_node := marker.get("node") as Node3D
	var dot := marker.get("dot") as Label3D
	var shear := marker.get("shear") as Label3D
	if marker_node == null or dot == null or shear == null:
		return false
	var state := tactile_state(normal, tangential, status, stale)
	var color := STALE_COLOR if stale else tactile_color(
		normal, tangential, proximity, status
	)
	if not color_is_finite(color):
		return false
	var response := maxf(normal, proximity * 0.65)
	if not is_finite(response):
		return false
	response = clampf(response, 0.0, 1.0)
	color.a = maxf(
		ONLINE_MARKER_ALPHA,
		lerpf(ONLINE_MARKER_ALPHA, 1.0, response),
	)
	dot.modulate = color
	var dot_scale := lerpf(DOT_MIN_SCALE, DOT_MAX_SCALE, response)
	if not is_finite(dot_scale):
		return false
	dot.scale = Vector3.ONE * dot_scale

	var show_shear := (
		not stale
		and state != STATE_ERROR
		and tangential >= SHEAR_VISIBLE_INTENSITY
		and direction_is_available(direction_raw)
	)
	shear.visible = show_shear
	if show_shear:
		var angle := direction_radians(direction_raw)
		var shear_scale := lerpf(SHEAR_MIN_SCALE, SHEAR_MAX_SCALE, tangential)
		if not is_finite(angle) or not is_finite(shear_scale):
			return false
		shear.rotation = Vector3(0.0, 0.0, angle)
		shear.scale = Vector3(
			shear_scale,
			lerpf(0.75, 1.15, tangential),
			1.0,
		)
		shear.modulate = Color(
			SHEAR_COLOR.r,
			SHEAR_COLOR.g,
			SHEAR_COLOR.b,
			lerpf(0.55, 1.0, tangential),
		)
	marker["state"] = state
	marker_node.visible = true
	return true


func _hide_side(side: String) -> void:
	for marker_v in _markers.get(side, []):
		var marker := marker_v as Dictionary
		var marker_node := marker.get("node") as Node3D
		marker_node.visible = false


func _hide_all() -> void:
	for side in SIDES:
		_hide_side(side)
