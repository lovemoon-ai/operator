class_name SpatialMP4Writer
extends RefCounted
# Typed GDScript facade over the SpatialMp4MuxerPlugin Android singleton.
# Host projects use this instead of Engine.get_singleton(...).call(...) so
# that:
#   * the @UsedByGodot method names live in one place (rename-once-here);
#   * the muxer's `camera_error` signal is forwarded as a typed Godot signal;
#   * the contract version is exposed up front for an early version check.
#
# Construction:
#     var writer := SpatialMP4Writer.new()
#     if not writer.bind():
#         push_error("SpatialMp4MuxerPlugin not installed; add the addon AAR")
#         return
#     # Hand to the provider so RGB packets flow through SpatialDataSink:
#     XRCaptureProvider.singleton().bind_muxer(writer.singleton())
#
# Lifecycle: muxer ownership of the writer handle lives in Kotlin -- this
# class only forwards calls. Call finish() at end of session; the file path
# returned is the final, renamed .mp4.

signal error(message: String)

# Bumped in lock-step with com.spatialmp4.contract.CONTRACT_VERSION. v5 embeds
# raw-container replay metadata such as operator_static and rgb_frame_index in
# MP4 so the archive remains self-contained.
const EXPECTED_CONTRACT_VERSION := 5

var _plugin: Object


func bind() -> bool:
	# Resolve the Engine singleton and connect its `camera_error` signal so
	# the host can hook a single error path. Safe to call multiple times.
	if _plugin != null:
		return true
	if not Engine.has_singleton("SpatialMp4MuxerPlugin"):
		return false
	_plugin = Engine.get_singleton("SpatialMp4MuxerPlugin")
	if _plugin.has_signal("camera_error"):
		_plugin.connect("camera_error", Callable(self, "_relay_error"))
	return true


func singleton() -> Object:
	# Exposed for XRCaptureProvider.bind_muxer(), which needs the raw Object
	# reference so its Kotlin bindMuxer(Object) can cast to SpatialDataSink.
	return _plugin


func contract_version() -> int:
	if _plugin == null:
		return 0
	return int(_plugin.call("getMuxerContractVersion"))


# ---- depth -----------------------------------------------------------------

func write_depth_frame(
	timestamp_ns: int,
	width: int,
	height: int,
	payload_u16_mm: PackedByteArray,
	fov_left: float,
	fov_right: float,
	fov_top: float,
	fov_bottom: float
) -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call(
		"writeDepthFrame",
		timestamp_ns, width, height, payload_u16_mm,
		fov_left, fov_right, fov_top, fov_bottom
	))


# ---- pose / hand / controller input ---------------------------------------

func write_head_pose(timestamp_ns: int, transform: Transform3D, tracking_valid: bool) -> bool:
	if _plugin == null:
		return false
	var q := transform.basis.get_rotation_quaternion()
	var p := transform.origin
	return bool(_plugin.call(
		"writeHeadPose",
		timestamp_ns, p.x, p.y, p.z, q.x, q.y, q.z, q.w, tracking_valid
	))


func write_controller_pose(source: String, timestamp_ns: int, transform: Transform3D, tracking_valid: bool) -> bool:
	if _plugin == null:
		return false
	var q := transform.basis.get_rotation_quaternion()
	var p := transform.origin
	return bool(_plugin.call(
		"writeControllerPose",
		source, timestamp_ns, p.x, p.y, p.z, q.x, q.y, q.z, q.w, tracking_valid
	))


func write_hand_joints_payload(hand: String, timestamp_ns: int, payload: PackedByteArray) -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call("writeHandJointsPayload", hand, timestamp_ns, payload))


func write_controller_input(
	controller: String,
	timestamp_ns: int,
	packet_type: int,
	available_mask: int,
	pressed_mask: int,
	touched_mask: int,
	changed_mask: int,
	trigger_value: float,
	grip_value: float,
	thumbstick_x: float,
	thumbstick_y: float,
	trackpad_x: float,
	trackpad_y: float
) -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.call(
		"writeControllerInput",
		controller, timestamp_ns, packet_type,
		available_mask, pressed_mask, touched_mask, changed_mask,
		trigger_value, grip_value,
		thumbstick_x, thumbstick_y, trackpad_x, trackpad_y
	))


# ---- session lifecycle / metrics ------------------------------------------

func finish() -> String:
	# Drain + finalize the native writer. Returns the absolute path of the
	# final .mp4 (after the partial -> final rename), or "" on failure.
	if _plugin == null:
		return ""
	return str(_plugin.call("finishSpatialMp4"))


func pop_metrics_json() -> String:
	# JSON object with native_rgb_writes / native_depth_writes / etc., each
	# counter atomically reset to 0 on read. Pair with the provider's
	# popMetricsJson() to get full per-second telemetry.
	if _plugin == null:
		return "{}"
	return str(_plugin.call("popMuxerMetricsJson"))


func _relay_error(message: String) -> void:
	emit_signal("error", message)
