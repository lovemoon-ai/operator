class_name XrStateSink
extends SensorSink
## Capability layer (components/sinks): the XrStateFrame encoder. A plain sink
## on the same StreamBinding as every other sink: it collects one tick's
## clock / head / controller / hand / body / motion-tracker SensorFrames and
## assembles them on StreamBinding.end_of_tick(), without yielding inside the
## tick. take_snapshot() returns the full internal snapshot (the XRoboToolkit
## compatibility encoder reads it); frame_v1() projects it onto the unchanged
## XrStateFrame v1 wire schema the host session sends.
##
## Timestamps pass through: the snapshot's timestamp_ns and every
## sample_timestamp_ns are the producing SensorFrame's timestamp_ns, except a
## record's own `sample_timestamp_ns` / body `source_timestamp_ns`.

const SCHEMA_VERSION := 1
const DEFAULT_COORDINATE_SPACE := "godot_world"
const V1_BODY_JOINT_FIELDS := ["joint", "flags", "tracked", "radius_m", "pose"]
const V1_MOTION_TRACKER_FIELDS := ["id", "tracker_index", "pose", "battery_level"]
const PICO_INT_EXTENSIONS := ["posture", "velocity_flags", "acceleration_flags"]
const PICO_VECTOR_EXTENSIONS := [
	"linear_velocity", "angular_velocity",
	"linear_acceleration", "angular_acceleration",
]

var _frame_id := 0
var _tick: Dictionary = {}
var _snapshot: Dictionary = {}


func accepted_frame_types() -> Array:
	return [
		SensorFrameType.CLOCK,
		SensorFrameType.POSE,
		SensorFrameType.CONTROLLER,
		SensorFrameType.HAND,
		SensorFrameType.BODY,
		SensorFrameType.MOTION_TRACKER,
	]


func policy() -> Dictionary:
	return {"ordering": "per_tick", "durability": "none", "drop_policy": "latest_wins"}


func on_frame(frame: SensorFrame) -> Variant:
	if frame.frame_type == SensorFrameType.CLOCK:
		_tick = {
			"timestamp_ns": frame.timestamp_ns,
			"predicted_display_time_ns": int(
				frame.payload.get("predicted_display_time_ns", frame.timestamp_ns)),
		}
		return null
	if not _tick.has("timestamp_ns"):
		_tick["timestamp_ns"] = frame.timestamp_ns
	match frame.frame_type:
		SensorFrameType.POSE:
			if frame.source_id == "head":
				_tick["head"] = _pose(_pose_record(frame.payload), frame.timestamp_ns)
				if not frame.coordinate_space.is_empty():
					_tick["coordinate_space"] = frame.coordinate_space
		SensorFrameType.CONTROLLER:
			_side(frame.source_id, "controllers", _controller(frame))
		SensorFrameType.HAND:
			_side(frame.source_id, "hands", _hand(frame))
		SensorFrameType.BODY:
			_tick["body"] = _body(frame)
		SensorFrameType.MOTION_TRACKER:
			if not _tick.has("motion_trackers"):
				_tick["motion_trackers"] = []
			(_tick["motion_trackers"] as Array).append(_motion_tracker(frame))
	return null


## Closes the tick opened by the first frame since the previous flush.
func end_of_tick() -> void:
	if _tick.is_empty():
		_snapshot = {}
		return
	_frame_id += 1
	var timestamp_ns := int(_tick["timestamp_ns"])
	var controllers: Dictionary = _tick.get("controllers", {})
	var hands: Dictionary = _tick.get("hands", {})
	_snapshot = {
		"schema_version": SCHEMA_VERSION,
		"frame_id": _frame_id,
		"timestamp_ns": timestamp_ns,
		"predicted_display_time_ns": int(_tick.get("predicted_display_time_ns", timestamp_ns)),
		"coordinate_space": str(_tick.get("coordinate_space", DEFAULT_COORDINATE_SPACE)),
		"head": _tick.get("head", _pose({}, timestamp_ns)),
		"controllers": {"left": controllers.get("left", {}), "right": controllers.get("right", {})},
		"hands": {"left": hands.get("left", {}), "right": hands.get("right", {})},
		"body": _tick.get("body", null),
		"motion_trackers": _tick.get("motion_trackers", []),
	}
	_tick = {}


## The last assembled snapshot ({} when the tick carried no frames). Consumed.
func take_snapshot() -> Dictionary:
	var snapshot := _snapshot
	_snapshot = {}
	return snapshot


## XrStateFrame v1 wire projection of a snapshot.
static func frame_v1(snapshot: Dictionary) -> Dictionary:
	var frame := snapshot.duplicate(true)
	frame.erase("predicted_display_time_ns")
	var body_v: Variant = frame.get("body", null)
	if body_v is Dictionary:
		var body := body_v as Dictionary
		body.erase("source_timestamp_ns")
		var joints_v: Variant = body.get("joints", [])
		if joints_v is Array:
			body["joints"] = _body_joints_v1(
				joints_v as Array,
				int(body.get("sample_timestamp_ns", frame.get("timestamp_ns", 0))),
			)
	var trackers_v: Variant = frame.get("motion_trackers", [])
	if trackers_v is Array:
		frame["motion_trackers"] = _filter_records(trackers_v as Array, V1_MOTION_TRACKER_FIELDS)
	return frame


## Field projection only. Which joints exist is the source's decision: PICO
## reports a fixed set and keeps every entry regardless of `flags`, while the
## Godot XRBodyTracker branch drops `flags == 0` at capture. Dropping untracked
## joints again here would hand a v1 consumer a short array and mis-index every
## joint after the gap.
static func _body_joints_v1(records: Array, sample_timestamp_ns: int) -> Array:
	var filtered := _filter_records(records, V1_BODY_JOINT_FIELDS)
	for joint_v in filtered:
		var pose_v: Variant = (joint_v as Dictionary).get("pose", null)
		if pose_v is Dictionary:
			(pose_v as Dictionary)["sample_timestamp_ns"] = sample_timestamp_ns
	return filtered


static func _filter_records(records: Array, allowed_fields: Array) -> Array:
	var filtered: Array = []
	for record_v in records:
		if not (record_v is Dictionary):
			continue
		var record := record_v as Dictionary
		var output := {}
		for field in allowed_fields:
			if record.has(field):
				output[field] = record[field]
		filtered.append(output)
	return filtered


func _side(source_id: String, group: String, value: Dictionary) -> void:
	if not _tick.has(group):
		_tick[group] = {}
	(_tick[group] as Dictionary)["left" if source_id.begins_with("left") else "right"] = value


## A pose record: either a raw {position, rotation, valid|is_active, ...}
## record, or a canonical PoseFrame/ControllerFrame {transform, tracking_valid}.
static func _pose_record(payload: Dictionary) -> Dictionary:
	if not payload.has("transform"):
		return payload
	var transform: Transform3D = payload["transform"]
	return {
		"valid": bool(payload.get("tracking_valid", true)),
		"position": transform.origin,
		"rotation": transform.basis.get_rotation_quaternion(),
	}


func _controller(frame: SensorFrame) -> Dictionary:
	var payload := frame.payload
	var input_raw: Dictionary = payload.get("input", {})
	var values := {}
	for key in input_raw.keys():
		if str(key) == "timestamp_ns":
			continue
		var value: Variant = input_raw[key]
		if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			values[str(key)] = float(value)
		elif typeof(value) == TYPE_BOOL:
			values[str(key)] = 1.0 if bool(value) else 0.0
	return {
		"pose": _pose(_pose_record(payload.get("pose", payload)), frame.timestamp_ns),
		"input": {"sample_timestamp_ns": frame.timestamp_ns, "values": values},
		"interaction_profile": str(payload.get("interaction_profile", "")),
	}


func _hand(frame: SensorFrame) -> Dictionary:
	var joints_raw: Array = frame.payload.get("joints", [])
	var joints: Array = []
	for joint_index in range(joints_raw.size()):
		var raw: Dictionary = joints_raw[joint_index] if joints_raw[joint_index] is Dictionary else {}
		var tracked := bool(raw.get("tracked", false))
		joints.append({
			"joint": joint_index,
			"flags": int(raw.get("flags", 1 if tracked else 0)),
			"tracked": tracked,
			"radius_m": float(raw.get("radius", raw.get("radius_m", 0.0))),
			"pose": _pose(raw, frame.timestamp_ns, tracked),
		})
	return {
		"active": bool(frame.payload.get("active", false)),
		"sample_timestamp_ns": frame.timestamp_ns,
		"joints": joints,
	}


func _body(frame: SensorFrame) -> Dictionary:
	var raw := frame.payload
	var source_timestamp_ns := int(raw.get("source_timestamp_ns", frame.timestamp_ns))
	var joints: Array = []
	for raw_joint_v in raw.get("joints", []):
		if not (raw_joint_v is Dictionary):
			continue
		var raw_joint := raw_joint_v as Dictionary
		var flags := int(raw_joint.get("flags", 0))
		var joint_source_timestamp_ns := int(raw_joint.get("source_timestamp_ns", source_timestamp_ns))
		var joint := {
			"joint": int(raw_joint.get("joint", joints.size())),
			"flags": flags,
			"tracked": flags != 0,
			"radius_m": float(raw_joint.get("radius_m", 0.0)),
			"source_timestamp_ns": joint_source_timestamp_ns,
			"pose": _pose(raw_joint, joint_source_timestamp_ns, flags != 0),
		}
		_copy_extensions(raw_joint, joint)
		joints.append(joint)
	return {
		"active": bool(raw.get("active", false)),
		"sample_timestamp_ns": frame.timestamp_ns,
		"source_timestamp_ns": source_timestamp_ns,
		"joint_set": str(raw.get("joint_set", "")),
		"body_flags": int(raw.get("body_flags", 0)),
		"joints": joints,
	}


## Payload: {id, tracker_index, pose: raw record, fields: wire extras}.
func _motion_tracker(frame: SensorFrame) -> Dictionary:
	var payload := frame.payload
	var tracker := {
		"id": str(payload.get("id", frame.source_id)),
		"tracker_index": int(payload.get("tracker_index", 0)),
		"pose": _pose(payload.get("pose", {}), frame.timestamp_ns, frame.valid),
	}
	var fields: Dictionary = payload.get("fields", {})
	if fields.has("battery_level"):
		tracker["battery_level"] = fields["battery_level"]
	_copy_extensions(fields, tracker)
	return tracker


static func _copy_extensions(source: Dictionary, target: Dictionary) -> void:
	for key in PICO_INT_EXTENSIONS:
		if source.has(key):
			target[key] = int(source.get(key))
	for key in PICO_VECTOR_EXTENSIONS:
		if source.has(key):
			target[key] = _vec3(source.get(key))


static func _pose(raw: Dictionary, timestamp_ns: int, default_valid: bool = true) -> Dictionary:
	var valid := bool(raw.get("valid", raw.get("is_active", default_valid))) and not raw.is_empty()
	var result := {
		"valid": valid,
		"sample_timestamp_ns": int(raw.get("sample_timestamp_ns", timestamp_ns)),
		"position": _vec3(raw.get("position", null)),
		"rotation": _quat(raw.get("rotation", null)),
	}
	if raw.has("linear_velocity"):
		result["linear_velocity"] = _vec3(raw.get("linear_velocity"))
	if raw.has("angular_velocity"):
		result["angular_velocity"] = _vec3(raw.get("angular_velocity"))
	if raw.has("confidence"):
		result["confidence"] = float(raw.get("confidence"))
	return result


static func _vec3(value: Variant) -> Array:
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Dictionary:
		return [
			float(value.get("x", 0.0)),
			float(value.get("y", 0.0)),
			float(value.get("z", 0.0)),
		]
	if value is Array and value.size() >= 3:
		return [float(value[0]), float(value[1]), float(value[2])]
	return [0.0, 0.0, 0.0]


static func _quat(value: Variant) -> Array:
	if value is Quaternion:
		return [value.x, value.y, value.z, value.w]
	if value is Dictionary:
		return [
			float(value.get("x", 0.0)),
			float(value.get("y", 0.0)),
			float(value.get("z", 0.0)),
			float(value.get("w", 1.0)),
		]
	if value is Array and value.size() >= 4:
		return [float(value[0]), float(value[1]), float(value[2]), float(value[3])]
	return [0.0, 0.0, 0.0, 1.0]
