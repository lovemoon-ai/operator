class_name XrtTrackingEncoder
extends RefCounted
## Converts Operator's internal atomic tracking snapshot to the legacy inner
## `Tracking` JSON object consumed by XRoboToolkit/HoloMotion.

const BODY_JOINT_SET := "pico_bd_24"
const BODY_JOINT_COUNT := 24
const HAND_JOINT_COUNT := 26
const MOTION_TRACKER_LIMIT := 3
## Thumbsticks and triggers rest a few thousandths off center. Receivers on this
## protocol feed the analog values straight into a base-velocity command — the
## reference consumer even ships a 0.05 deadzone helper but never calls it — so
## that idle noise becomes a slow unattended drift in a robot nobody is
## touching. The sender is the only place in the chain that can hold the line,
## so hold it here. Values past the band are not rescaled: the response curve
## outside the deadzone stays identical to the reference client's.
const ANALOG_DEADZONE := 0.05
const IDENTITY_POSE := "0.0,0.0,0.0,0.0,0.0,0.0,1.0"
const GODOT_HAND_BONE_ADJUSTMENT_INVERSE := Quaternion(
	0.0, 0.7071067811865476, -0.7071067811865476, 0.0
)


func encode(snapshot: Dictionary, include_body := true) -> Dictionary:
	var timestamp_ns := _positive_timestamp(
		snapshot.get("timestamp_ns", 0),
		int(Time.get_unix_time_from_system() * 1000000000.0)
	)
	var predicted_display_time_ns := _positive_timestamp(
		snapshot.get("predicted_display_time_ns", 0),
		Time.get_ticks_usec() * 1000
	)
	var tracking := {
		"predictTime": float(predicted_display_time_ns) / 1000.0,
		"appState": {"focus": _focus(snapshot.get("focus", true))},
		"timeStampNs": timestamp_ns,
		"Input": 1,
		"Head": _head(snapshot.get("head", {})),
		"Controller": _controllers(snapshot.get("controllers", {})),
	}
	var hands := _hands(snapshot.get("hands", {}))
	if not hands.is_empty():
		tracking["Hand"] = hands
	if include_body:
		var body := _body(snapshot.get("body", null), timestamp_ns)
		if not body.is_empty():
			tracking["Body"] = body
	var motion := _motion(snapshot.get("motion_trackers", []), timestamp_ns)
	if not motion.is_empty():
		tracking["Motion"] = motion
	return tracking


## Builds the explicit "stop" frame.
##
## Section-by-section, because the three behave differently on the receiving
## end and the difference is the whole point of this frame:
##
##   Controller — sent, zeroed. Receivers latch the last button and trigger
##     values and only clear them on a new Controller section, so omitting it
##     leaves a held trigger held.
##   Hand       — sent, `isActive: 0`. Same latching problem, and a receiver
##     holding last-known state would otherwise keep driving the fingers from
##     the live grasp pose.
##   Body       — OMITTED, and this is load-bearing. A receiver reads an absent
##     Body as "no body this frame" and stops. It does not read 24 identity
##     poses that way: identity rotations are a valid skeleton, they retarget to
##     a rest pose, and a humanoid told to hold a rest pose walks its limbs
##     there. The stop frame used to send exactly that, which turned every
##     pause, focus loss and disarm into a commanded T-pose.
func neutral(timestamp_ns := -1, predicted_display_time_ns := -1, focus := true) -> Dictionary:
	var resolved_timestamp := timestamp_ns
	if resolved_timestamp < 0:
		resolved_timestamp = int(Time.get_unix_time_from_system() * 1000000000.0)
	var resolved_predicted := predicted_display_time_ns
	if resolved_predicted < 0:
		resolved_predicted = Time.get_ticks_usec() * 1000
	var tracking := encode({
		"timestamp_ns": resolved_timestamp,
		"predicted_display_time_ns": resolved_predicted,
		"head": {},
		"controllers": {},
		"hands": {},
		"body": null,
		"motion_trackers": [],
		"focus": focus,
	}, false)
	tracking["Hand"] = neutral_hands()
	tracking.erase("Body")
	return tracking


func neutral_hands() -> Dictionary:
	return {"leftHand": neutral_hand(), "rightHand": neutral_hand()}


func neutral_hand() -> Dictionary:
	var joints: Array = []
	for _index in range(HAND_JOINT_COUNT):
		joints.append({"p": IDENTITY_POSE, "s": 0, "r": 0.0})
	return {
		"isActive": 0,
		"count": HAND_JOINT_COUNT,
		"scale": 1.0,
		"HandJointLocations": joints,
	}


func _head(value: Variant) -> Dictionary:
	var pose: Dictionary = value if value is Dictionary else {}
	var valid := _pose_valid(pose)
	return {"pose": _pose_string(pose) if valid else IDENTITY_POSE, "status": 1 if valid else 0}


func _controllers(value: Variant) -> Dictionary:
	var controllers: Dictionary = value if value is Dictionary else {}
	return {
		"left": _controller(controllers.get("left", {}), false),
		"right": _controller(controllers.get("right", {}), true),
	}


func _controller(value: Variant, right_menu_fallback: bool) -> Dictionary:
	var controller: Dictionary = value if value is Dictionary else {}
	var pose: Dictionary = controller.get("pose", {}) if controller.get("pose", {}) is Dictionary else {}
	var input: Dictionary = controller.get("input", {}) if controller.get("input", {}) is Dictionary else {}
	var values: Dictionary = input.get("values", input) if input.get("values", input) is Dictionary else {}
	var menu_pressed := _button(values.get("menu_button", false))
	if right_menu_fallback:
		menu_pressed = menu_pressed or _button(values.get("select_button", false))
	# The thumbstick deadzone is radial, not per-axis: a per-axis cut snaps
	# near-center diagonals onto the pure axes, which a receiver reads as a real
	# flick.
	var axis_x := _clamped_number(values.get("primary_x", 0.0), -1.0, 1.0)
	var axis_y := _clamped_number(values.get("primary_y", 0.0), -1.0, 1.0)
	if _within_radial_deadzone(axis_x, axis_y):
		axis_x = 0.0
		axis_y = 0.0
	return {
		"pose": _pose_string(pose) if _pose_valid(pose) else IDENTITY_POSE,
		"axisX": axis_x,
		"axisY": axis_y,
		"axisClick": _button(values.get("primary_click", false)),
		"grip": _deadzoned(_clamped_number(values.get("grip", 0.0), 0.0, 1.0)),
		"trigger": _deadzoned(_clamped_number(values.get("trigger", 0.0), 0.0, 1.0)),
		"primaryButton": _button(values.get("ax_button", false)),
		"secondaryButton": _button(values.get("by_button", false)),
		"menuButton": menu_pressed,
	}


## Zeroes a scalar axis that rests inside the neutral band. No rescaling: a
## value past the band keeps its exact magnitude, so live values pass through
## bit-for-bit rather than round-tripping through a curve.
func _deadzoned(value: float) -> float:
	return 0.0 if absf(value) <= ANALOG_DEADZONE else value


## Kept in doubles on purpose. Routing the pair through Vector2 would truncate
## every live axis value to 32-bit float, since Godot's vector types use real_t.
func _within_radial_deadzone(x: float, y: float) -> bool:
	return (x * x + y * y) <= (ANALOG_DEADZONE * ANALOG_DEADZONE)


## The Hand section is all-or-nothing: either both hands or no section at all.
## Receivers index `leftHand`/`rightHand` without checking they exist, and a
## throw there takes the whole frame down — including Body, which is the one
## section that matters. A side that is not tracked ships as an inactive hand
## rather than as a missing key.
func _hands(value: Variant) -> Dictionary:
	var source: Dictionary = value if value is Dictionary else {}
	var left := _hand(source.get("left", {}))
	var right := _hand(source.get("right", {}))
	if left.is_empty() and right.is_empty():
		return {}
	return {
		"leftHand": left if not left.is_empty() else neutral_hand(),
		"rightHand": right if not right.is_empty() else neutral_hand(),
	}


func _hand(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var hand := value as Dictionary
	var joints_value: Variant = hand.get("joints", [])
	if not (joints_value is Array) or joints_value.size() != HAND_JOINT_COUNT:
		return {}
	var scale_value: Variant = _finite_number_or_null(hand.get("scale", 1.0))
	if scale_value == null:
		return {}
	var joints: Array = []
	for joint_value in joints_value:
		if not (joint_value is Dictionary):
			return {}
		var joint := joint_value as Dictionary
		var pose: Dictionary = joint.get("pose", joint) if joint.get("pose", joint) is Dictionary else {}
		var radius_value: Variant = _finite_number_or_null(
			joint.get("radius_m", joint.get("radius", 0.0))
		)
		if not _pose_valid(pose) or radius_value == null:
			return {}
		joints.append({
			"p": _legacy_hand_pose_string(pose),
			"s": int(joint.get("flags", 0)),
			"r": float(radius_value),
		})
	return {
		"isActive": 1 if bool(hand.get("active", false)) else 0,
		"count": HAND_JOINT_COUNT,
		"scale": float(scale_value),
		"HandJointLocations": joints,
	}


func _body(value: Variant, top_timestamp_ns: int) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var body := value as Dictionary
	if not bool(body.get("active", false)) or str(body.get("joint_set", "")) != BODY_JOINT_SET:
		return {}
	var joints_value: Variant = body.get("joints", [])
	if not (joints_value is Array) or joints_value.size() != BODY_JOINT_COUNT:
		return {}
	var ordered: Array = []
	ordered.resize(BODY_JOINT_COUNT)
	var body_timestamp_ns := _positive_timestamp(
		body.get("legacy_timestamp_ns", 0), top_timestamp_ns)
	var body_source_timestamp_ns := _first_positive_timestamp([
		body.get("source_timestamp_ns", 0),
		body.get("sample_timestamp_ns", 0),
	], body_timestamp_ns)
	for joint_value in joints_value:
		if not (joint_value is Dictionary):
			return {}
		var joint := joint_value as Dictionary
		var index := int(joint.get("joint", -1))
		if index < 0 or index >= BODY_JOINT_COUNT or ordered[index] != null:
			return {}
		var pose: Dictionary = joint.get("pose", {}) if joint.get("pose", {}) is Dictionary else {}
		var flags := int(joint.get("flags", 0))
		var body_pose := _body_pose_string(pose, flags)
		if body_pose.is_empty():
			return {}
		ordered[index] = {
			"p": body_pose,
			"t": _first_positive_timestamp([
				joint.get("source_timestamp_ns", 0),
				joint.get("timestamp_ns", 0),
				joint.get("sample_timestamp_ns", 0),
				pose.get("sample_timestamp_ns", 0),
			], body_source_timestamp_ns),
			"va": _six_string(
				_motion_vector(joint, pose, "linear_velocity"),
				_motion_vector(joint, pose, "linear_acceleration")
			),
			"wva": _six_string(
				_motion_vector(joint, pose, "angular_velocity"),
				_motion_vector(joint, pose, "angular_acceleration")
			),
		}
	for joint in ordered:
		if joint == null:
			return {}
	return {
		"len": BODY_JOINT_COUNT,
		"timeStampNs": body_timestamp_ns,
		"joints": ordered,
	}


func _motion(value: Variant, timestamp_ns: int) -> Dictionary:
	if not (value is Array) or value.is_empty():
		return {}
	var joints: Array = []
	for tracker_value in value:
		if joints.size() >= MOTION_TRACKER_LIMIT:
			break
		if not (tracker_value is Dictionary):
			continue
		var tracker := tracker_value as Dictionary
		var pose: Dictionary = tracker.get("pose", {}) if tracker.get("pose", {}) is Dictionary else {}
		if not _pose_valid(pose):
			continue
		joints.append({
			"p": _pose_string(pose),
			"va": _six_string(
				_motion_vector(tracker, pose, "linear_velocity"),
				_motion_vector(tracker, pose, "angular_velocity")
			),
			"wva": _six_string(
				_motion_vector(tracker, pose, "linear_acceleration"),
				_motion_vector(tracker, pose, "angular_acceleration")
			),
			"sn": str(tracker.get("id", tracker.get("tracker_index", joints.size()))),
		})
	if joints.is_empty():
		return {}
	return {"len": joints.size(), "timeStampNs": timestamp_ns, "joints": joints}


func _motion_vector(container: Dictionary, pose: Dictionary, key: String) -> Array:
	if container.has(key):
		return _vec3(container.get(key))
	if pose.has(key):
		return _vec3(pose.get(key))
	var raw: Variant = container.get("raw_motion", {})
	if raw is Dictionary and raw.has(key):
		return _vec3(raw.get(key))
	return [0.0, 0.0, 0.0]


func _pose_valid(pose: Dictionary) -> bool:
	if pose.is_empty() or not bool(pose.get("valid", false)):
		return false
	if not pose.has("position") or not pose.has("rotation"):
		return false
	return _strict_vec3(pose.get("position")) != null \
		and _strict_quat(pose.get("rotation")) != null


func _pose_string(pose: Dictionary) -> String:
	var position_value: Variant = _strict_vec3(pose.get("position", null))
	var rotation_value: Variant = _strict_quat(pose.get("rotation", null))
	if not (position_value is Array) or not (rotation_value is Array):
		return IDENTITY_POSE
	return _join_numbers((position_value as Array) + (rotation_value as Array))


func _legacy_hand_pose_string(pose: Dictionary) -> String:
	var position_value: Variant = _strict_vec3(pose.get("position", null))
	var rotation_value: Variant = _strict_quat(pose.get("rotation", null))
	if not (position_value is Array) or not (rotation_value is Array):
		return IDENTITY_POSE
	var rotation := rotation_value as Array
	var godot_rotation := Quaternion(
		float(rotation[0]), float(rotation[1]), float(rotation[2]), float(rotation[3]))
	var legacy_rotation := godot_rotation * GODOT_HAND_BONE_ADJUSTMENT_INVERSE
	return _join_numbers((position_value as Array) + [
		legacy_rotation.x,
		legacy_rotation.y,
		legacy_rotation.z,
		legacy_rotation.w,
	])


func _body_pose_string(pose: Dictionary, flags: int) -> String:
	if (flags & 0x2) == 0 or not pose.has("position"):
		return ""
	var position_value: Variant = _strict_vec3(pose.get("position"))
	if not (position_value is Array):
		return ""
	var rotation: Array = [0.0, 0.0, 0.0, 1.0]
	if (flags & 0x1) != 0:
		var rotation_value: Variant = _strict_quat(pose.get("rotation", null))
		if not (rotation_value is Array):
			return ""
		rotation = rotation_value as Array
	# The old Unity path flips z/qz/qw in PXR_Plugin, then flips them back in
	# TrackingData. Legacy wire values therefore equal the raw PICO/OpenXR pose.
	return _join_numbers((position_value as Array) + rotation)


func _six_string(first: Array, second: Array) -> String:
	return _join_numbers(first + second)


func _join_numbers(values: Array) -> String:
	var parts := PackedStringArray()
	for value in values:
		parts.append(str(_finite_number_or_zero(value)))
	return ",".join(parts)


func _vec3(value: Variant) -> Array:
	if value is Vector3:
		return [
			_finite_number_or_zero(value.x),
			_finite_number_or_zero(value.y),
			_finite_number_or_zero(value.z),
		]
	if value is Dictionary:
		return [
			_finite_number_or_zero(value.get("x", 0.0)),
			_finite_number_or_zero(value.get("y", 0.0)),
			_finite_number_or_zero(value.get("z", 0.0)),
		]
	if value is Array and value.size() >= 3:
		return [
			_finite_number_or_zero(value[0]),
			_finite_number_or_zero(value[1]),
			_finite_number_or_zero(value[2]),
		]
	return [0.0, 0.0, 0.0]


func _strict_vec3(value: Variant) -> Variant:
	var components: Array
	if value is Vector3:
		components = [value.x, value.y, value.z]
	elif value is Dictionary:
		if not value.has("x") or not value.has("y") or not value.has("z"):
			return null
		components = [value.get("x"), value.get("y"), value.get("z")]
	elif value is Array and value.size() >= 3:
		components = [value[0], value[1], value[2]]
	else:
		return null
	return _strict_numeric_array(components)


func _strict_quat(value: Variant) -> Variant:
	var components: Array
	if value is Quaternion:
		components = [value.x, value.y, value.z, value.w]
	elif value is Dictionary:
		if not value.has("x") or not value.has("y") or not value.has("z") or not value.has("w"):
			return null
		components = [value.get("x"), value.get("y"), value.get("z"), value.get("w")]
	elif value is Array and value.size() >= 4:
		components = [value[0], value[1], value[2], value[3]]
	else:
		return null
	var numeric_value: Variant = _strict_numeric_array(components)
	if not (numeric_value is Array):
		return null
	var numeric := numeric_value as Array
	var length_squared := 0.0
	for component in numeric:
		length_squared += float(component) * float(component)
	if not is_finite(length_squared) or length_squared <= 1e-8:
		return null
	return numeric


func _strict_numeric_array(values: Array) -> Variant:
	var result: Array = []
	for value in values:
		var number: Variant = _finite_number_or_null(value)
		if number == null:
			return null
		result.append(float(number))
	return result


func _clamped_number(value: Variant, minimum: float, maximum: float) -> float:
	var number: Variant = _finite_number_or_null(value, true)
	if number == null:
		return 0.0
	return clampf(float(number), minimum, maximum)


func _finite_number_or_zero(value: Variant) -> float:
	var number: Variant = _finite_number_or_null(value)
	return float(number) if number != null else 0.0


func _finite_number_or_null(value: Variant, allow_bool := false) -> Variant:
	if allow_bool and typeof(value) == TYPE_BOOL:
		return 1.0 if bool(value) else 0.0
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return null
	var number := float(value)
	return number if is_finite(number) else null


func _positive_timestamp(value: Variant, fallback: int) -> int:
	if typeof(value) == TYPE_INT and int(value) > 0:
		return int(value)
	if typeof(value) == TYPE_FLOAT and is_finite(float(value)) and float(value) > 0.0:
		return int(value)
	return maxi(1, fallback)


func _first_positive_timestamp(values: Array, fallback: int) -> int:
	for value in values:
		if typeof(value) == TYPE_INT and int(value) > 0:
			return int(value)
		if typeof(value) == TYPE_FLOAT and is_finite(float(value)) and float(value) > 0.0:
			return int(value)
	return maxi(1, fallback)


func _button(value: Variant) -> bool:
	if typeof(value) == TYPE_BOOL:
		return bool(value)
	var number: Variant = _finite_number_or_null(value)
	return number != null and float(number) >= 0.5


## Legacy `appState.focus`. Absent or unreadable values stay `true` so a
## snapshot that never reports focus keeps the historical behavior.
func _focus(value: Variant) -> bool:
	if typeof(value) == TYPE_BOOL:
		return bool(value)
	var number: Variant = _finite_number_or_null(value)
	if number == null:
		return true
	return float(number) >= 0.5
