extends Control
## Tiny face-locked button that re-opens the settings panel.
## Just emits `pressed` when the user clicks the gear; the active mode
## controller handles the panel visibility.

signal pressed

@onready var _button: Button = $Button

var _feedback_input_mode := "controllers"
var _feedback_controller: XRController3D


func _ready() -> void:
	var icon := _load_svg_icon("settings")
	if icon != null:
		_button.icon = icon
		_button.expand_icon = true
		_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_button.text = ""
	_button.pressed.connect(_on_pressed)
	_button.mouse_entered.connect(func() -> void: _play_ui_sound("hover", -5.0))


func _on_pressed() -> void:
	_play_ui_sound("click")
	pressed.emit()


func set_feedback_input_mode(mode: String, controller: XRController3D = null) -> void:
	_feedback_input_mode = mode
	_feedback_controller = controller


func _play_ui_sound(action: String, volume_db: float = 0.0) -> void:
	if _feedback_input_mode == "hands":
		var sound_bus := _get_ui_sound_bus()
		if sound_bus != null and sound_bus.has_method("play"):
			sound_bus.call("play", action, volume_db)
	elif _feedback_input_mode == "controllers":
		var haptics := _get_haptics_bus()
		var use_haptics := _feedback_controller != null
		if haptics != null and haptics.has_method("should_use_controller_feedback"):
			use_haptics = bool(haptics.call("should_use_controller_feedback", _feedback_controller))
		if use_haptics and haptics != null and haptics.has_method("fire_ui_event"):
			haptics.call("fire_ui_event", action, _feedback_controller)
		else:
			var sound_bus := _get_ui_sound_bus()
			if sound_bus != null and sound_bus.has_method("play"):
				sound_bus.call("play", action, volume_db)


func _get_ui_sound_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("UISoundBus")


func _get_haptics_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Haptics")


func _load_svg_icon(icon_name: String) -> Texture2D:
	var path := "res://assets/icons/%s.svg" % icon_name
	if not FileAccess.file_exists(path):
		return null
	var svg := FileAccess.get_file_as_string(path)
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)
