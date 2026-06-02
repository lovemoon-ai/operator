extends Control
## Tiny face-locked button that re-opens the settings panel.
## Just emits `pressed` when the user clicks the gear; main.gd handles
## the panel visibility.

signal pressed

@onready var _button: Button = $Button


func _ready() -> void:
	_button.pressed.connect(_on_pressed)


func _on_pressed() -> void:
	pressed.emit()
