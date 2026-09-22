extends RefCounted

const CASE_ID := "teleop.revo1_controller_mapping"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var mode := ControlMode.new()
	mode.configure({
		"control_schema": {
			"axes": [
				{"name": "revo1_left_grasp", "dead_zone": 0.0},
			],
			"buttons": [{"name": "left_hand_enable"}],
		},
		"input_mapping": [
			{"source": "left_trigger", "target": "revo1_left_grasp"},
			{"source": "left_controller_active", "target": "left_hand_enable"},
		],
	})
	var tracking := FakeTrackingProvider.new()
	tracking.set_controller_input(0, {"trigger": 0.7, "grip": 0.4})
	var command := mode.collect_command(tracking)
	t.almost_eq(float(command["axes"].get("revo1_left_grasp", 0.0)), 0.7, 0.001,
		"trigger drives the Revo-1 fixed grasp action")
	t.is_true(bool(command["buttons"].get("left_hand_enable", false)),
		"an active physical controller engages the hand stream")

	tracking.set_controller_input(0, {"trigger": 0.0, "grip": 0.0})
	command = mode.collect_command(tracking)
	t.almost_eq(float(command["axes"].get("revo1_left_grasp", 1.0)), 0.0, 0.001,
		"releasing trigger requests the open action")
	t.is_true(bool(command["buttons"].get("left_hand_enable", false)),
		"releasing both analog controls keeps streaming the open target")
	tracking.set_controller_mode_active(0, false)
	command = mode.collect_command(tracking)
	t.is_false(bool(command["buttons"].get("left_hand_enable", true)),
		"losing the physical controller releases the hand stream")
	tracking.free()
