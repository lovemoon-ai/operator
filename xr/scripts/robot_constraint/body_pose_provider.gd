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
		return {}
	var status_method_ok := pico_openxr_bridge.has_method("get_status")
	if status_method_ok:
		var status: Variant = pico_openxr_bridge.call("get_status")
		if typeof(status) == TYPE_DICTIONARY:
			if not bool((status as Dictionary).get("bd_body_tracking_supported", false)):
				return {}
	var body: Variant = pico_openxr_bridge.call("sample_body_joints")
	if typeof(body) != TYPE_DICTIONARY:
		return {}
	# Pico's body_dict IS the vendor proto — joint indices, position +
	# rotation sub-dicts, flags. Translate it directly into the
	# raw_vendor_pose.v1 shape so an offline replay can drive the entire
	# pipeline from disk without the OpenXR runtime.
	raw_vendor_pose_ready.emit(_build_raw_frame_from_pico(body as Dictionary, timestamp_ns))
	return _pico_adapter.sample(body as Dictionary, timestamp_ns)


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
			var pos_dict: Dictionary = entry.get("position", {})
			var rot_dict: Dictionary = entry.get("rotation", {})
			var joint_out: Dictionary = {"source_joint": idx, "flags": flags}
			if not pos_dict.is_empty() and not rot_dict.is_empty():
				joint_out["pose"] = {
					"p": [float(pos_dict.get("x", 0.0)), float(pos_dict.get("y", 0.0)), float(pos_dict.get("z", 0.0))],
					"q": [
						float(rot_dict.get("x", 0.0)),
						float(rot_dict.get("y", 0.0)),
						float(rot_dict.get("z", 0.0)),
						float(rot_dict.get("w", 1.0)),
					],
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
