class_name HandSource
extends Node
## Capability layer (components/sources): hand joints. Hands never flow
## through the GDScript StreamBinding: the hand_capture GDExtension writes them
## natively. This component wires those native writers to whichever sink
## plugins the composition mounted (SpatialMP4 muxer and/or live push) and owns
## the independent 60 Hz OpenXR hand recorder used for local recordings.
## Timestamping stays in the native code (wire-protocol.md "Headset timebase").

const OPENXR_HAND_CAPTURE_SINGLETON := &"NativeOpenXRHandCapture"

var _pose_sampler: Node
var _body_motion_sampler: Node
var _recorder: Object = null
var _recording := false


func configure(pose_sampler: Node, body_motion_sampler: Node) -> void:
	_pose_sampler = pose_sampler
	_body_motion_sampler = body_motion_sampler


## Hand joints, body joints and motion trackers are written by the
## hand_capture GDExtension (C++): local recordings write MP4 metadata tracks
## through the muxer plugin; live sessions push hands via writeHandJointsJson on
## the live push plugin (rate-limited in C++ to the legacy 30 Hz wire cadence;
## body/motion have no live streams). Idempotent — call again when a plugin
## singleton binds late or the mounted sinks change.
func enable_native_writers(muxer_target: Object, live_target: Object) -> void:
	if _pose_sampler == null:
		return
	if _recorder == null and Engine.has_singleton(OPENXR_HAND_CAPTURE_SINGLETON):
		_recorder = Engine.get_singleton(OPENXR_HAND_CAPTURE_SINGLETON)
	if muxer_target == null and live_target == null:
		return
	var had_native := bool(_pose_sampler.has_native_hand_capture())
	if bool(_pose_sampler.enable_native_hand_capture(muxer_target, live_target)) and not had_native:
		print("Native hand capture enabled (hand_capture GDExtension, full XR frame rate)")
	if muxer_target != null and _body_motion_sampler != null \
			and not bool(_body_motion_sampler.has_native_writer()) \
			and bool(_body_motion_sampler.enable_native_writer(muxer_target)):
		print("Native body/motion capture writer enabled (hand_capture GDExtension)")


## Starts the independent 60 Hz OpenXR hand recorder for a local recording.
## A no-op (success) when hands are not recorded locally.
func start_recording(record_locally: bool, xr_time_to_godot_ticks_offset_ns: int) -> bool:
	if not record_locally:
		return true
	if _recorder == null:
		push_error("NativeOpenXRHandCapture singleton is unavailable")
		return false
	_recording = bool(_recorder.call("start_recording", xr_time_to_godot_ticks_offset_ns))
	if not _recording:
		push_error("Native OpenXR hand recorder start failed: %s" % str(
			_recorder.call("get_last_error")
		))
		return false
	if _pose_sampler != null and _pose_sampler.has_method("set_native_hand_muxer_writes_enabled"):
		_pose_sampler.set_native_hand_muxer_writes_enabled(false)
	print("Native OpenXR hand recorder started at an independent 60 Hz (Quest/PICO)")
	return true


## Native camera/hand workers hold OpenXR sessions and feed the active native
## writer; join them before the provider finalizes that writer.
func stop_recording() -> void:
	var was_started := _recording
	_recording = false
	if was_started and _recorder != null:
		_recorder.call("stop_recording")
	if _pose_sampler != null and _pose_sampler.has_method("set_native_hand_muxer_writes_enabled"):
		_pose_sampler.set_native_hand_muxer_writes_enabled(true)


func reset_session() -> void:
	_recording = false


## "" while the recorder is healthy (or not running); otherwise why it stopped.
func recording_error() -> String:
	if not _recording or bool(_recorder.call("is_recording")):
		return ""
	var hand_error := str(_recorder.call("get_last_error"))
	stop_recording()
	return "Native 60 Hz hand recorder stopped unexpectedly: %s" % hand_error


func pop_metrics() -> Dictionary:
	if _recorder == null:
		return {}
	var hand_metrics: Variant = _recorder.call("pop_metrics")
	if typeof(hand_metrics) == TYPE_DICTIONARY:
		return hand_metrics
	return {}
