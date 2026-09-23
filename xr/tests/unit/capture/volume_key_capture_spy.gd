extends "res://scripts/app/modes/capture_app_base.gd"

var start_requests := 0
var stop_requests := 0


func start_capture() -> void:
	start_requests += 1


func stop_capture() -> void:
	stop_requests += 1
