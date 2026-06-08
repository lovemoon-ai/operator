class_name MjDeviceCapabilityProfile
extends RefCounted


static func collect() -> Dictionary:
	var os_name := OS.get_name()
	var model := OS.get_model_name()
	var processor := OS.get_processor_name()
	return {
		"os": os_name,
		"model": model,
		"processor": processor,
		"processor_count": OS.get_processor_count(),
		"features": OS.get_cmdline_args(),
		"is_android": os_name == "Android",
		"is_pico_hint": model.to_lower().contains("pico"),
		"is_quest_hint": model.to_lower().contains("quest") or model.to_lower().contains("oculus") or model.to_lower().contains("meta"),
	}
