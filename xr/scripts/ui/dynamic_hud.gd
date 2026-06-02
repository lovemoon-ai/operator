class_name DynamicHud
extends Control
## Auto-generates HUD elements from the device's telemetry schema.
## Shows device name, type, connection status, FPS, and any telemetry
## values defined in the DeviceDescriptor's telemetry_schema.

var _telemetry_labels: Dictionary = {}
var _warn_thresholds: Dictionary = {}
var _device_name_label: Label
var _device_type_label: Label
var _status_label: Label
var _fps_label: Label
var _container: VBoxContainer


func _ready():
	_container = VBoxContainer.new()
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_container)

	_device_name_label = Label.new()
	_device_name_label.add_theme_font_size_override("font_size", 18)
	_container.add_child(_device_name_label)

	_device_type_label = Label.new()
	_device_type_label.add_theme_font_size_override("font_size", 14)
	_container.add_child(_device_type_label)

	_status_label = Label.new()
	_container.add_child(_status_label)

	_fps_label = Label.new()
	_container.add_child(_fps_label)

	# Separator
	var sep = HSeparator.new()
	_container.add_child(sep)


func configure_for_device(descriptor: Dictionary):
	# Clear old telemetry labels
	for key in _telemetry_labels:
		_telemetry_labels[key].queue_free()
	_telemetry_labels.clear()
	_warn_thresholds.clear()

	var device_info = descriptor.get("device", {})
	_device_name_label.text = device_info.get("name", "Unknown Device")
	_device_type_label.text = "Type: %s" % device_info.get("type", "unknown")

	var schema = descriptor.get("telemetry_schema", {})
	var values = schema.get("values", [])
	for val_def in values:
		var tname: String = val_def["name"]
		var display: String = val_def.get("display", tname)
		var unit: String = val_def.get("unit", "")

		var label = Label.new()
		label.text = "%s: -- %s" % [display, unit]
		_container.add_child(label)
		_telemetry_labels[tname] = label

		if val_def.has("warn_below"):
			_warn_thresholds[tname] = val_def["warn_below"]


func update_telemetry(telemetry: Dictionary):
	var values = telemetry.get("values", {})
	for tname in values:
		if _telemetry_labels.has(tname):
			var label: Label = _telemetry_labels[tname]
			var val = values[tname]
			# Find display name from label text prefix
			var prefix = label.text.split(":")[0]
			label.text = "%s: %s" % [prefix, str(val)]

			# Warn highlighting
			if _warn_thresholds.has(tname):
				var threshold = _warn_thresholds[tname]
				if val is float and val < threshold:
					label.add_theme_color_override("font_color", Color.RED)
				else:
					label.remove_theme_color_override("font_color")


func update_status(connected: bool, fps: float):
	_status_label.text = "Status: %s" % ("Connected" if connected else "Disconnected")
	_status_label.add_theme_color_override("font_color", Color.GREEN if connected else Color.RED)
	_fps_label.text = "FPS: %.0f" % fps


func clear():
	for key in _telemetry_labels:
		_telemetry_labels[key].queue_free()
	_telemetry_labels.clear()
	_device_name_label.text = ""
	_device_type_label.text = ""
