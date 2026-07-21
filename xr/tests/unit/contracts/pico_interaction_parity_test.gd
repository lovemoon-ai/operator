extends RefCounted
## Keeps the shared PICO APK on the established interaction contract: explicit
## controller evidence wins, while bare-hand interaction remains the fallback.

const CASE_ID := "contracts.pico_interaction_parity"
const OPERATOR_INTERACTION_PATH := "res://scripts/interaction/operator_interaction.gd"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var source := FileAccess.get_file_as_string(OPERATOR_INTERACTION_PATH)
	t.is_false(source.is_empty(), "operator interaction source must be readable")

	var detect_start := source.find("func _detect_mode()")
	var detect_end := source.find("func _controller_input_detected()", detect_start)
	t.is_true(detect_start >= 0 and detect_end > detect_start,
		"automatic interaction detector must remain available")
	if detect_start < 0 or detect_end <= detect_start:
		return

	var detector := source.substr(detect_start, detect_end - detect_start)
	var controller_profile := detector.find("_tracker_profile_is_controller")
	var hand_profile := detector.find("_tracker_profile_is_hand")
	var controller_tracking := detector.find("if controller_tracking")
	var hand_gesture := detector.find("_hand_pinch_gesture_active")
	t.is_true(controller_profile >= 0 and hand_profile > controller_profile,
		"controller profiles must take priority over bare-hand profiles")
	t.is_true(controller_tracking >= 0 and hand_gesture > controller_tracking,
		"tracked controllers must take priority over hand gestures")
