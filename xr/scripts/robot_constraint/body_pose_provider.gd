class_name BodyPoseProvider
extends Node
## Selects an active body adapter (Godot/Pico/Fallback), samples it each
## physics tick, and exposes the resolved canonical frame as the
## ``canonical_frame_ready`` signal.
##
## Debug overlays and recording consumers can tap into
## ``canonical_frame_ready`` directly.

const CanonicalJointsCls = preload("res://scripts/robot_constraint/canonical_joints.gd")
const CanonicalResolverCls = preload("res://scripts/robot_constraint/canonical_resolver.gd")
const GodotBodyAdapterCls = preload("res://scripts/robot_constraint/godot_body_adapter.gd")
const PicoBodyAdapterCls = preload("res://scripts/robot_constraint/pico_body_adapter.gd")
const FallbackBodyAdapterCls = preload("res://scripts/robot_constraint/fallback_body_adapter.gd")

const BODY_TRACKER_NAME := &"/user/body_tracker"

signal canonical_frame_ready(frame: Dictionary)
## Emitted with the *raw* vendor frame (one of the per-vendor schemas:
## ``operator.raw_vendor_pose.v1``, source = ``pico_bd_body_tracking`` or
## ``meta_fb_body_tracking``). Lets ``SessionSpoolWriter`` archive the
## upstream-of-canonical bytes so an offline replay can rebuild canonical
## body-pose frames from disk.
##
## Quest path is degenerate today: Meta's tracker doesn't expose a stable
## vendor payload separate from the OpenXR-converted canonical, so we
## synthesize the raw frame from the same XRBodyTracker snapshot we used
## to build canonical. Pico has a distinct vendor proto from the bd_body
## extension, so the raw frame there is genuinely upstream.
signal raw_vendor_pose_ready(frame: Dictionary)

enum SourceMode {
	AUTO,
	GODOT_ONLY,
	PICO_ONLY,
	FALLBACK_ONLY,
	OFF,
}

@export var source_mode: SourceMode = SourceMode.AUTO
@export var sample_rate_hz: float = 60.0

var tracking_provider: Object  # TrackingProvider
var pico_openxr_bridge: Object

var _godot_adapter: GodotBodyAdapter = GodotBodyAdapter.new()
var _pico_adapter: PicoBodyAdapter = PicoBodyAdapter.new()
var _fallback_adapter: FallbackBodyAdapter = FallbackBodyAdapter.new()

var _last_frame: Dictionary = {}
var _time_since_last_sample: float = 0.0
var _enabled: bool = false
var _last_pico_diag_key := ""
var _last_pico_diag_usec := 0

const PICO_DIAG_REPRINT_USEC := 5_000_000
const PICO_BODY_STATUS_VALID := 1
const PICO_BODY_STATUS_LIMITED := 2
const PICO_MIN_BODY_SPAN_M := 0.05


func configure(p_tracking_provider: Object, p_pico_bridge: Object = null) -> void:
	tracking_provider = p_tracking_provider
	pico_openxr_bridge = p_pico_bridge


func set_enabled(value: bool) -> void:
	_enabled = value
	_time_since_last_sample = 0.0


func is_enabled() -> bool:
	return _enabled


func get_latest_frame() -> Dictionary:
	return _last_frame


func _physics_process(delta: float) -> void:
	if not _enabled:
		return
	if sample_rate_hz <= 0.0:
		return
	_time_since_last_sample += delta
	var interval := 1.0 / sample_rate_hz
	if _time_since_last_sample < interval:
		return
	_time_since_last_sample = 0.0
	var ts_ns := Time.get_ticks_usec() * 1000
	var partial_frames: Array = []
	match source_mode:
		SourceMode.OFF:
			return
		SourceMode.GODOT_ONLY:
			partial_frames.append(_sample_godot(ts_ns))
		SourceMode.PICO_ONLY:
			partial_frames.append(_sample_pico(ts_ns))
		SourceMode.FALLBACK_ONLY:
			partial_frames.append(_sample_fallback(ts_ns))
		SourceMode.AUTO:
			# Prefer the highest-quality body source available, but
			# always fall back to HMD+controllers so the resolver has at
			# least head+wrist+inferred-torso when the body tracker drops.
			var pico_frame := _sample_pico(ts_ns)
			if not pico_frame.is_empty():
				partial_frames.append(pico_frame)
			var godot_frame := _sample_godot(ts_ns)
			if not godot_frame.is_empty():
				partial_frames.append(godot_frame)
			var fallback_frame := _sample_fallback(ts_ns)
			if not fallback_frame.is_empty():
				partial_frames.append(fallback_frame)
	# Drop empty entries to avoid emitting an empty frame when all sources
	# are off.
	var non_empty: Array = []
	for f in partial_frames:
		if typeof(f) == TYPE_DICTIONARY and not f.is_empty():
			non_empty.append(f)
	if non_empty.is_empty():
		return
	var merged := CanonicalResolverCls.resolve(non_empty, ts_ns)
	_last_frame = merged
	canonical_frame_ready.emit(merged)


# -- sampling helpers ----------------------------------------------------


func _sample_godot(timestamp_ns: int) -> Dictionary:
	var tracker := XRServer.get_tracker(BODY_TRACKER_NAME)
	if tracker == null or not (tracker is XRBodyTracker):
		return {}
	# Emit the raw_vendor_pose frame BEFORE the canonical conversion so the
	# recorded raw stream is genuinely upstream. Schema-compliant per
	# ``raw_vendor_pose.v1.schema.json``.
	raw_vendor_pose_ready.emit(_build_raw_frame_from_godot(tracker as XRBodyTracker, timestamp_ns))
	return _godot_adapter.sample(tracker as XRBodyTracker, timestamp_ns)


func _sample_pico(timestamp_ns: int) -> Dictionary:
	if pico_openxr_bridge == null or not pico_openxr_bridge.has_method("sample_body_joints"):
		_log_pico_diag_once(
			"bridge_missing",
			"Pico body source unavailable: missing PicoOpenXRExtension.sample_body_joints"
		)
		return {}
	var status_method_ok := pico_openxr_bridge.has_method("get_status")
	if status_method_ok:
		var status: Variant = pico_openxr_bridge.call("get_status")
		if typeof(status) == TYPE_DICTIONARY:
			if not bool((status as Dictionary).get("bd_body_tracking_supported", false)):
				_log_pico_diag_once("unsupported", "Pico body source unsupported: %s" % JSON.stringify(status))
				return {}
	var body: Variant = pico_openxr_bridge.call("sample_body_joints")
	if typeof(body) != TYPE_DICTIONARY:
		_log_pico_diag_once(
			"sample_not_dict",
			"Pico body sample returned %s, expected Dictionary" % type_string(typeof(body))
		)
		return {}
	var body_dict := body as Dictionary
	var joints_v: Variant = body_dict.get("joints", [])
	var joint_count := (joints_v as Array).size() if typeof(joints_v) == TYPE_ARRAY else 0
	if joint_count <= 0:
		_log_pico_diag_once(_pico_diag_key(body_dict, "empty"),
			"Pico body sample has no joints: %s" % _pico_body_diag_summary(body_dict))
		return {}
	if _pico_bridge_has_body_tracking2() and not _pico_body_state_ready(body_dict):
		_log_pico_diag_once(_pico_diag_key(body_dict, "not_ready"),
			"Pico body state not ready; ignoring sample: %s"
			% _pico_body_diag_summary(body_dict))
		return {}
	var raw_span := _pico_raw_joint_span(body_dict)
	if raw_span >= 0.0 and raw_span < PICO_MIN_BODY_SPAN_M:
		_log_pico_diag_once(_pico_diag_key(body_dict, "collapsed"),
			"Pico body sample collapsed to one point; ignoring sample: %s"
			% _pico_body_diag_summary(body_dict))
		return {}
	# Pico's body_dict IS the vendor proto — joint indices, position +
	# rotation sub-dicts, flags. Translate it directly into the
	# raw_vendor_pose.v1 shape so an offline replay can drive the entire
	# pipeline from disk without the OpenXR runtime.
	raw_vendor_pose_ready.emit(_build_raw_frame_from_pico(body_dict, timestamp_ns))
	var frame := _pico_adapter.sample(body_dict, timestamp_ns)
	if frame.is_empty():
		_log_pico_diag_once(_pico_diag_key(body_dict, "invalid"),
			"Pico body sample produced no valid canonical joints: %s"
			% _pico_body_diag_summary(body_dict))
	else:
		_log_pico_diag_once(_pico_diag_key(body_dict, "online"),
			"Pico body source online: %s" % _pico_body_diag_summary(body_dict))
	return frame


func _log_pico_diag_once(key: String, message: String) -> void:
	var now := Time.get_ticks_usec()
	if key == _last_pico_diag_key and now - _last_pico_diag_usec < PICO_DIAG_REPRINT_USEC:
		return
	_last_pico_diag_key = key
	_last_pico_diag_usec = now
	print("[BodyPoseProvider] %s" % message)


func _pico_diag_key(body: Dictionary, prefix: String) -> String:
	return "%s:%s:%s:%s:%s" % [
		prefix,
		str(body.get("status", "")),
		str(body.get("message", "")),
		str(body.get("locate_result", "")),
		str(body.get("state_result", "")),
	]


func _pico_body_diag_summary(body: Dictionary) -> String:
	var joints_v: Variant = body.get("joints", [])
	var joint_count := (joints_v as Array).size() if typeof(joints_v) == TYPE_ARRAY else 0
	var status := _pico_body_status_name(int(body.get("status", 0)))
	var message := _pico_body_message_name(int(body.get("message", 0)))
	var span := _pico_raw_joint_span(body)
	var parts := [
		"active=%s" % str(body.get("active", false)),
		"supported=%s" % str(body.get("supported", false)),
		"status=%s(%d)" % [status, int(body.get("status", 0))],
		"message=%s(%d)" % [message, int(body.get("message", 0))],
		"joints=%d" % joint_count,
		"locate_result=%s" % str(body.get("locate_result", "")),
		"state_result=%s" % str(body.get("state_result", "")),
		"all_tracked=%s" % str(body.get("all_tracked", false)),
		"body_flags=%s" % str(body.get("body_flags", "")),
		"raw_span=%.4f" % span,
		"raw_sample=%s" % _pico_raw_joint_sample_summary(body),
		"bridge={%s}" % _pico_bridge_diag_summary(),
	]
	return " ".join(PackedStringArray(parts))


func _pico_body_state_ready(body: Dictionary) -> bool:
	var status := int(body.get("status", 0))
	return status == PICO_BODY_STATUS_VALID or status == PICO_BODY_STATUS_LIMITED


func _pico_bridge_has_body_tracking2() -> bool:
	if pico_openxr_bridge == null or not pico_openxr_bridge.has_method("get_status"):
		return false
	var raw: Variant = pico_openxr_bridge.call("get_status")
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	return bool((raw as Dictionary).get("pico_body_tracking2_extension", false))


func _pico_raw_joint_span(body: Dictionary) -> float:
	var joints_v: Variant = body.get("joints", [])
	if typeof(joints_v) != TYPE_ARRAY:
		return -1.0
	var have_bounds := false
	var bounds_min := Vector3.ZERO
	var bounds_max := Vector3.ZERO
	for entry_v in (joints_v as Array):
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var position := _pico_joint_position(entry_v as Dictionary)
		if position.is_empty():
			continue
		var p: Vector3 = position["value"]
		if have_bounds:
			bounds_min = bounds_min.min(p)
			bounds_max = bounds_max.max(p)
		else:
			bounds_min = p
			bounds_max = p
			have_bounds = true
	if not have_bounds:
		return -1.0
	return (bounds_max - bounds_min).length()


func _pico_raw_joint_sample_summary(body: Dictionary) -> String:
	var joints_v: Variant = body.get("joints", [])
	if typeof(joints_v) != TYPE_ARRAY:
		return "[]"
	var samples: Array = []
	for entry_v in (joints_v as Array):
		if samples.size() >= 3:
			break
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var entry := entry_v as Dictionary
		var position := _pico_joint_position(entry)
		var position_text := str(position.get("value", Vector3.ZERO)) if not position.is_empty() else "missing"
		samples.append("#%s:%s:%s" % [
			str(entry.get("joint", entry.get("source_joint", "?"))),
			type_string(typeof(entry.get("position", null))),
			position_text,
		])
	return "[" + ", ".join(PackedStringArray(samples)) + "]"


func _pico_joint_position(entry: Dictionary) -> Dictionary:
	var position := _vector3_from_variant(entry.get("position", null))
	if not position.is_empty():
		return position
	var transform_v: Variant = entry.get("transform", null)
	if typeof(transform_v) == TYPE_TRANSFORM3D:
		var transform: Transform3D = transform_v
		return {"value": transform.origin}
	return {}


func _vector3_from_variant(value: Variant) -> Dictionary:
	match typeof(value):
		TYPE_VECTOR3:
			return {"value": value}
		TYPE_DICTIONARY:
			var dict := value as Dictionary
			if dict.has("x") and dict.has("y") and dict.has("z"):
				return {"value": Vector3(float(dict["x"]), float(dict["y"]), float(dict["z"]))}
			if dict.has("p"):
				return _vector3_from_variant(dict["p"])
		TYPE_ARRAY:
			var arr := value as Array
			if arr.size() >= 3:
				return {"value": Vector3(float(arr[0]), float(arr[1]), float(arr[2]))}
		TYPE_PACKED_FLOAT32_ARRAY:
			var arr32: PackedFloat32Array = value
			if arr32.size() >= 3:
				return {"value": Vector3(float(arr32[0]), float(arr32[1]), float(arr32[2]))}
		TYPE_PACKED_FLOAT64_ARRAY:
			var arr64: PackedFloat64Array = value
			if arr64.size() >= 3:
				return {"value": Vector3(float(arr64[0]), float(arr64[1]), float(arr64[2]))}
	return {}


func _pico_bridge_diag_summary() -> String:
	if pico_openxr_bridge == null or not pico_openxr_bridge.has_method("get_status"):
		return "status_unavailable"
	var raw: Variant = pico_openxr_bridge.call("get_status")
	if typeof(raw) != TYPE_DICTIONARY:
		return "status_type=%s" % type_string(typeof(raw))
	var status := raw as Dictionary
	var parts := [
		"session=%s" % str(status.get("session_created", false)),
		"bd_ext=%s" % str(status.get("bd_body_tracking_extension", false)),
		"bd_supported=%s" % str(status.get("bd_body_tracking_supported", false)),
		"body_tracker=%s" % str(status.get("body_tracker_created", false)),
		"motion_ext=%s" % str(status.get("motion_tracking_extension", false)),
		"motion_trackers=%s" % str(status.get("motion_tracker_count", 0)),
		"motion_request_sent=%s" % str(status.get("motion_request_sent", false)),
		"last_create=%s" % str(status.get("last_body_create_result", "")),
		"last_state=%s" % str(status.get("last_body_state_result", "")),
		"last_locate=%s" % str(status.get("last_body_locate_result", "")),
		"last_motion_request=%s" % str(status.get("last_motion_request_result", "")),
	]
	return " ".join(PackedStringArray(parts))


func _pico_body_status_name(status: int) -> String:
	var name := "UNKNOWN"
	match status:
		0:
			name = "INVALID"
		1:
			name = "VALID"
		2:
			name = "LIMITED"
	return name


func _pico_body_message_name(message: int) -> String:
	var name := "UNKNOWN"
	match message:
		0:
			name = "NO_ERROR"
		1:
			name = "TRACKER_NOT_CALIBRATED"
		2:
			name = "TRACKER_NUM_NOT_ENOUGH"
		3:
			name = "TRACKER_STATE_NOT_SATISFIED"
		4:
			name = "TRACKER_PERSISTENT_INVISIBILITY"
		5:
			name = "TRACKER_DATA_ERROR"
		6:
			name = "USER_CHANGE"
		7:
			name = "TRACKING_POSE_ERROR"
	return name


# -- raw vendor frame builders ------------------------------------------------
# Produce an ``operator.raw_vendor_pose.v1`` frame from the Godot / Pico
# inputs without going through the canonicalization step. The schema
# accepts either string or integer ``source_joint`` ids; we use integers
# because that's what each vendor reports natively. Quaternions are
# preserved in [x, y, z, w] order to match the schema.

func _build_raw_frame_from_pico(body_dict: Dictionary, timestamp_ns: int) -> Dictionary:
	var joints_out: Array = []
	var joints_in: Variant = body_dict.get("joints", [])
	if typeof(joints_in) == TYPE_ARRAY:
		for entry_v in (joints_in as Array):
			if typeof(entry_v) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = entry_v
			var idx: int = int(entry.get("joint", entry.get("source_joint", -1)))
			if idx < 0:
				continue
			var flags: int = int(entry.get("flags", 0))
			var position := _pico_joint_position(entry)
			var rot_v: Variant = entry.get("rotation", {})
			var rot_dict := {}
			if typeof(rot_v) == TYPE_DICTIONARY:
				rot_dict = rot_v as Dictionary
			var joint_out: Dictionary = {"source_joint": idx, "flags": flags}
			if not position.is_empty():
				var p: Vector3 = position["value"]
				var q := Quaternion.IDENTITY
				if not rot_dict.is_empty():
					q = Quaternion(
						float(rot_dict.get("x", 0.0)),
						float(rot_dict.get("y", 0.0)),
						float(rot_dict.get("z", 0.0)),
						float(rot_dict.get("w", 1.0))
					)
				joint_out["pose"] = {
					"p": [p.x, p.y, p.z],
					"q": [q.x, q.y, q.z, q.w],
				}
			else:
				joint_out["pose"] = null
			joints_out.append(joint_out)
	# Per-joint flags carry the tracking quality bits already; the schema
	# has additionalProperties:false at the top level so we deliberately
	# don't propagate body_dict["all_tracked"] here.
	return {
		"schema": "operator.raw_vendor_pose.v1",
		"timestamp_ns": timestamp_ns,
		"source": "pico_bd_body_tracking",
		"source_schema": "XR_BD_body_tracking",
		"space": "openxr_local_floor",
		"joints": joints_out,
	}


func _build_raw_frame_from_godot(tracker: XRBodyTracker, timestamp_ns: int) -> Dictionary:
	# XRBodyTracker exposes 87 joints under Godot 4.5's OpenXR mapping.
	# Iterate by integer joint id so the output preserves the vendor's
	# native ordering; the offline replay can decode it via the same
	# enum the on-device adapter uses.
	var joints_out: Array = []
	# XRBodyTracker.JOINT_MAX in Godot 4.5 is 87 (Meta body skeleton).
	var joint_max: int = 87
	for i in range(joint_max):
		var flags: int = int(tracker.get_joint_flags(i))
		var xform: Transform3D = tracker.get_joint_transform(i)
		var joint_out: Dictionary = {"source_joint": i, "flags": flags}
		# Only emit a pose payload when the runtime reports the joint as
		# tracked/valid — otherwise leave pose=null per the schema.
		if flags != 0:
			var p := xform.origin
			var q := Quaternion(xform.basis.orthonormalized())
			joint_out["pose"] = {
				"p": [p.x, p.y, p.z],
				"q": [q.x, q.y, q.z, q.w],
			}
		else:
			joint_out["pose"] = null
		joints_out.append(joint_out)
	# Source id matches the Python ``GodotBodyAdapter.source_id`` (and the
	# canonical resolver's priority table) so an offline replay dispatches
	# this frame to the right adapter. The underlying OpenXR extension is
	# captured in ``source_schema`` for telemetry purposes only; replay
	# routing keys on ``source`` alone.
	return {
		"schema": "operator.raw_vendor_pose.v1",
		"timestamp_ns": timestamp_ns,
		"source": "godot_xrbodytracker",
		"source_schema": "XR_FB_body_tracking",
		"space": "openxr_local_floor",
		"joints": joints_out,
	}


func _sample_fallback(timestamp_ns: int) -> Dictionary:
	if tracking_provider == null:
		return {}
	var head: Dictionary = {}
	var left_wrist: Dictionary = {}
	var right_wrist: Dictionary = {}
	if tracking_provider.has_method("get_head_pose"):
		head = tracking_provider.call("get_head_pose")
	if tracking_provider.has_method("get_controller_pose"):
		left_wrist = tracking_provider.call("get_controller_pose", 0)
		right_wrist = tracking_provider.call("get_controller_pose", 1)
	return _fallback_adapter.sample(head, left_wrist, right_wrist, timestamp_ns)
