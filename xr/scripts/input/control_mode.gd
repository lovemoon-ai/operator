class_name ControlMode
extends RefCounted
## Core abstraction that maps VR inputs to DeviceCommand based on DeviceDescriptor.
## Reads a descriptor's input_mapping array and transforms VR source values
## (joystick axes, triggers, buttons, poses) into the target command format.

var _descriptor: Dictionary = {}
var _mappings: Array = []
var _dead_zones: Dictionary = {}  # axis_name -> dead_zone
var _button_targets: Dictionary = {}  # button_name -> button definition
var _toggle_states: Dictionary = {}  # button_name -> bool (for toggle buttons)
var _enable_latched: Dictionary = {}  # enable target -> bool (hysteresis state)

# Deadman hysteresis. A single 0.5 threshold chatters when the grip value sits
# near it, which is why this used to hold `enable=true` for 100ms after release.
# That grace made RELEASE LAG BY 100ms -- and during those 100ms the client keeps
# streaming the operator's still-moving hand pose, so the arm visibly kept going
# after they let go. Two thresholds give the same chatter immunity with ZERO
# release delay: engage above PRESS, drop below RELEASE, hold state in between.
const ENABLE_PRESS_THRESHOLD := 0.6
const ENABLE_RELEASE_THRESHOLD := 0.4
const HandGestureMapperScript = preload("res://scripts/input/hand_gesture_mapper.gd")

# --- Driving hand -------------------------------------------------------------
# One controller drives one arm. Rather than hard-coding "right" (which breaks
# outright if only the left controller is powered on), the `active_*` sources
# resolve to whichever hand is DRIVING: the last hand to squeeze its grip, held
# latched until that grip is released. Before any squeeze it falls back to
# whichever controller is actually active, preferring right.
#
# Switching hands is safe: taking over re-triggers enable, so the robot captures
# a fresh baseline at the new hand's pose instead of jumping.
const HAND_LEFT := 0
const HAND_RIGHT := 1
var _driving_hand: int = HAND_RIGHT
var _driving_latched: bool = false


## Which hand currently drives the arm. The overlay gizmo follows this so it is
## always attached to the controller actually in command.
func get_driving_hand() -> int:
	return _driving_hand


## Whether the deadman is currently engaged, using the SAME hysteresis state the
## command stream reports. Callers (e.g. the gizmo's visibility test) must not
## re-threshold the raw grip themselves: a second copy of the thresholds silently
## desyncs from the real enable the moment either is tuned.
func is_deadman_engaged() -> bool:
	for target in _enable_latched:
		if bool(_enable_latched[target]):
			return true
	return false


## Whether the deadman for ONE hand is engaged.
##
## A dual-arm descriptor gives each side its own `left_enable`/`right_enable`
## target, so the any-target [method is_deadman_engaged] above cannot answer
## per-hand: it reports true for BOTH hands as soon as either grip is squeezed,
## which would leave the idle hand's overlay drawn as if that arm were live.
## Single-arm descriptors use an unprefixed `enable`, which belongs to whichever
## hand is currently driving.
func is_deadman_engaged_for_hand(hand: int) -> bool:
	var side_target := "left_enable" if hand == HAND_LEFT else "right_enable"
	if _enable_latched.has(side_target):
		return bool(_enable_latched[side_target])
	if hand == _driving_hand:
		return bool(_enable_latched.get("enable", false))
	return false


# Per-frame cache of get_controller_input(hand). Resolving the driving hand
# needs both hands' grips, and the mapping loop then re-reads the driving hand's
# inputs, so without this a single command rebuilt the same input Dictionaries
# several times per frame. That cost lands in _process, which is also where
# commands are sent, so it shows up directly as a lower delivered command rate.
var _input_cache: Dictionary = {}
var _hand_target_cache: Dictionary = {}
var _hand_joint_cache: Dictionary = {}
var _hand_control_unlocked := false


func _cached_input(tracking: TrackingProvider, hand: int) -> Dictionary:
	if _input_cache.has(hand):
		return _input_cache[hand]
	var input: Dictionary = tracking.get_controller_input(hand)
	_input_cache[hand] = input
	return input


func _update_driving_hand(tracking: TrackingProvider) -> void:
	var grip := [_get_grip_value(tracking, HAND_LEFT), _get_grip_value(tracking, HAND_RIGHT)]

	if _driving_latched:
		# Stay with this hand until its grip is released, so a stray squeeze from
		# the other hand cannot steal control mid-motion.
		if grip[_driving_hand] < ENABLE_RELEASE_THRESHOLD:
			_driving_latched = false
		return

	# Free: the first hand to cross the press threshold takes command.
	for hand in [HAND_RIGHT, HAND_LEFT]:
		if grip[hand] >= ENABLE_PRESS_THRESHOLD and tracking.is_controller_mode_active(hand):
			_driving_hand = hand
			_driving_latched = true
			return

	# Idle: track whichever controller is actually usable, preferring right.
	if tracking.is_controller_mode_active(HAND_RIGHT):
		_driving_hand = HAND_RIGHT
	elif tracking.is_controller_mode_active(HAND_LEFT):
		_driving_hand = HAND_LEFT


func configure(descriptor: Dictionary) -> void:
	_descriptor = descriptor
	_mappings = descriptor.get("input_mapping", [])
	_dead_zones.clear()
	_button_targets.clear()
	_hand_control_unlocked = false
	# Build dead zone lookup from control_schema.axes
	var schema = descriptor.get("control_schema", {})
	for axis_def in schema.get("axes", []):
		_dead_zones[axis_def["name"]] = axis_def.get("dead_zone", 0.0)
	for button_def in schema.get("buttons", []):
		_button_targets[button_def["name"]] = button_def


func collect_command(tracking: TrackingProvider) -> Dictionary:
	# Fresh inputs each command; the cache only dedupes within this one frame.
	_input_cache.clear()
	_hand_target_cache.clear()
	_hand_joint_cache.clear()
	# Resolve the driving hand BEFORE reading any source, so every `active_*`
	# lookup in this frame refers to the same controller.
	_update_driving_hand(tracking)
	# Stamp with the SAME unix-epoch clock RobotClockSync.now_ns() uses for its
	# ClockPing t_xr_send. The bridge's clock offset is derived from ClockPing, so
	# the command timestamp must share that clock or the offset cannot cancel and
	# the xr->rx / e2e latency segments come out as raw clock skew (garbage).
	# (Was Time.get_ticks_usec()*1000 — a monotonic, boot-relative clock.)
	var cmd = {"axes": {}, "buttons": {}, "poses": {}, "timestamp_ns": RobotClockSync.now_ns()}
	for mapping in _mappings:
		var source: String = mapping["source"]
		var target: String = mapping["target"]
		var scale: float = mapping.get("scale", 1.0)
		var invert: bool = mapping.get("invert", false)
		var offset: float = mapping.get("offset", 0.0)

		var value = _read_vr_source(source, tracking)
		if value == null:
			continue

		if _is_enable_target(target):
			# Hysteresis, not a release grace: crossing PRESS engages, crossing
			# RELEASE disengages immediately, in between holds. Release therefore
			# reaches the robot on the very next send (~14ms) instead of 100ms late.
			var enable_scalar := _source_value_to_scalar(value, scale, invert, offset)
			var enable_pressed := bool(_enable_latched.get(target, false))
			if enable_scalar >= ENABLE_PRESS_THRESHOLD:
				enable_pressed = true
			elif enable_scalar < ENABLE_RELEASE_THRESHOLD:
				enable_pressed = false
			_enable_latched[target] = enable_pressed
			cmd["buttons"][target] = bool(cmd["buttons"].get(target, false)) or enable_pressed
			continue

		if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			var fval: float = float(value)
			if invert: fval = -fval
			fval = fval * scale + offset
			if _button_targets.has(target):
				cmd["buttons"][target] = fval >= 0.5
			else:
				# Apply dead zone
				var dz = _dead_zones.get(target, 0.0)
				if absf(fval) < dz: fval = 0.0
				cmd["axes"][target] = fval
		elif typeof(value) == TYPE_BOOL:
			cmd["buttons"][target] = value
		elif value is Dictionary and value.has("position"):
			# Never forward a pose from an untracked source. get_controller_pose()
			# reports is_active=false (and may hand back a cached value) when the
			# controller is off or lost, and publishing that ships a stale pose to
			# the robot. This was previously only masked by the deadman reading 0
			# from the same dead controller -- safety by coincidence, not design.
			if not bool(value.get("is_active", true)):
				continue
			cmd["poses"][target] = {
				"position": [value["position"].x, value["position"].y, value["position"].z],
				"rotation": [value["rotation"].x, value["rotation"].y, value["rotation"].z, value["rotation"].w]
			}
	return cmd


func _read_vr_source(source: String, tracking: TrackingProvider) -> Variant:
	var hand_binding: Array = HandGestureMapperScript.source_binding(source)
	if hand_binding.size() == 2:
		return _get_hand_target(tracking, int(hand_binding[0]), int(hand_binding[1]))
	# Map all possible VR input sources
	match source:
		"left_hand_clutch": return _get_hand_clutch(tracking, HAND_LEFT)
		"right_hand_clutch": return _get_hand_clutch(tracking, HAND_RIGHT)
		"left_joystick_x": return _get_input(tracking, 0, "joystick").x
		"left_joystick_y": return _get_input(tracking, 0, "joystick").y
		"right_joystick_x": return _get_input(tracking, 1, "joystick").x
		"right_joystick_y": return _get_input(tracking, 1, "joystick").y
		"left_trigger": return _get_input_float(tracking, 0, "trigger")
		"right_trigger": return _get_input_float(tracking, 1, "trigger")
		"left_grip": return _get_grip_value(tracking, 0)
		"right_grip": return _get_grip_value(tracking, 1)
		"button_a": return _get_input_bool(tracking, 1, "ax_button")
		"button_b": return _get_input_bool(tracking, 1, "by_button")
		"button_x": return _get_input_bool(tracking, 0, "ax_button")
		"button_y": return _get_input_bool(tracking, 0, "by_button")
		"right_controller_pose": return tracking.get_controller_pose(1)
		"left_controller_pose": return tracking.get_controller_pose(0)
		"head_pose": return tracking.get_head_pose()
		"right_hand_joints": return tracking.get_hand_joints(1)
		"left_hand_joints": return tracking.get_hand_joints(0)
		"left_joystick_click": return _get_input_bool(tracking, 0, "primary_click")
		"right_joystick_click": return _get_input_bool(tracking, 1, "primary_click")
		# Hand-agnostic sources: resolve to whichever controller is driving, so a
		# single-arm setup works with EITHER controller instead of only the right.
		"active_controller_pose": return tracking.get_controller_pose(_driving_hand)
		"active_grip": return _get_grip_value(tracking, _driving_hand)
		"active_trigger": return _get_input_float(tracking, _driving_hand, "trigger")
		"active_joystick_x": return _get_input(tracking, _driving_hand, "joystick").x
		"active_joystick_y": return _get_input(tracking, _driving_hand, "joystick").y
		"active_joystick_click": return _get_input_bool(tracking, _driving_hand, "primary_click")
		"active_button_a": return _get_input_bool(tracking, _driving_hand, "ax_button")
		"active_button_b": return _get_input_bool(tracking, _driving_hand, "by_button")
		"active_hand_joints": return tracking.get_hand_joints(_driving_hand)
	return null


func _get_hand_target(tracking: TrackingProvider, hand: int, channel: int) -> float:
	if not _hand_target_cache.has(hand):
		_hand_target_cache[hand] = HandGestureMapperScript.targets_from_tracking(
			_cached_hand_joints(tracking, hand),
			_cached_input(tracking, hand)
		)
	var targets: PackedFloat64Array = _hand_target_cache[hand]
	if channel < 0 or channel >= targets.size():
		return 0.0
	return clampf(float(targets[channel]), 0.0, 1.0)


func _get_hand_clutch(tracking: TrackingProvider, hand: int) -> float:
	var joints := _cached_hand_joints(tracking, hand)
	if not _hand_control_unlocked:
		return 0.0
	return 1.0 if HandGestureMapperScript.has_required_joints(joints) else 0.0


func set_hand_control_unlocked(unlocked: bool) -> void:
	_hand_control_unlocked = unlocked
	if not unlocked:
		for target in _enable_latched:
			if _is_enable_target(str(target)):
				_enable_latched[target] = false


func is_hand_control_unlocked() -> bool:
	return _hand_control_unlocked


func get_hand_control_state(hand: int) -> Dictionary:
	var joints_v: Variant = _hand_joint_cache.get(hand, [])
	var joints: Array = joints_v if joints_v is Array else []
	var wrist_position: Variant = HandGestureMapperScript.wrist_position(joints)
	return {
		"tracked": wrist_position is Vector3,
		"position": wrist_position,
		"index_tip": HandGestureMapperScript.index_tip_position(joints),
		"wrist_button_transform": HandGestureMapperScript.wrist_button_transform(joints),
		"control_enabled": is_deadman_engaged_for_hand(hand),
	}


func _cached_hand_joints(tracking: TrackingProvider, hand: int) -> Array:
	if _hand_joint_cache.has(hand):
		return _hand_joint_cache[hand]
	var joints: Array = tracking.get_hand_joints(hand)
	_hand_joint_cache[hand] = joints
	return joints


## Scaled numeric form of a VR source, so a caller can apply its own thresholds
## (the deadman needs two, for hysteresis). Mirrors `_source_value_to_button`'s
## scale/invert/offset handling exactly; that function is this plus `>= 0.5`.
func _source_value_to_scalar(value: Variant, scale: float, invert: bool, offset: float) -> float:
	if typeof(value) == TYPE_BOOL:
		return 1.0 if bool(value) else 0.0
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		var numeric_value := float(value)
		if invert:
			numeric_value = -numeric_value
		return numeric_value * scale + offset
	if value is Vector2:
		var vector_value: Vector2 = value
		var vector_magnitude := vector_value.length()
		if invert:
			vector_magnitude = -vector_magnitude
		return vector_magnitude * scale + offset
	return 0.0


func _source_value_to_button(value: Variant, scale: float, invert: bool, offset: float) -> bool:
	if typeof(value) == TYPE_BOOL:
		return bool(value)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		var numeric_value := float(value)
		if invert:
			numeric_value = -numeric_value
		numeric_value = numeric_value * scale + offset
		return numeric_value >= 0.5
	if value is Vector2:
		var vector_value: Vector2 = value
		var vector_magnitude := vector_value.length()
		if invert:
			vector_magnitude = -vector_magnitude
		vector_magnitude = vector_magnitude * scale + offset
		return vector_magnitude >= 0.5
	return false


func _is_enable_target(target: String) -> bool:
	return target == "enable" or target.ends_with("_enable")


# Helper methods to safely extract input values
func _get_input(tracking: TrackingProvider, hand: int, key: String) -> Vector2:
	var input := _cached_input(tracking, hand)
	if input.is_empty(): return Vector2.ZERO
	var val = input.get(key, Vector2.ZERO)
	if val is Vector2: return val
	return Vector2.ZERO


func _get_input_float(tracking: TrackingProvider, hand: int, key: String) -> float:
	var input := _cached_input(tracking, hand)
	if input.is_empty(): return 0.0
	return float(input.get(key, 0.0))


func _get_grip_value(tracking: TrackingProvider, hand: int) -> float:
	var input := _cached_input(tracking, hand)
	if input.is_empty(): return 0.0
	return maxf(
		float(input.get("grip", 0.0)),
		maxf(float(input.get("grip_click", 0.0)), float(input.get("grip_force", 0.0)))
	)


func _get_input_bool(tracking: TrackingProvider, hand: int, key: String) -> bool:
	var input := _cached_input(tracking, hand)
	if input.is_empty(): return false
	return float(input.get(key, 0.0)) > 0.5
