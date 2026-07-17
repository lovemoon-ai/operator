class_name StreamBinding
extends RefCounted
## v2 core/pipeline (WP5): minimal source->sinks fanout. Routes each
## canonical SensorFrame to every attached SensorSink whose
## accepted_frame_types() match. Replaces the WP4 FrameWriterShim as the
## samplers' frame sink.
##
## Return-value contract (samplers bool() some results, so legacy writer
## semantics must survive the split): the fanout returns the boolean OR of
## all non-null sink results, or null when no routed sink voted. Example:
## - controller input: only SpatialMp4Sink votes -> muxer bool (legacy).
##
## Hands, body joints and motion trackers do not flow through this fanout:
## the hand_capture GDExtension writes them natively (see pose_sampler /
## body_motion_sampler).
##
## Full pipeline policies (backpressure, threading) are out of scope here.
##
## Dependency rule: core/ must stay below sinks/, so sinks are duck-typed
## Objects honoring the SensorSink contract (accepts/on_frame) rather than
## a typed reference to the sinks/ base class.

var _sinks: Array = []
# Accepted-type set per sink, parallel to _sinks. Cached once at add_sink:
# every sink's accepted_frame_types() allocates a fresh Array literal per
# call, so querying it per frame was pure allocation churn at up to 90 Hz
# across multiple streams and sinks.
var _accepted_sets: Array = []


func add_sink(sink: Object) -> void:
	if sink == null or _sinks.has(sink):
		return
	_sinks.append(sink)
	var accepted := {}
	for frame_type in sink.accepted_frame_types():
		accepted[int(frame_type)] = true
	_accepted_sets.append(accepted)


func sinks() -> Array:
	return _sinks


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	var result: Variant = null
	for index in _sinks.size():
		if not (_accepted_sets[index] as Dictionary).has(frame.frame_type):
			continue
		var sink_result: Variant = (_sinks[index] as Object).on_frame(frame)
		if sink_result == null:
			continue
		result = bool(sink_result) or (result != null and bool(result))
	return result
