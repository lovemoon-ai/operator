class_name TrackingStatusText
extends RefCounted

static func key(phase: String) -> String:
	match phase:
		"unavailable": return "UI_PICO_CALIBRATION_UNAVAILABLE"
		"calibrating": return "UI_PICO_CALIBRATION_IN_PROGRESS"
		"confirming": return "UI_PICO_CALIBRATION_UNCONFIRMED"
		"confirmation_waiting_tracking": return "UI_TRACKING_CONFIRM_WAITING"
		"ready": return "UI_PICO_CALIBRATION_READY"
		"limited": return "UI_PICO_CALIBRATION_LIMITED"
		"waiting_body": return "UI_PICO_CALIBRATION_WAIT_BODY"
		"motion_setup": return "UI_PICO_CALIBRATION_WAIT_MOTION"
		"mode_conflict": return "UI_TRACKING_MODE_CONFLICT"
	return "UI_PICO_CALIBRATION_REQUIRED"
