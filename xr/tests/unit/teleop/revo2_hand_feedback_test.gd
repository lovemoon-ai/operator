extends RefCounted

const CASE_ID := "teleop.revo2_hand_feedback"
const GestureMapper = preload("res://scripts/input/hand_gesture_mapper.gd")
const TargetFilter = preload("res://scripts/input/hand_target_filter.gd")
const FeedbackOverlay = preload("res://scripts/ui/dexterous_hand_feedback_overlay.gd")
const TactileOverlay = preload("res://scripts/ui/dexterous_hand_tactile_overlay.gd")
const HandControlIndicatorScript = preload("res://scripts/ui/hand_control_indicator.gd")
const HandPalmMenuScript = preload("res://scripts/ui/hand_unlock_button.gd")
const ControlFrameGizmoScript = preload("res://scripts/ui/control_frame_gizmo.gd")
const TcpHandlerScript = preload("res://scripts/network/tcp_handler.gd")
const PalmMenuVisibilityStateScript = preload(
	"res://scripts/ui/palm_menu_visibility_state.gd"
)
const RobotDiscoveryScript = preload("res://scripts/network/discovery.gd")
const TeleopControllerScript = preload("res://scripts/app/modes/teleop_controller.gd")
const BlueprintRuntimeScript = preload(
	"res://scripts/blueprint/blueprint_runtime.gd"
)


class FakeCommandSender:
	extends CommandSender


class FakeOutsideTarget:
	extends Node
	var started_with: Dictionary = {}
	var target_ready := false

	func start(config: Dictionary) -> void:
		started_with = config.duplicate(true)

	func is_ready() -> bool:
		return target_ready


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
	var pinch_targets := GestureMapper.targets_from_tracking(_pinch_hand_skeleton(), {})
	t.is_true(float(open_targets[2]) < 0.1, "straight index finger maps near open")
	t.is_true(float(closed_targets[2]) > 0.8, "curled index finger maps near closed")
	t.is_true(float(flex_only[0]) < 0.1,
		"thumb joint bend does not drive the metacarpal motor")
	t.is_true(float(flex_only[1]) > 0.8 and float(flex_only[1]) <= 0.87,
		"thumb joint bend drives the second Revo2 motor")
	t.is_true(float(oppose_only[0]) > 0.45 and float(oppose_only[0]) <= 0.5,
		"thumb opposition drives the first Revo2 motor")
	t.is_true(float(oppose_only[1]) < 0.1,
		"thumb opposition does not drive the proximal motor")
	t.is_true(float(pinch_targets[0]) > 0.25,
		"thumb-index proximity adds opposition for a natural pinch")

	var fallback := GestureMapper.targets_from_tracking([], {"trigger": 0.7, "grip": 0.4})
	t.almost_eq(float(fallback[0]), 0.35, 0.001,
		"trigger controls fallback thumb opposition")
	t.almost_eq(float(fallback[1]), 0.609, 0.001,
		"trigger controls fallback thumb flex")
	t.almost_eq(float(fallback[2]), 0.7, 0.001, "trigger controls fallback index")
	t.almost_eq(float(fallback[5]), 0.4, 0.001, "grip controls fallback pinky")
	var target_filter := TargetFilter.new()
	var filter_start := target_filter.filter(
		PackedFloat64Array([0.2, 0.3, 0.4, 0.4, 0.4, 0.4]), 1_000_000
	)
	var filter_jitter := target_filter.filter(
		PackedFloat64Array([0.202, 0.302, 0.402, 0.402, 0.402, 0.402]), 1_014_000
	)
	t.eq(filter_jitter, filter_start, "sub-deadband tracking jitter is held")
	var filter_motion := target_filter.filter(
		PackedFloat64Array([0.4, 0.6, 0.8, 0.8, 0.8, 0.8]), 1_028_000
	)
	t.is_true(float(filter_motion[2]) > 0.4 and float(filter_motion[2]) < 0.8,
		"fast motion passes promptly without an unfiltered step")
	target_filter.reset()
	var finite_filter := target_filter.filter(
		PackedFloat64Array([NAN, 0.2, 0.3, 0.3, 0.3, 0.3]), 2_000_000
	)
	t.almost_eq(float(finite_filter[0]), 0.0, 0.0001,
		"non-finite tracking targets reset to a safe open command")
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
	var invalid_wrist_joints := open_palm.duplicate(true)
	invalid_wrist_joints[1]["position"] = Vector3(NAN, 0.0, 0.0)
	t.eq(GestureMapper.wrist_position(invalid_wrist_joints), null,
		"non-finite wrist tracking cannot reach a wrist-mounted render node")
	t.is_true(not bool(GestureMapper.palm_menu_state(
		open_palm, Vector3(INF, 0.0, 0.0), GestureMapper.HAND_LEFT
	).get("tracked", true)), "non-finite head tracking cannot place the palm menu")
	var distant_palm := open_palm.duplicate(true)
	for distant_joint_v in distant_palm:
		var distant_joint := distant_joint_v as Dictionary
		if bool(distant_joint.get("tracked", false)):
			distant_joint["position"] = (
				distant_joint.get("position", Vector3.ZERO) as Vector3
			) + Vector3(25.0, 0.0, 0.0)
	t.is_true(bool(GestureMapper.palm_menu_state(
		distant_palm, Vector3(25.0, 0.0, 0.5), GestureMapper.HAND_LEFT
	).get("tracked", false)), "large-room tracking coordinates keep the palm menu valid")

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
	t.is_true(not HandPalmMenuScript.transform_is_safe(
		Transform3D(Basis.IDENTITY, Vector3(NAN, 0.0, 0.0))),
		"non-finite palm-menu positions are rejected before rendering")
	t.is_true(not HandPalmMenuScript.transform_is_safe(
		Transform3D(Basis(Vector3.ZERO, Vector3.UP, Vector3.BACK), Vector3.ZERO)),
		"degenerate palm-menu bases are rejected before inversion")
	t.is_true(not HandControlIndicatorScript.position_is_safe(Vector3(INF, 0.0, 0.0)),
		"non-finite wrist lamp positions are rejected before rendering")
	t.is_true(not ControlFrameGizmoScript._position_is_safe(Vector3(0.0, NAN, 0.0)),
		"non-finite control-frame origins are rejected before rendering")

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
	t.eq((clutch_mode.get_hand_control_state(0).get("joints", []) as Array).size(), 26,
		"tactile feedback reuses the same tracked joints as hand control")
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
	t.eq(FeedbackOverlay.CHANNEL_LABELS[0], "OP",
		"the first feedback row names thumb opposition")
	t.eq(FeedbackOverlay.CHANNEL_LABELS[1], "TF",
		"the second feedback row names thumb flexion")

	var tactile_payload := {"values": {
		"revo2_left_touch_normal": [0, 10, 100, 1000, 10000],
		"revo2_left_touch_tangential": [0, 20, 200, 2000, 20000],
		"revo2_left_touch_direction": [0, 45, 90, 180, 270],
		"revo2_left_touch_proximity": [0, 100, 1000, 10000, 100000],
		"revo2_left_touch_status": [0, 0, 0, 1, 0],
	}}
	var parsed_tactile := TactileOverlay.parse_telemetry(tactile_payload)
	t.is_true(bool(parsed_tactile.get("left", {}).get("valid", false)),
		"complete five-finger tactile telemetry is accepted")
	t.is_true(not bool(parsed_tactile.get("right", {}).get("valid", true)),
		"missing tactile hand telemetry stays hidden")
	t.is_true(not bool(parsed_tactile.get("right", {}).get("present", true)),
		"missing tactile hand telemetry is distinguished from a malformed sample")
	var incomplete_tactile_payload := {"values": {
		"revo2_left_touch_normal": [1, 1, 1, 1, 1],
	}}
	var incomplete_tactile := TactileOverlay.parse_telemetry(incomplete_tactile_payload)
	t.is_true(not bool(incomplete_tactile.get("left", {}).get("valid", true)),
		"partial tactile telemetry is rejected instead of rendered as healthy zeros")
	t.is_true(bool(incomplete_tactile.get("left", {}).get("present", false)),
		"partial tactile telemetry is marked malformed rather than absent")
	var non_finite_tactile := TactileOverlay.parse_telemetry({"values": {
		"revo2_left_touch_normal": [0, 10, NAN, 1000, 10000],
		"revo2_left_touch_tangential": [0, 10, 100, 1000, 10000],
		"revo2_left_touch_direction": [0, 45, 90, 180, 270],
		"revo2_left_touch_proximity": [0, 100, 1000, 10000, 100000],
		"revo2_left_touch_status": [0, 0, 0, 0, 0],
	}})
	t.is_true(not bool(non_finite_tactile.get("left", {}).get("valid", true)),
		"non-finite tactile telemetry is rejected before rendering")
	t.is_true(TactileOverlay.tactile_intensity(1000.0) >
		TactileOverlay.tactile_intensity(10.0),
		"larger raw tactile values produce stronger visual intensity")
	t.almost_eq(TactileOverlay.direction_radians(90.0), PI * 0.5, 0.001,
		"degree tactile direction rotates the fingertip shear marker")
	t.is_true(not TactileOverlay.direction_is_available(65535.0),
		"the unavailable direction sentinel hides the shear marker")
	t.eq(TactileOverlay.tactile_color(0.0, 0.0, 0.2, 1.0),
		TactileOverlay.SENSOR_ERROR_COLOR,
		"abnormal tactile sensors use the explicit error color")
	t.eq(TactileOverlay.tactile_state(0.0, 0.0, 0.0, true),
		TactileOverlay.STATE_STALE,
		"stale telemetry uses the explicit stale state")
	var tactile_overlay := TactileOverlay.new()
	tactile_overlay._build_markers()
	tactile_overlay.update_telemetry(tactile_payload)
	var tactile_update_usec := int(tactile_overlay._last_update_usec["left"])
	tactile_overlay.update_telemetry({"values": {}})
	t.eq(int(tactile_overlay._last_update_usec["left"]), tactile_update_usec,
		"missing tactile keys preserve the last sample for stale-state rendering")
	tactile_overlay.update_telemetry(incomplete_tactile_payload)
	t.eq(int(tactile_overlay._last_update_usec["left"]), 0,
		"malformed tactile keys invalidate the cached sample immediately")
	var tactile_marker := (tactile_overlay._markers["left"] as Array)[0] as Dictionary
	t.is_true(tactile_overlay._update_marker(
		tactile_marker, 1200.0, 3000.0, 90.0, 40000.0, 0.0, false
	), "finite tactile data updates the fingertip marker")
	var tactile_dot := tactile_marker.get("dot") as Label3D
	var tactile_shear := tactile_marker.get("shear") as Label3D
	t.is_true(tactile_dot.modulate.a >= TactileOverlay.ONLINE_MARKER_ALPHA,
		"fresh fingertips remain visible even at low contact")
	t.is_true(tactile_dot.scale.x > TactileOverlay.DOT_MIN_SCALE,
		"normal and proximity intensity scale the fingertip dot")
	t.is_true(tactile_shear.visible,
		"tangential contact renders a directional shear bar")
	t.almost_eq(tactile_shear.rotation.z, PI * 0.5, 0.001,
		"the shear bar follows the reported tactile direction")
	tactile_overlay._update_marker(
		tactile_marker, 1200.0, 3000.0, 90.0, 40000.0, 0.0, true
	)
	t.is_true(not tactile_shear.visible,
		"stale tactile telemetry hides its directional shear bar")
	tactile_overlay.free()

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
	var discovery_key := RobotDiscoveryScript._endpoint_key("192.0.2.10", 64001)
	t.eq(int((discovered[discovery_key] as Dictionary).get("telemetry_port", 0)), 64009,
		"discovery preserves the dedicated telemetry port")
	discovery._process_announcement(JSON.stringify({
		"service": "xrobo-agent",
		"name": "test-bridge",
		"tcp_port": 64001,
		"video_port": 0,
		"device_type": "revo2_dual_hand",
	}), "192.0.2.11")
	discovered = discovery.get_known_robots()
	t.eq(discovered.size(), 2, "discovery preserves same-name services on distinct endpoints")
	var second_discovery_key := RobotDiscoveryScript._endpoint_key("192.0.2.11", 64001)
	discovery._known_robots[discovery_key]["last_seen"] = -100.0
	discovery._check_timeouts()
	discovered = discovery.get_known_robots()
	t.is_false(discovered.has(discovery_key),
		"timeout removes only the expired endpoint identity")
	t.is_true(discovered.has(second_discovery_key),
		"same-name peer remains discovered when the other endpoint expires")
	var controller := TeleopControllerScript.new()
	controller._capture_control_frame_for_hand({"frame": [0.0, NAN, 0.0, 1.0]}, 0,
		"frame", "mirror")
	t.is_true(not bool(controller._control_frame_valid[0]),
		"non-finite telemetry quaternions never reach the control-frame gizmo")
	controller._capture_control_frame_for_hand({"frame": [0.0, 0.0, 0.0, 0.0]}, 0,
		"frame", "mirror")
	t.is_true(not bool(controller._control_frame_valid[0]),
		"zero-length telemetry quaternions never reach the control-frame gizmo")
	controller._known_robots = {
		RobotDiscoveryScript._endpoint_key("192.0.2.10", 64001): {
			"name": "test-bridge",
			"ip": "192.0.2.10",
			"pose_port": 64001,
			"telemetry_port": 64009,
		}
	}
	t.eq(controller._telemetry_port_for("192.0.2.10", 64001), 64009,
		"teleop uses the discovered telemetry port")
	t.eq(controller._telemetry_port_for("192.0.2.11", 63901), 63903,
		"manual endpoints derive the standard telemetry port")
	var tcp_server := TCPServer.new()
	t.eq(tcp_server.listen(0, "127.0.0.1"), OK,
		"loopback server supports the TCP reset regression")
	var raw_tcp_handler := TcpHandlerScript.new()
	t.eq(raw_tcp_handler._tcp.connect_to_host(
		"127.0.0.1", tcp_server.get_local_port()
	), OK, "raw peer starts a connection while logical state remains disconnected")
	raw_tcp_handler.disconnect_from_robot()
	t.eq(raw_tcp_handler._tcp.get_status(), StreamPeerTCP.STATUS_NONE,
		"logical disconnect always recreates a reusable StreamPeerTCP")
	tcp_server.stop()
	raw_tcp_handler.free()
	var command_sender := FakeCommandSender.new()
	command_sender.control_mode = ControlMode.new()
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
	outside_target.target_ready = true
	controller._set_revo2_hand_control_unlocked(true)
	t.is_true(controller._revo2_hand_control_unlocked,
		"an explicit touch may unlock only after the target is ready")
	controller._set_teleop_suspended(true)
	t.is_true(not controller._revo2_hand_control_unlocked,
		"opening settings always restores the locked state")
	var authored_blueprint := BlueprintRuntimeScript.new()
	authored_blueprint._blueprint_id = "brainco.revo2.dual_hand"
	controller._blueprint_runtime = authored_blueprint
	controller._teleop_suspended = false
	controller._refresh_revo2_visualization_ownership()
	t.is_true(command_sender.control_mode.is_hand_control_unlocked(),
		"robot-authored Revo2 UI keeps hand samples flowing for server-side gating")
	authored_blueprint.clear()
	controller._refresh_revo2_visualization_ownership()
	t.is_true(not command_sender.control_mode.is_hand_control_unlocked(),
		"clearing the robot-authored UI restores the legacy local lock")
	t.is_true(TeleopControllerScript._descriptor_supports_revo2_hand_runtime(
		_revo2_capability_descriptor()),
		"authoritative descriptor capabilities activate Revo2 without a vendor type")
	t.is_true(not TeleopControllerScript._descriptor_supports_revo2_hand_runtime({
		"device": {"type": "robot_arm"},
		"control_schema": {"axes": []},
		"telemetry_schema": {"values": []},
	}), "unrelated formal configurations do not show Revo2 controls")
	controller.free()
	authored_blueprint.free()
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


func _pinch_hand_skeleton() -> Array[Dictionary]:
	var joints := _hand_skeleton(false, true, false)
	joints[5]["position"] = joints[10]["position"]
	return joints


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
