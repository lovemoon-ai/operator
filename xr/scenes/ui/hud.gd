extends Node3D
## In-VR HUD overlay showing connection state, FPS, tracking mode, and platform.

@onready var _status_label: Label = $SubViewport/Panel/VBoxContainer/StatusLabel
@onready var _fps_label: Label = $SubViewport/Panel/VBoxContainer/FPSLabel
@onready var _tracking_label: Label = $SubViewport/Panel/VBoxContainer/TrackingLabel
@onready var _platform_label: Label = $SubViewport/Panel/VBoxContainer/PlatformLabel

## FPS calculation
var _frame_count: int = 0
var _fps_timer: float = 0.0
var _current_fps: float = 0.0

## Status text
var _status_text: String = "Initializing..."
## Platform name
var _platform_text: String = "Detecting..."
## Tracking mode
var _tracking_text: String = "Unknown"


func _process(delta: float) -> void:
	# Update FPS counter
	_frame_count += 1
	_fps_timer += delta
	if _fps_timer >= 1.0:
		_current_fps = _frame_count / _fps_timer
		_frame_count = 0
		_fps_timer = 0.0

		if _fps_label:
			_fps_label.text = "FPS: %.0f" % _current_fps

	# Update other labels (less frequently)
	if _fps_timer < 0.1:  # Update on first frame of each second
		if _status_label:
			_status_label.text = _status_text
		if _platform_label:
			_platform_label.text = "Platform: %s" % _platform_text
		if _tracking_label:
			_tracking_label.text = "Tracking: %s" % _tracking_text


## Set the main status text.
func set_status(text: String) -> void:
	_status_text = text
	if _status_label:
		_status_label.text = text


## Set the platform name.
func set_platform(platform: String) -> void:
	_platform_text = platform
	if _platform_label:
		_platform_label.text = "Platform: %s" % platform


## Set the tracking mode description.
func set_tracking_mode(mode: String) -> void:
	_tracking_text = mode
	if _tracking_label:
		_tracking_label.text = "Tracking: %s" % mode


## Get current FPS.
func get_fps() -> float:
	return _current_fps
