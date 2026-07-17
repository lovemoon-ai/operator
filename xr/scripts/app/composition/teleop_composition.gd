class_name TeleopComposition
extends RefCounted
## v2 app/composition (WP6): composition root for the teleop mode's
## command-emission stack. Builds the scene-owned CommandSender Node and
## wraps it in RobotControlSink (latest-only, 72 Hz default — all wire
## formats live in CommandSender/ControlMode unchanged).
##
## Session / TcpHandler / video handlers stay wired by the teleop mode
## controller: they are transport plumbing with scene-tree lifecycle,
## not sensor-frame composition.
##
## Robot-constraint composition gate (for future use by the constraint
## overlay): the module composes only when its feature flag is enabled AND
## the platform reports body tracking; otherwise it is degraded/absent —
## never a crash.

## Builds the CommandSender (added as a child of `parent`) and the
## RobotControlSink wrapping it.  When SINK_ISAAC_TELEOP is enabled, it also
## composes PoseSampler/IsaacTeleopBodySampler -> StreamBinding -> IsaacTeleopSink.
## The optional sink is not started here; the mode supplies the connected
## peer host at connection time.
static func build(
	parent: Node,
	features: FeatureSet = null,
	sensors: Dictionary = {}
) -> Dictionary:
	var command_sender: Node = CommandSender.new()
	command_sender.name = "CommandSender"
	parent.add_child(command_sender)
	var sink := RobotControlSink.new()
	sink.attach(command_sender)
	var result := {
		"command_sender": command_sender,
		"robot_control_sink": sink,
	}
	if features == null or not features.enabled(OperatorFeature.SINK_ISAAC_TELEOP):
		return result

	var isaac_sink := IsaacTeleopSink.new()
	var binding := StreamBinding.new()
	binding.add_sink(isaac_sink)
	var pose_sampler := PoseSampler.new()
	pose_sampler.name = "IsaacTeleopPoseSampler"
	parent.add_child(pose_sampler)
	pose_sampler.configure(
		null,
		sensors.get("camera"),
		sensors.get("left_controller"),
		sensors.get("right_controller"),
		null,
		sensors.get("platform"))
	pose_sampler.set_frame_sink(binding)
	pose_sampler.set_stream_intervals(0, 0)
	pose_sampler.set_capture_options({
		"record_head_pose": true,
		"record_controller_pose": true,
		"record_controller_input": true,
		"record_hand_data": true,
	})

	var body_sampler := IsaacTeleopBodySampler.new()
	body_sampler.name = "IsaacTeleopBodySampler"
	parent.add_child(body_sampler)
	body_sampler.configure(pose_sampler, sensors.get("pico_openxr_bridge"))
	body_sampler.set_frame_sink(binding)
	result["isaac_teleop_sink"] = isaac_sink
	result["isaac_teleop_binding"] = binding
	result["isaac_teleop_pose_sampler"] = pose_sampler
	result["isaac_teleop_body_sampler"] = body_sampler
	return result


## Feature × capability gate for the optional robot-constraint module.
static func robot_constraint_available(features: FeatureSet, platform: PlatformRegistry) -> bool:
	if features == null or platform == null:
		return false
	return features.enabled(OperatorFeature.ROBOT_CONSTRAINT) \
		and platform.has_capability(SensorCapability.BODY_TRACKING)
