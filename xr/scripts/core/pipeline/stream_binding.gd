class_name StreamBinding
extends RefCounted
## v2 core/pipeline (WP5): minimal source->sinks fanout. Routes each
## canonical SensorFrame to every attached SensorSink whose
## accepted_frame_types() match. Replaces the WP4 FrameWriterShim as the
## samplers' frame sink.
##
## Return-value contract (samplers bool() some results, so legacy writer
## semantics must survive the split): the fanout returns the boolean OR of
## all non-null sink results, or null when no routed sink voted. Examples:
## - controller input: only SpatialMp4Sink votes -> muxer bool (legacy).
## - body joints: SpatialMp4Sink (muxer wrote) OR JsonlSidecarSink (sidecar
##   wrote) == legacy write_body_joints `wrote` OR.
## - motion tracker: only JsonlSidecarSink votes -> file-open bool (legacy).
##
## Full pipeline policies (backpressure, threading) are out of scope here.
##
## Dependency rule: core/ must stay below sinks/, so sinks are duck-typed
## Objects honoring the SensorSink contract (accepts/on_frame) rather than
## a typed reference to the sinks/ base class.

var _sinks: Array = []


func add_sink(sink: Object) -> void:
	if sink != null and not _sinks.has(sink):
		_sinks.append(sink)


func sinks() -> Array:
	return _sinks


## Legacy guard mirrored from FrameWriterShim: true when any attached sink
## exposes the motion-tracker event surface (spool pipeline yes, live no).
func supports_motion_tracker_events() -> bool:
	for sink in _sinks:
		if sink.has_method("supports_motion_tracker_events") and sink.supports_motion_tracker_events():
			return true
	return false


func on_frame(frame: SensorFrame) -> Variant:
	if frame == null:
		return null
	var result: Variant = null
	for sink in _sinks:
		if not sink.accepts(frame.frame_type):
			continue
		var sink_result: Variant = sink.on_frame(frame)
		if sink_result == null:
			continue
		result = bool(sink_result) or (result != null and bool(result))
	return result
