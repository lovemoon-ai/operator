class_name FakeRobotControlSink
extends SensorSink
## v2 test harness (WP7): teleop sink double. Stores emitted robot command
## frames (latest-only per the production RobotControlSink policy) plus a
## history for assertions.

var commands: Array = []  # Array[Dictionary] (emitted DeviceCommand dicts)
var latest_command: Dictionary = {}
var _latest_frames: Dictionary = {}  # frame_type -> SensorFrame
var sending := false


func accepted_frame_types() -> Array:
	return [
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.INPUT_EVENT,
		SensorFrameType.HAND,
	]


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	_latest_frames[frame.frame_type] = frame
	return true


func latest_frame(frame_type: int) -> SensorFrame:
	return _latest_frames.get(frame_type)


## Automation port for command emission (the production sink delegates to
## CommandSender; tests push the mapped command dict here).
func emit_command(command: Dictionary) -> void:
	latest_command = command
	commands.append(command)


func set_sending(enabled: bool) -> void:
	sending = enabled


func is_sending() -> bool:
	return sending


func stop() -> Dictionary:
	sending = false
	_latest_frames.clear()
	return {"commands_emitted": commands.size()}


func policy() -> Dictionary:
	return {"ordering": "latest_only", "durability": "none", "drop_policy": "replace"}


func health() -> Dictionary:
	return {"commands_emitted": commands.size(), "sending": sending}
