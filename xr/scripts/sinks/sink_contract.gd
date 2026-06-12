class_name SensorSink
extends RefCounted
## v2 sinks (WP5): base contract for sensor-data consumers.
##
## Sinks consume canonical SensorFrames (contracts/sensor/sensor_frame.gd)
## and never pull data from platform plugins directly. Each concrete sink
## declares the frame types it accepts, its lifecycle (start/stop), and its
## quality-of-service policy (ordering, durability, drop policy).
##
## Dependency rule: sinks/ must never branch on device names or reference
## vendor singleton names — plugin objects are injected by the composition
## root via the platform layer.


## Frame-type ids (SensorFrameType.*) this sink consumes. The fanout
## (StreamBinding) only routes matching frames.
func accepted_frame_types() -> Array:
	return []


func accepts(frame_type: int) -> bool:
	return frame_type in accepted_frame_types()


## Consume one frame. Return value semantics are sink-specific: writers
## return bool for "accepted/written" where the legacy writer surface did,
## or null for void writes (samplers only bool() the values that were
## bool-typed pre-refactor).
func on_frame(_frame: SensorFrame) -> Variant:
	return null


## Open the sink for a session. `options` is the effective capture-options
## dictionary (CaptureOptions.to_dict() compatible).
func start(_options: Dictionary) -> bool:
	return true


## Close the sink. Result includes a `final_path` when the sink produced a
## durable artifact.
func stop() -> Dictionary:
	return {}


func health() -> Dictionary:
	return {}


## QoS declaration: {ordering, durability, drop_policy, ...}.
func policy() -> Dictionary:
	return {}
