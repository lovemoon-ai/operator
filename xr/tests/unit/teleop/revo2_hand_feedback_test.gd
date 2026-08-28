extends RefCounted

const CASE_ID := "teleop.revo2_hand_feedback"
const GestureMapper = preload("res://scripts/input/hand_gesture_mapper.gd")
const FeedbackOverlay = preload("res://scripts/ui/dexterous_hand_feedback_overlay.gd")
const HandControlIndicatorScript = preload("res://scripts/ui/hand_control_indicator.gd")
const HandPalmMenuScript = preload("res://scripts/ui/hand_unlock_button.gd")
const PalmMenuVisibilityStateScript = preload(
	"res://scripts/ui/palm_menu_visibility_state.gd"
)
const RobotDiscoveryScript = preload("res://scripts/network/discovery.gd")
const TeleopControllerScript = preload("res://scripts/app/modes/teleop_controller.gd")


class FakeCommandSender:
	extends CommandSender


class FakeOutsideTarget:
	extends Node
	var started_with: Dictionary = {}
	var ready := false

	func start(config: Dictionary) -> void:
		started_with = config.duplicate(true)

	func is_ready() -> bool:
		return ready


class FakeTcpHandler:
	extends Node
	var connected := false

	func is_connected_to_robot() -> bool:
		return connected


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var open_targets := GestureMapper.targets_from_tracking(_hand_skeleton(false), {})
	var closed_targets := GestureMapper.targets_from_tracking(_hand_skeleton(true), {})
	var flex_only := GestureMapper.targets_from_tracking(
		_hand_skeleton(false, true, false), {}
	)
	var oppose_only := GestureMapper.targets_from_tracking(
		_hand_skeleton(false, false, true), {}
	)
	t.is_true(float(open_targets[2]) < 0.1, "straight index finger maps near open")
	t.is_true(float(closed_targets[2]) > 0.8, "curled index finger maps near closed")
	t.is_true(float(flex_only[0]) <= 0.5,
		"thumb proximal flex stays below the official SDK safety cap")
	t.is_true(float(flex_only[0]) > 0.4,
		"thumb joint bend drives the first Revo2 motor")
	t.is_true(float(flex_only[1]) < 0.1,
		"thumb joint bend does not drive the abduction motor")
	t.is_true(float(oppose_only[0]) < 0.1,
		"thumb opposition does not drive the flex motor")
	t.is_true(float(oppose_only[1]) > 0.75 and float(oppose_only[1]) <= 0.85,
		"thumb opposition drives the second Revo2 motor")

	var fallback := GestureMapper.targets_from_tracking([], {"trigger": 0.7, "grip": 0.4})
	t.almost_eq(float(fallback[0]), 0.35, 0.001,
		"trigger controls capped fallback thumb flex")
	t.almost_eq(float(fallback[1]), 0.35, 0.001,
		"trigger controls fallback thumb auxiliary")
	t.almost_eq(float(fallback[2]), 0.7, 0.001, "trigger controls fallback index")
	t.almost_eq(float(fallback[5]), 0.4, 0.001, "grip controls fallback pinky")
	var open_palm := _mirrored_hand_x(_hand_skeleton(false))
	var palm_menu: Dictionary = GestureMapper.palm_menu_state(
		open_palm, Vector3(0.0, 0.0, 0.5), GestureMapper.HAND_LEFT
	)
	t.is_true(bool(palm_menu.get("tracked", false)),
		"tracked wrist, palm, and fingers produce palm-menu state")
	t.is_true(float(palm_menu.get("facing", -1.0)) > 0.95,
		"left palm facing the headset passes the facing test")
	t.is_true(float(palm_menu.get("openness", 0.0)) > 0.8,
		"five extended fingers pass the open-hand test")
	t.is_true((palm_menu.get("anchor_position") as Vector3).y < -0.09,
		"palm menu anchor sits below the hand toward the forearm")
	var back_of_hand: Dictionary = GestureMapper.palm_menu_state(
		open_palm, Vector3(0.0, 0.0, -0.5), GestureMapper.HAND_LEFT
	)
	t.is_true(float(back_of_hand.get("facing", 1.0)) < -0.95,
		"showing the back of the hand fails the palm-facing test")
	var right_palm: Dictionary = GestureMapper.palm_menu_state(
		_hand_skeleton(false), Vector3(0.0, 0.0, 0.5), GestureMapper.HAND_RIGHT
	)
	t.is_true(float(right_palm.get("facing", -1.0)) > 0.95,
		"right-palm orientation follows the same anatomical convention")
	var one_finger_closed := _hand_skeleton(false)
	_set_chain(
		one_finger_closed,
		[16, 17, 18, 19, 20],
		Vector3(0.018, 0.0, 0.0),
		true,
	)
	var closed_palm: Dictionary = GestureMapper.palm_menu_state(
		one_finger_closed, Vector3(0.0, 0.0, 0.5), GestureMapper.HAND_LEFT
	)
	t.is_true(float(closed_palm.get("openness", 1.0)) < 0.3,
		"closing any finger prevents an open-palm pose")
	var missing_palm := open_palm.duplicate(true)
	missing_palm[0] = {"tracked": false}
	t.is_true(not bool(GestureMapper.palm_menu_state(
		missing_palm, Vector3(0.0, 0.0, 0.5), GestureMapper.HAND_LEFT
	).get("tracked", true)), "losing a required palm joint invalidates the menu pose")

	var visibility := PalmMenuVisibilityStateScript.new()
	t.is_true(not visibility.update(true, 1.0, 1.0, 0.10),
		"palm menu waits for a stable entry pose")
	t.is_true(visibility.update(true, 1.0, 1.0, 0.08),
		"palm menu appears after the stable entry interval")
	t.is_true(visibility.update(true, 0.65, 0.65, 0.20),
		"exit hysteresis keeps the menu visible near the entry threshold")
	t.is_true(visibility.update(true, 0.30, 1.0, 0.06),
		"a brief palm rotation does not flicker the menu")
	t.is_true(not visibility.update(true, 0.30, 1.0, 0.07),
		"a sustained palm rotation hides the menu")
	visibility.update(true, 1.0, 1.0, 0.18)
	t.is_true(not visibility.update(false, 1.0, 1.0, 0.0),
		"required-joint tracking loss hides the menu immediately")
	var palm_menu_node := HandPalmMenuScript.new()
	t.eq(_full_size_panel_count(palm_menu_node, Vector2(HandPalmMenuScript.VIEWPORT_SIZE)), 0,
		"palm menu composition layer has no opaque full-size gray backplate")
	palm_menu_node.free()

	var button_center := HandPalmMenuScript.button_center_local()
	t.eq(HandPalmMenuScript.touch_phase(
		Vector3(button_center.x, button_center.y, 0.030)), "arm",
		"right fingertip approaching the palm menu arms direct touch")
	t.eq(HandPalmMenuScript.touch_phase(
		Vector3(button_center.x, button_center.y, 0.012)), "arm",
		"palm menu stays armed while crossing the approach region")
	t.eq(HandPalmMenuScript.touch_phase(
		Vector3(button_center.x, button_center.y, 0.004)), "press",
		"right fingertip entering the button volume reaches the press phase")
	t.is_true(HandPalmMenuScript.touch_released(
		Vector3(button_center.x, button_center.y, 0.030)),
		"retracting the fingertip releases the palm-menu button")
	t.is_true(HandPalmMenuScript.touch_released(
		Vector3(button_center.x + 0.060, button_center.y, 0.004)),
		"moving the fingertip away sideways releases the palm-menu button")
	t.eq(HandPalmMenuScript.visual_scale_for_phase("arm"), Vector2(1.035, 1.035),
		"approaching the palm-menu button makes it grow")
	t.eq(HandPalmMenuScript.visual_scale_for_phase("press"), Vector2(0.94, 0.88),
		"pressing the palm-menu button makes it visibly sink")
	t.is_true(HandPalmMenuScript.should_trigger_armed_touch("press", false, true),
		"a single fingertip contact triggers immediately")
	t.is_true(not HandPalmMenuScript.should_trigger_armed_touch("press", true, true),
		"holding contact cannot trigger repeatedly")
	t.is_true(not HandPalmMenuScript.should_trigger_armed_touch("press", false, false),
		"a menu appearing around an already-touching finger cannot auto-unlock")
	t.eq(HandPalmMenuScript.feedback_event_for_state(true), "toggle_on",
		"unlock press plays the ascending system prompt")
	t.eq(HandPalmMenuScript.feedback_event_for_state(false), "toggle_off",
		"lock press plays the descending system prompt")
	var display_transform := HandPalmMenuScript.face_head_transform(
		Vector3(0.2, -0.3, -0.5), Transform3D.IDENTITY
	)
	var to_head := -display_transform.origin.normalized()
	t.is_true(display_transform.basis.z.distance_to(to_head) < 0.0001,
		"palm-menu text faces the headset")
	var expected_up := (Vector3.UP - to_head * Vector3.UP.dot(to_head)).normalized()
	t.is_true(display_transform.basis.y.distance_to(expected_up) < 0.0001,
		"palm-menu text remains upright for the operator")

	var control_mode := ControlMode.new()
	control_mode.configure({
		"control_schema": {"axes": [{"name": "left_index", "dead_zone": 0.0}]},
		"input_mapping": [{
			"source": "left_hand_index_flex",
			"target": "left_index",
			"scale": 1.0,
			"invert": false,
			"offset": 0.0,
		}],
	})
	var tracking := FakeTrackingProvider.new()
	tracking.set_hand_joints(0, _hand_skeleton(true))
	var command := control_mode.collect_command(tracking)
	t.is_true(float(command.get("axes", {}).get("left_index", 0.0)) > 0.8,
		"descriptor mapping publishes the computed hand channel")
	tracking.free()
	var clutch_mode := ControlMode.new()
	clutch_mode.configure({
		"control_schema": {"buttons": [
			{"name": "left_enable"},
			{"name": "right_enable"},
		]},
		"input_mapping": [
			{
				"source": "left_hand_clutch",
				"target": "left_enable",
				"scale": 1.0,
				"invert": false,
				"offset": 0.0,
			},
			{
				"source": "right_hand_clutch",
				"target": "right_enable",
				"scale": 1.0,
				"invert": false,
				"offset": 0.0,
			},
		],
	})
	var clutch_tracking := FakeTrackingProvider.new()
	clutch_tracking.set_hand_joints(0, _hand_skeleton(false))
	clutch_tracking.set_hand_joints(1, _hand_skeleton(false))
	var locked_command := clutch_mode.collect_command(clutch_tracking)
	t.is_true(not bool(locked_command.get("buttons", {}).get("left_enable", false)),
		"manual lock disables the left hand")
	t.is_true(not bool(locked_command.get("buttons", {}).get("right_enable", false)),
		"manual lock disables the right hand")
	var locked_state: Dictionary = clutch_mode.get_hand_control_state(0)
	t.is_true(bool(locked_state.get("tracked", false)),
		"wrist indicator receives the tracked bare-hand position")
	t.eq(locked_state.get("position"), Vector3(0.0, -0.05, 0.0),
		"wrist indicator uses the OpenXR wrist joint")
	t.is_true(not bool(locked_state.get("control_enabled", true)),
		"wrist state reports the clutch independently from network status")
	t.eq(
		HandControlIndicatorScript.status_color(false, false),
		HandControlIndicatorScript.DISCONNECTED_COLOR,
		"disconnected robot uses the gray wrist indicator")
	t.eq(
		HandControlIndicatorScript.status_color(true, false),
		HandControlIndicatorScript.CONNECTED_COLOR,
		"connected but locked hand uses the green wrist indicator")
	clutch_mode.set_hand_control_unlocked(true)
	var unlocked_command := clutch_mode.collect_command(clutch_tracking)
	t.is_true(bool(unlocked_command.get("buttons", {}).get("left_enable", false)),
		"manual unlock enables the tracked left hand")
	t.is_true(bool(unlocked_command.get("buttons", {}).get("right_enable", false)),
		"manual unlock enables the tracked right hand")
	t.is_true(bool(clutch_mode.get_hand_control_state(0).get("control_enabled", false)),
		"wrist state exposes the exact manual unlock state")
	t.eq(
		HandControlIndicatorScript.status_color(true, true),
		HandControlIndicatorScript.CONTROL_ENABLED_COLOR,
		"manual unlock uses the orange wrist indicator")
	var partial_left := _hand_skeleton(false)
	partial_left[10] = {"tracked": false}
	clutch_tracking.set_hand_joints(0, partial_left)
	var partial_command := clutch_mode.collect_command(clutch_tracking)
	t.is_true(not bool(partial_command.get("buttons", {}).get("left_enable", true)),
		"partial finger tracking disables that hand even when the wrist remains tracked")
	t.is_true(bool(partial_command.get("buttons", {}).get("right_enable", false)),
		"partial tracking on one hand does not stop the other hand")
	clutch_tracking.set_hand_joints(0, _hand_skeleton(false))
	t.eq(HandPalmMenuScript.status_text(false, true), "解锁",
		"locked button offers the unlock action")
	t.eq(HandPalmMenuScript.status_text(true, true), "锁定",
		"unlocked button offers the lock action")
	t.eq(HandPalmMenuScript.status_text(false, false), "未连接",
		"unavailable button reports the disconnected state")
	clutch_tracking.set_hand_joints(0, [])
	var lost_command := clutch_mode.collect_command(clutch_tracking)
	t.is_true(not bool(lost_command.get("buttons", {}).get("left_enable", true)),
		"tracking loss releases control immediately")
	t.is_true(bool(lost_command.get("buttons", {}).get("right_enable", false)),
		"tracking loss on one side does not stop the other hand")
	t.is_true(not bool(clutch_mode.get_hand_control_state(0).get("tracked", true)),
		"wrist indicator hides when hand tracking is lost")
	clutch_tracking.set_hand_joints(0, _hand_skeleton(false))
	clutch_mode.set_hand_control_unlocked(false)
	var relocked_command := clutch_mode.collect_command(clutch_tracking)
	t.is_true(not bool(relocked_command.get("buttons", {}).get("left_enable", true)),
		"manual lock stops the left hand")
	t.is_true(not bool(relocked_command.get("buttons", {}).get("right_enable", true)),
		"manual lock stops the right hand")
	clutch_tracking.free()

	var parsed := FeedbackOverlay.parse_telemetry({"values": {
		"revo2_left_target": [100, 200, 300, 400, 500, 600],
		"revo2_left_position": [90, 180, 250, 390, 480, 590],
		"revo2_left_current": [10, 20, 30, 40, 50, 60],
		"revo2_left_stall": [0, 0, 1, 0, 0, 0],
	}})
	t.is_true(bool(parsed.get("left", {}).get("valid", false)),
		"six-element Revo2 telemetry is accepted")
	t.is_true(not bool(parsed.get("right", {}).get("valid", true)),
		"missing hand telemetry stays hidden")
	t.eq(float(parsed.get("left", {}).get("stall", [])[2]), 1.0,
		"STALL channel survives telemetry parsing")
	t.eq(FeedbackOverlay.current_color(0.0), FeedbackOverlay.CURRENT_LOW,
		"low current uses the safe color")
	t.eq(FeedbackOverlay.current_color(0.0, true), FeedbackOverlay.CURRENT_HIGH,
		"STALL overrides current with the alert color")

	var discovery := RobotDiscoveryScript.new()
	discovery._process_announcement(JSON.stringify({
		"service": "xrobo-agent",
		"name": "test-bridge",
		"tcp_port": 64001,
		"video_port": 0,
		"telemetry_port": 64009,
		"device_type": "revo2_dual_hand",
	}), "192.0.2.10")
	var discovered: Dictionary = discovery.get_known_robots()
	t.eq(int((discovered["test-bridge"] as Dictionary).get("telemetry_port", 0)), 64009,
		"discovery preserves the dedicated telemetry port")
	var controller := TeleopControllerScript.new()
	controller._known_robots = {"192.0.2.10": discovered["test-bridge"]}
	t.eq(controller._telemetry_port_for("192.0.2.10", 64001), 64009,
		"teleop uses the discovered telemetry port")
	t.eq(controller._telemetry_port_for("192.0.2.11", 63901), 63903,
		"manual endpoints derive the standard telemetry port")
	var command_sender := FakeCommandSender.new()
	var outside_target := FakeOutsideTarget.new()
	var tcp_handler := FakeTcpHandler.new()
	controller._command_sender = command_sender
	controller._outside_target = outside_target
	controller._active_target = outside_target
	controller._tcp_handler = tcp_handler
	controller._revo2_hand_control_unlocked = true
	controller._connect_to_robot("192.0.2.10", 64001)
	t.is_true(not controller._revo2_hand_control_unlocked,
		"starting a new connection always restores the locked state")
	t.is_true(controller._revo2_hand_runtime_enabled,
		"confirmed/discovered Revo2 configuration activates the working-page runtime")
	t.eq(outside_target.started_with, {"host": "192.0.2.10", "port": 64001},
		"formal runtime starts the selected endpoint after confirmation")
	controller._set_revo2_hand_control_unlocked(true)
	t.is_true(not controller._revo2_hand_control_unlocked,
		"a disconnected palm-menu button cannot unlock hand control")
	tcp_handler.connected = true
	controller._set_revo2_hand_control_unlocked(true)
	t.is_true(not controller._revo2_hand_control_unlocked,
		"transport connection alone cannot unlock before the descriptor is ready")
	outside_target.ready = true
	controller._set_revo2_hand_control_unlocked(true)
	t.is_true(controller._revo2_hand_control_unlocked,
		"an explicit touch may unlock only after the target is ready")
	controller._set_teleop_suspended(true)
	t.is_true(not controller._revo2_hand_control_unlocked,
		"opening settings always restores the locked state")
	t.is_true(TeleopControllerScript._descriptor_supports_revo2_hand_runtime(
		_revo2_capability_descriptor()),
		"authoritative descriptor capabilities activate Revo2 without a vendor type")
	t.is_true(not TeleopControllerScript._descriptor_supports_revo2_hand_runtime({
		"device": {"type": "robot_arm"},
		"control_schema": {"axes": []},
		"telemetry_schema": {"values": []},
	}), "unrelated formal configurations do not show Revo2 controls")
	controller.free()
	command_sender.free()
	outside_target.free()
	tcp_handler.free()
	discovery.free()


func _full_size_panel_count(root: Node, viewport_size: Vector2) -> int:
	var count := 0
	for child in root.get_children():
		if child is Panel:
			var panel := child as Panel
			if panel.size.x >= viewport_size.x * 0.85 \
					and panel.size.y >= viewport_size.y * 0.85:
				count += 1
		count += _full_size_panel_count(child, viewport_size)
	return count


func _revo2_capability_descriptor() -> Dictionary:
	var axes: Array = []
	for side in ["left", "right"]:
		for channel in TeleopControllerScript.REVO2_HAND_CHANNELS:
			axes.append({"name": "revo2_%s_%s" % [side, channel]})
	return {
		"device": {"type": "custom_dual_hand"},
		"control_schema": {"axes": axes},
		"telemetry_schema": {"values": [
			{"name": "revo2_left_position"},
			{"name": "revo2_right_position"},
		]},
	}


func _hand_skeleton(
	curled: bool,
	thumb_flexed: Variant = null,
	thumb_opposed: Variant = null,
) -> Array[Dictionary]:
	if thumb_flexed == null:
		thumb_flexed = curled
	if thumb_opposed == null:
		thumb_opposed = curled
	var joints: Array[Dictionary] = []
	for _i in range(26):
		joints.append({"tracked": false})
	joints[0] = {"tracked": true, "position": Vector3(0.0, -0.025, 0.0)}
	joints[1] = {"tracked": true, "position": Vector3(0.0, -0.05, 0.0)}

	_set_chain(joints, [6, 7, 8, 9, 10], Vector3(-0.018, 0.0, 0.0), curled)
	_set_chain(joints, [11, 12, 13, 14, 15], Vector3(0.0, 0.0, 0.0), curled)
	_set_chain(joints, [16, 17, 18, 19, 20], Vector3(0.018, 0.0, 0.0), curled)
	_set_chain(joints, [21, 22, 23, 24, 25], Vector3(0.036, 0.0, 0.0), curled)
	_set_thumb(joints, bool(thumb_flexed), bool(thumb_opposed))
	return joints


func _mirrored_hand_x(joints: Array[Dictionary]) -> Array[Dictionary]:
	var mirrored := joints.duplicate(true)
	for joint_v in mirrored:
		var joint := joint_v as Dictionary
		if not bool(joint.get("tracked", false)):
			continue
		var position := joint.get("position", Vector3.ZERO) as Vector3
		position.x = -position.x
		joint["position"] = position
	return mirrored


func _set_thumb(joints: Array[Dictionary], flexed: bool, opposed: bool) -> void:
	var metacarpal := Vector3(-0.035, 0.0, 0.0)
	var proximal: Vector3
	if opposed:
		proximal = Vector3(-0.030, 0.020, 0.0)
	else:
		proximal = Vector3(-0.052, 0.008, 0.0)
	var distal: Vector3
	var tip: Vector3
	if flexed:
		distal = proximal + Vector3(0.0, 0.0, 0.017)
		tip = distal + Vector3(0.0, -0.017, 0.0)
	else:
		var thumb_axis := proximal - metacarpal
		distal = proximal + thumb_axis
		tip = distal + thumb_axis
	joints[2] = {"tracked": true, "position": metacarpal}
	joints[3] = {"tracked": true, "position": proximal}
	joints[4] = {"tracked": true, "position": distal}
	joints[5] = {"tracked": true, "position": tip}


func _set_chain(
	joints: Array[Dictionary],
	indices: Array,
	base: Vector3,
	curled: bool,
) -> void:
	var points: Array[Vector3]
	if curled:
		points = [
			base,
			base + Vector3(0.0, 0.022, 0.0),
			base + Vector3(0.016, 0.022, 0.0),
			base + Vector3(0.016, 0.006, 0.0),
			base + Vector3(0.003, 0.006, 0.0),
		]
	else:
		points = [
			base,
			base + Vector3(0.0, 0.022, 0.0),
			base + Vector3(0.0, 0.044, 0.0),
			base + Vector3(0.0, 0.066, 0.0),
			base + Vector3(0.0, 0.088, 0.0),
		]
	for i in range(indices.size()):
		joints[int(indices[i])] = {"tracked": true, "position": points[i]}
