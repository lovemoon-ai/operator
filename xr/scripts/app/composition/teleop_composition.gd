class_name TeleopComposition
extends RefCounted
## v2 app/composition (WP6): composition root for the teleop mode's
## command-emission stack. Builds the scene-owned CommandSender Node and
## wraps it in RobotControlSink (latest-only, 72 Hz default — all wire
## formats live in CommandSender/ControlMode unchanged).
##
## Session / TcpHandler / video handlers stay wired by the scene
## (scenes/main.gd): they are transport plumbing with scene-tree lifecycle,
## not sensor-frame composition.
##
## Robot-constraint composition gate (for future use by the constraint
## overlay): the module composes only when its feature flag is enabled AND
## the platform reports body tracking; otherwise it is degraded/absent —
## never a crash.

## Builds the CommandSender (added as a child of `parent`) and the
## RobotControlSink wrapping it.
## Returns {command_sender, robot_control_sink}.
static func build(parent: Node) -> Dictionary:
	var command_sender: Node = CommandSender.new()
	command_sender.name = "CommandSender"
	parent.add_child(command_sender)
	var sink := RobotControlSink.new()
	sink.attach(command_sender)
	return {
		"command_sender": command_sender,
		"robot_control_sink": sink,
	}


## Feature × capability gate for the optional robot-constraint module.
static func robot_constraint_available(features: FeatureSet, platform: PlatformRegistry) -> bool:
	if features == null or platform == null:
		return false
	return features.enabled(OperatorFeature.ROBOT_CONSTRAINT) \
		and platform.has_capability(SensorCapability.BODY_TRACKING)
