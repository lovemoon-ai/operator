extends RefCounted
class_name SettingsConfigStore


static func load(path: String, section: String, defaults: Dictionary, loaded_key: String = "") -> Dictionary:
	var out := defaults.duplicate(true)
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if not loaded_key.is_empty():
		out[loaded_key] = err == OK
	if err != OK:
		return out

	for key in defaults.keys():
		var default_value: Variant = defaults[key]
		out[key] = _coerce_value(cfg.get_value(section, key, default_value), default_value)
	return out


static func save(path: String, section: String, defaults: Dictionary, options: Dictionary, log_tag: String = "Settings") -> int:
	var cfg := ConfigFile.new()
	for key in defaults.keys():
		cfg.set_value(section, key, options.get(key, defaults[key]))
	var err := cfg.save(path)
	if err != OK:
		push_warning("[%s] Failed to save %s: error %d" % [log_tag, path, err])
	return err


static func _coerce_value(value: Variant, default_value: Variant) -> Variant:
	match typeof(default_value):
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_STRING:
			return str(value)
		_:
			return value
