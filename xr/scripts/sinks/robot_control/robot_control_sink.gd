class_name RobotControlSink
extends SensorSink
## v2 sinks/robot_control (WP5): teleop command emission behind the
## SensorSink contract. Wraps the existing CommandSender (v2 DeviceCommand
## JSON) and optional PoseSender (v1 Tracking JSON) by composition — the
## wire formats, 72 Hz default rate, enable-grace and logcat prints all stay
## inside those classes unchanged.
##
## QoS: latest-only. The senders pull the freshest tracking state from
## TrackingProvider on their own _physics_process tick, which is exactly the
## legacy fast path; on_frame keeps a latest-frame cache so future pure
## frame-driven compositions (WP6/WP7 fakes) can read the same surface.

const DEFAULT_RATE_HZ := 72.0

var _command_sender: Node = null
var _pose_sender: Node = null
# Latest-only frame cache keyed by SensorFrameType id.
var _latest_frames: Dictionary = {}


## Attach the scene-owned senders (created/added by the composition root —
## the sink does not own scene-tree lifecycle).
func attach(command_sender: Node, pose_sender: Node = null) -> void:
	_command_sender = command_sender
	_pose_sender = pose_sender


func command_sender() -> Node:
	return _command_sender


func pose_sender() -> Node:
	return _pose_sender


## v2 path: configure ControlMode from the robot's DeviceDescriptor.
func configure_for_device(descriptor: Dictionary) -> void:
	if _command_sender != null:
		_command_sender.configure_for_device(descriptor)


func set_sending(enabled: bool) -> void:
	if _command_sender != null:
		_command_sender.set_sending(enabled)
	if _pose_sender != null and _pose_sender.has_method("set_sending"):
		_pose_sender.set_sending(enabled)


func is_sending() -> bool:
	return _command_sender != null and _command_sender.is_sending()


func accepted_frame_types() -> Array:
	return [
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.INPUT_EVENT,
		SensorFrameType.HAND,
	]


## Latest-only drop policy: each new frame of a type replaces the previous.
func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	_latest_frames[frame.frame_type] = frame
	return true


func latest_frame(frame_type: int) -> SensorFrame:
	return _latest_frames.get(frame_type)


func stop() -> Dictionary:
	set_sending(false)
	_latest_frames.clear()
	return {}


func policy() -> Dictionary:
	return {
		"ordering": "latest_only",
		"durability": "none",
		"drop_policy": "replace",
		"rate_hz": DEFAULT_RATE_HZ,
	}


func health() -> Dictionary:
	return {
		"command_sender_bound": _command_sender != null,
		"sending": is_sending(),
	}
